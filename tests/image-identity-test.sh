#!/usr/bin/env bash
# An image is its content, not its name.
#
# This is the invariant behind the worst bug this runtime has had: a rebuilt tag
# served the previous image. `myapp:dev` built twice is two different images,
# and ferry-cri keyed the unpacked root filesystem on the *name* -- both the
# cache key and the ext4 file name -- so the second load found an entry already
# there and reused the first image's filesystem. The build reported success, the
# load reported success, `ferry image ls` showed the new image, and only the
# running container disagreed.
#
# It is worth being blunt about why that deserves a permanent test rather than a
# fix and a changelog entry:
#
#   - It is silent. Nothing fails, nothing logs, and the only symptom is a
#     container running code you did not write any more. The natural reaction is
#     to doubt your build, your editor, or your cluster, in that order.
#   - It is on the path everybody uses. Edit, rebuild the same tag, run it, is
#     the entire inner loop of `ferry image build`.
#   - It is easy to reintroduce. Keying a cache by name reads perfectly well,
#     and two of the four bugs in experiment 25 came from exactly that instinct
#     applied in different places.
#
# So this checks the invariant two ways. The source rules run anywhere and catch
# the shape of the mistake at the point somebody makes it; the end-to-end case
# runs against a live cluster and catches it however it is made. Neither alone
# is enough: the rules cannot see a new code path, and the end-to-end test does
# not run on a machine with no cluster up.
#
#   ./tests/image-identity-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
note() { skip=$((skip + 1)); printf '  \033[33m-\033[0m %s\n' "$1"; }

contains() { # description file needle
  # -e, because a needle that starts with a dash is a flag otherwise.
  if grep -qF -e "$3" "$2"; then ok "$1"; else bad "$1"; echo "      '$3' is not in $(basename "$2")"; fi
}
lacks() { # description file needle
  if grep -qF -e "$3" "$2"; then bad "$1"; echo "      '$3' is back in $(basename "$2")"; else ok "$1"; fi
}

runtime="$repo/ferry-cri/Sources/ferry-cri/PodRuntime.swift"
network="$repo/ferry-cri/Sources/ferry-cri/PodNetwork.swift"

echo "the root filesystem is keyed by content"

# The identity an image is cached under. Everything else here follows from it.
contains "identity prefers the digest over the name" "$runtime" \
  'let identity = image.digest.isEmpty ? canonical : image.digest'

# The guard that decides whether to unpack. When this asked about `canonical`,
# a second image under an existing tag skipped the unpack entirely.
contains "the unpack guard asks about the identity" "$runtime" \
  'if rootfsCache[identity] == nil {'
lacks "the unpack guard no longer asks about the name" "$runtime" \
  'if rootfsCache[canonical] == nil {'

# The file name, which collided for the same reason the key did. It is the
# platform manifest's digest rather than the image's: an index records the name
# it was tagged as, so one build under two tags is two identities over one
# filesystem, and naming the file by the index unpacked it twice.
contains "the ext4 path is derived from the platform manifest" "$runtime" \
  'let content = (try? await image.descriptor(for: platform).digest) ?? identity'
contains "the ext4 path is derived from that content digest" "$runtime" \
  'let path = imageDisk(content)'
lacks "the ext4 path is no longer derived from the index" "$runtime" \
  'let safe = identity.replacingOccurrences'
contains "a second identity over the same content reuses the disk" "$runtime" \
  'rootfsCache[identity] = shared'

# Names are aliases for the identity, never the other way round.
contains "names resolve to the identity" "$runtime" \
  'for key in keys { rootfsCache[key] = rootfsCache[identity] }'

echo
echo "a superseded image is collected"

# The first attempt at this collected nothing, because it asked whether
# anything still referenced the old rootfs and the superseded image's own
# digest key always did. Reachability is by tag.
contains "the collector ignores digest keys when deciding reachability" "$runtime" \
  '!$0.key.hasPrefix("sha256:") && $0.value.source == stale.source'

echo
echo "removing an image removes all of it"

# The kubelet's image garbage collector calls RemoveImage by image ID, and on a
# full disk it calls it every five minutes. Removing the key it was handed and
# leaving the aliases left imageStatus answering "present" for an image
# createContainer could no longer resolve -- and freed nothing, so it ran again
# and took the next image apart. That is what made this bug look recurrent.
contains "removal resolves the reference to a root filesystem" "$runtime" \
  'guard let mount = direct.compactMap({ rootfsCache[$0] }).first else {'
contains "removal drops every name the image is known by" "$runtime" \
  'let aliases = id.map { id in pulledImages.filter { $0.value.id == id }.map(\.key) } ?? []'
# But not every name on the disk: two tags of one build share it, and removing
# the unused one must not take the names of the one a pod is running.
lacks "removal does not drop another image's names that share the disk" "$runtime" \
  'let aliases = rootfsCache.filter { $0.value.source == mount.source }.map(\.key)'
contains "removal gives the disk back once nothing unpacks to it" "$runtime" \
  'if !rootfsCache.values.contains(where: { $0.source == mount.source }) {'
contains "removal gives the disk back" "$runtime" \
  'try? FileManager.default.removeItem(atPath: mount.source)'

echo
echo "a pod address is not reused while the Mac remembers it"

contains "a never-used address is preferred" "$network" \
  '} else if next < subnet.upper.value {'
contains "recycling is oldest-first" "$network" \
  'host = reusable.removeFirst()'
lacks "recycling is not newest-first" "$network" \
  'reusable.popLast()'

echo
echo "end to end: a rebuilt tag runs the new image"

ferry="$repo/ferry"
kubeconfig="$("$ferry" kubeconfig 2>/dev/null)"

if [ -z "$kubeconfig" ] || [ ! -f "$kubeconfig" ] || ! kubectl --kubeconfig "$kubeconfig" get nodes >/dev/null 2>&1; then
  note "no cluster up; skipped (run 'ferry up' to include this)"
elif ! command -v buildctl >/dev/null 2>&1; then
  note "buildctl not installed; skipped (brew install buildkit)"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  tag="ferry-image-identity-test:dev"
  pod="ferry-image-identity-test"
  k() { kubectl --kubeconfig "$kubeconfig" "$@"; }

  cat > "$work/pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
  restartPolicy: Never
  containers:
    - name: $pod
      image: $tag
      imagePullPolicy: IfNotPresent
YAML

  # What the container prints is what the image was built from, so a stale
  # rootfs is visible as the wrong string rather than as a subtle difference.
  build_and_run() { # marker -> what the pod printed
    printf 'FROM ghcr.io/linuxcontainers/alpine:3.20\nRUN echo %s > /marker\nCMD ["cat","/marker"]\n' \
      "$1" > "$work/Dockerfile"
    "$ferry" image build -q -t "$tag" "$work" >/dev/null 2>&1 || { echo "BUILD-FAILED"; return; }
    k delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1
    k apply -f "$work/pod.yaml" >/dev/null 2>&1
    local i=0
    while [ "$i" -lt 60 ]; do
      case "$(k get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" in
        Succeeded|Failed|Running) break ;;
      esac
      sleep 1; i=$((i + 1))
    done
    k logs "$pod" 2>/dev/null | tr -d '\r\n'
  }

  first="$(build_and_run VERSION-ONE)"
  [ "$first" = VERSION-ONE ] && ok "the first build runs" \
    || bad "the first build runs (pod printed '$first')"

  # The bug. Same tag, different content: this printed VERSION-ONE.
  second="$(build_and_run VERSION-TWO)"
  [ "$second" = VERSION-TWO ] && ok "a rebuilt tag runs the new image" \
    || bad "a rebuilt tag runs the new image (pod printed '$second')"

  # And the rootfs for the superseded image goes away, rather than one ext4
  # per build accumulating until the disk is full.
  # `grep -c` prints 0 and exits non-zero when it matches nothing, so `|| echo 0`
  # would append a second line and make this "0\n0" -- which `-le` then rejects
  # as not an integer, reporting a leak that did not happen. It prints the count
  # on its own.
  runtime_dir="$("$ferry" profile 2>/dev/null | awk '/^  runtime /{print $2}')"
  state="$runtime_dir/cri"
  count() { ls "$state" 2>/dev/null | grep -c 'image-sha256'; }

  if [ -z "$runtime_dir" ] || [ ! -d "$state" ]; then
    # Rather than comparing two zeroes and calling it a pass.
    note "could not find the image store; leak check skipped"
  else
    before="$(count)"
    build_and_run VERSION-THREE >/dev/null
    after="$(count)"
    [ "$after" -le "$before" ] && ok "a rebuild does not leak a root filesystem" \
      || bad "a rebuild does not leak a root filesystem ($before -> $after)"
  fi

  k delete pod "$pod" --ignore-not-found >/dev/null 2>&1
fi

echo
printf '%s passed, %s failed' "$pass" "$fail"
[ "$skip" -gt 0 ] && printf ', %s skipped' "$skip"
echo
[ "$fail" -eq 0 ]
