#!/usr/bin/env bash
# Tests for installing ferry rather than building it.
#
# What an installed release is, as far as ferry is concerned, is a directory
# that is not a git checkout, reached through a symlink, carrying binaries and
# no sources. Every one of those three has already been a bug in something:
# a CLI that resolves its root to the bin directory it was linked from, a
# profile derived from a directory name that changes every upgrade, a `build`
# that fails four steps in because there is nothing to build. They are cheap to
# check here and expensive to notice on someone else's Mac.
#
# The join token is tested here too. It is the one piece of this that is pure
# arithmetic on a string, and the one piece where getting it wrong means a
# second Mac silently sharing the first Mac's pod addresses.
#
#   ./tests/install-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

is() { # description actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "      got:  '$2'"; echo "      want: '$3'"; fi
}
contains() { # description haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; echo "      '$2' does not contain '$3'" ;; esac
}
empty() { # description actual
  if [ -z "$2" ]; then ok "$1"; else bad "$1"; echo "      expected nothing, got '$2'"; fi
}
succeeds() { # description command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else bad "$description"; fi
}
refuses() { # description command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$description"; else ok "$description"; fi
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# A fake installed release: the CLI, what it sources, and a VERSION file. No
# git, because that is the thing being tested.
fake_release() { # dir version
  local dir="$1" version="$2"
  mkdir -p "$dir/lib" "$dir/bin"
  cp "$repo/ferry" "$dir/ferry"
  cp "$repo/lib/versions.sh" "$dir/lib/"
  cat > "$dir/VERSION" <<META
ferry=$version
kubernetes=v1.34.0
control-plane=v1.34.11
etcd=v3.6.5
commit=deadbeef
swift=6.4
built=2026-01-01T00:00:00Z
META
}

# Every invocation below gets its own state, so nothing here can find, start or
# stand on a real cluster.
run_ferry() { # dir args...
  local dir="$1"; shift
  ( export FERRY_HOME="$sandbox/home" \
           FERRY_RUN="$sandbox/run" \
           FERRY_PROFILES="$sandbox/profiles"
    "$dir/ferry" "$@" 2>&1 )
}

# --- the join token -------------------------------------------------------
#
# Sourced rather than re-implemented: a test that agrees with a copy of the
# encoder proves nothing about the encoder ferry actually ships.
printf '\033[1m%s\033[0m\n' "the join token"
(
  # ferry runs its dispatcher when sourced with no arguments, which prints
  # usage; the function definitions are what is wanted.
  export FERRY_HOME="$sandbox/home" FERRY_RUN="$sandbox/run" \
         FERRY_PROFILES="$sandbox/profiles"
  # shellcheck source=../ferry
  . "$repo/ferry" >/dev/null 2>&1

  hash="$(printf 'a%.0s' $(seq 1 64))"
  token="$(ferry_token_encode "$hash" "abc123" "s3cr3ts3cr3ts3cr")"
  is "encodes to one pasteable string" "$token" "F10$hash::abc123.s3cr3ts3cr3ts3cr"

  decoded="$(ferry_token_decode "$token")"
  is "and decodes back to the hash and the credential" \
    "$decoded" "$hash abc123.s3cr3ts3cr3ts3cr"

  # The failure this shape exists to prevent: a token that lost characters on
  # its way through a chat window must not parse. If it did, the CA pin would
  # be checked against a truncated hash, fail, and report a CA mismatch -- which
  # is a security-shaped error message for a copy-and-paste mistake.
  refuses "a truncated hash is not a token" ferry_token_decode "F10${hash:0:40}::abc123.secret"
  refuses "a non-hex hash is not a token" ferry_token_decode "F10${hash:0:63}z::abc123.secret"
  refuses "a credential with no dot is not a token" ferry_token_decode "F10$hash::abc123"
  refuses "the old three-part form is not one of these" ferry_token_decode "abc123.s3cr3t"
  refuses "an empty string is not a token" ferry_token_decode ""

  exit $fail
) || fail=$((fail + 1))
# The subshell above keeps its own counters; re-run the two that the parent
# needs to see as a single outcome.
[ "$fail" -eq 0 ] && pass=$((pass + 7))
echo

# --- an installed release is not a checkout -------------------------------
printf '\033[1m%s\033[0m\n' "an installed release"
dist="$sandbox/.ferry-dist/versions/ferry-v0.1.0"
fake_release "$dist" "v0.1.0"

out="$(run_ferry "$dist" version)"
contains "reports its release version" "$out" "ferry v0.1.0"

# The one that would have been silent. A release directory is named after its
# version, so deriving the profile from the directory name gives a new profile
# -- new ports, new state, new pod CIDR -- at every upgrade, and the old
# cluster's etcd is left behind in a directory nobody will look in.
out="$(run_ferry "$dist" profile)"
contains "runs on the default profile, not one named after its directory" \
  "$out" "profile default"
contains "so its state is ~/.ferry, like a main checkout's" "$out" "$sandbox/home"

# Nothing in a release can be built: there are no sources, no patches and no
# toolchain. Failing here, by name, beats failing inside build-kubelet.sh.
out="$(run_ferry "$dist" build)"
contains "refuses to build" "$out" "not a checkout"
contains "and points at installing a release instead" "$out" "get.ferry.kurpuis.com"

# The same wall, reached the other way. 'ferry upgrade' compiles a kubelet, so a
# release cannot do it either -- and has to say so before taking an etcd
# snapshot and spending several minutes discovering it inside build-kubelet.sh.
out="$(run_ferry "$dist" upgrade plan v1.35.0)"
contains "refuses to upgrade kubernetes" "$out" "cannot build a kubelet"
contains "and says a newer ferry is how you move kubernetes" "$out" "get.ferry.kurpuis.com"
echo

# --- reached through a symlink --------------------------------------------
printf '\033[1m%s\033[0m\n' "reached through a symlink"
# Exactly the shape install.sh creates: a launcher on PATH pointing at
# 'current', which points at the version. Both hops have to be followed, or
# ferry looks for its kernel, plugins and binaries in ~/.local/bin.
ln -sfn "versions/ferry-v0.1.0" "$sandbox/.ferry-dist/current"
mkdir -p "$sandbox/bin"
ln -sfn "$sandbox/.ferry-dist/current/ferry" "$sandbox/bin/ferry"

out="$(run_ferry "$sandbox/bin" version)"
case "$out" in
  *"$sandbox/bin"*) bad "does not mistake the launcher's directory for its root" ;;
  *) ok "does not mistake the launcher's directory for its root" ;;
esac
# Stops at 'current' rather than resolving through to the version directory, so
# that a path written down once -- the LaunchAgent plist -- follows upgrades
# instead of pinning the cluster to the release installed that day.
contains "resolves to 'current', not to the version behind it" \
  "$out" "root          $sandbox/.ferry-dist/current"
contains "and still knows which release it is" "$out" "ferry v0.1.0"

# The property that matters: the files ferry opens are found through that root.
succeeds "and the release's own files are reachable from it" \
  test -f "$sandbox/.ferry-dist/current/VERSION"

# An upgrade is one symlink move, and the launcher follows it without relinking.
fake_release "$sandbox/.ferry-dist/versions/ferry-v0.2.0" "v0.2.0"
ln -sfn "versions/ferry-v0.2.0" "$sandbox/.ferry-dist/current"
out="$(run_ferry "$sandbox/bin" version)"
contains "moving 'current' upgrades the launcher without touching it" "$out" "ferry v0.2.0"
ln -sfn "versions/ferry-v0.1.0" "$sandbox/.ferry-dist/current"

out="$(run_ferry "$sandbox/bin" profile)"
contains "still on the default profile through the links" "$out" "profile default"
echo

# The LaunchAgent is the one thing that records ferry's path and then reads it
# back at every login, so it is the one that must not name a version directory.
# Pinned there, an upgrade moves 'current' and the launcher, and leaves the
# agent starting the old release at every login with nothing saying so.
printf '\033[1m%s\033[0m\n' "the login agent follows upgrades"
contains "the installer runs ferry through 'current'" \
  "$(cat "$repo/install.sh")" 'ROOT="$INSTALL_DIR/current"'
case "$(grep -n 'ROOT="\$target"' "$repo/install.sh")" in
  "") ok "and not through the version directory" ;;
  *)  bad "install.sh still points ROOT at the version directory" ;;
esac
contains "and the plist is written from ferry's own root" \
  "$(cat "$repo/ferry")" 'local launcher="$here/ferry"'
echo

# --- a checkout still behaves like a checkout ------------------------------
printf '\033[1m%s\033[0m\n' "a checkout is unchanged"
out="$(run_ferry "$repo" version)"
case "$out" in
  *"ferry (checkout"*) ok "reports a commit rather than a release version" ;;
  *) bad "reports a commit rather than a release version"; echo "      got: $out" ;;
esac
out="$(run_ferry "$repo" profile)"
contains "and derives its profile from git as before" "$out" "profile "
echo

# --- uninstalling ----------------------------------------------------------
#
# The only step in ferry that removes a file outside its own directories, so
# what it will and will not remove is worth pinning down.
printf '\033[1m%s\033[0m\n' "uninstalling"
mkdir -p "$sandbox/bin2"
ln -sfn "$sandbox/.ferry-dist/current/ferry" "$sandbox/bin2/ferry"
# Somebody else's ferry, on the same PATH, pointing somewhere else entirely.
other="$sandbox/other"; mkdir -p "$other"
cp "$repo/ferry" "$other/ferry"
ln -sfn "$other/ferry" "$sandbox/bin2/ferry-other"

out="$( export FERRY_HOME="$sandbox/uhome" FERRY_RUN="$sandbox/urun" \
               FERRY_PROFILES="$sandbox/profiles" FERRY_BIN_DIR="$sandbox/bin2"
        mkdir -p "$FERRY_HOME"
        "$sandbox/bin2/ferry" uninstall --yes 2>&1 )"
succeeds "removes its own launcher" test ! -e "$sandbox/bin2/ferry"
succeeds "and leaves another ferry on the same PATH alone" test -L "$sandbox/bin2/ferry-other"
succeeds "keeps the cluster's state without --purge" test -d "$sandbox/uhome"
contains "and says the release is still there" "$out" ".ferry-dist"

# --purge is the irreversible one, so it refuses a FERRY_HOME it should never
# have been handed rather than trusting the caller.
#
# HOME is overridden for this, and that is not paranoia. The first version of
# this test passed $HOME as FERRY_HOME against the developer's real home
# directory -- and `cmd_down --purge`, which ran before the guard, deletes
# $FERRY_HOME/etcd, $FERRY_HOME/version and $FERRY_HOME/version.previous. It
# asserted "and $HOME is still there", which was true while three things inside
# it had been removed. A test for a destructive guard must not be able to
# destroy anything if the guard fails: the guard is what is on trial.
ln -sfn "$sandbox/.ferry-dist/current/ferry" "$sandbox/bin2/ferry"
fakehome="$sandbox/fakehome"
mkdir -p "$fakehome/etcd"
echo "kubernetes=v1.34.0" > "$fakehome/version"
out="$( export HOME="$fakehome" FERRY_HOME="$fakehome" FERRY_RUN="$sandbox/urun" \
               FERRY_PROFILES="$sandbox/profiles" FERRY_BIN_DIR="$sandbox/bin2"
        "$sandbox/bin2/ferry" uninstall --purge --yes 2>&1 )"
contains "refuses to purge a FERRY_HOME that is \$HOME" "$out" "refusing to purge"
# The three the old ordering destroyed before ever reaching the guard.
succeeds "before deleting etcd" test -d "$fakehome/etcd"
succeeds "before deleting the recorded cluster version" test -f "$fakehome/version"
succeeds "and before unlinking the launcher" test -L "$sandbox/bin2/ferry"
echo

# --- stopping a cluster the login agent is watching ------------------------
#
# launchd restarts a job that exits non-zero, which is how the agent notices a
# cluster that fell over -- and it cannot tell that apart from 'ferry down',
# because both end with the processes gone. Without the marker, 'ferry down'
# stopped the cluster and launchd started it again five seconds later, so there
# was no way to turn ferry off at all while the agent was installed.
printf '\033[1m%s\033[0m\n' "stopping is distinguishable from crashing"
(
  export FERRY_HOME="$sandbox/shome" FERRY_RUN="$sandbox/srun" \
         FERRY_PROFILES="$sandbox/profiles"
  mkdir -p "$FERRY_HOME"
  # shellcheck source=../ferry
  . "$repo/ferry" >/dev/null 2>&1

  was_stopped && { echo "FAIL: a fresh cluster reads as stopped"; exit 1; }
  mark_stopped
  was_stopped || { echo "FAIL: 'ferry down' did not record the stop"; exit 1; }
  clear_stopped
  was_stopped && { echo "FAIL: 'ferry up' did not clear the stop"; exit 1; }
  exit 0
) && ok "down records it, up clears it" || bad "the stopped marker does not round-trip"

contains "'ferry down' records it before stopping anything" \
  "$(sed -n '/^cmd_down/,/ferry-proxy runs as root/p' "$repo/ferry")" "mark_stopped"
contains "and the agent exits 0 when it sees it, so launchd leaves it down" \
  "$(sed -n '/^cmd_service_run/,/^}/p' "$repo/ferry")" "not restarting it"
# A cluster already running must not be started a second time: cmd_up refuses
# with a non-zero exit, which is exactly launchd's restart condition, so the
# agent would respawn against a healthy cluster every few seconds forever.
contains "a running cluster is held, not started again" \
  "$(sed -n '/^cmd_service_run/,/^}/p' "$repo/ferry")" "already up; holding it"
# cmd_up starts a control plane. Doing that on a Mac that joined someone else's
# cluster gives it a second etcd and a second idea of the cluster.
contains "a joined worker is never started as a server" \
  "$(sed -n '/^cmd_service_run/,/^}/p' "$repo/ferry")" "joined a cluster on another"
# An agent that adopted a running cluster must leave it as it found it.
# `ferry service uninstall` boots the job out, which is a SIGTERM, so a trap
# that always calls cmd_down stops a cluster the operator started by hand --
# removing a plist tore down a healthy cluster, seconds later.
service_run_src="$(sed -n '/^cmd_service_run/,/^}/p' "$repo/ferry")"
contains "an adopted cluster is left running when the agent is stopped" \
  "$service_run_src" "adopted it rather than starting it"
contains "and the agent records which of the two it did" "$service_run_src" "adopted=1"
echo

# --- the agent's environment ----------------------------------------------
printf '\033[1m%s\033[0m\n' "the login agent's environment"
# cmd_up waits for the node with kubectl and installs CoreDNS with it. launchd
# hands an agent almost no PATH, and the installer puts kubectl in ~/.local/bin
# whenever /usr/local/bin is not writable -- which is stock macOS. Missing, the
# cluster times out on a node that is fine and comes up with no DNS.
agent_src="$(sed -n '/^cmd_service_install/,/^}/p' "$repo/ferry")"
contains "records where kubectl actually is" "$agent_src" "command -v kubectl"
contains "and the installer's fallback bin directory" "$agent_src" '$HOME/.local/bin'
contains "and says so when there is no kubectl to record" "$agent_src" "will not find one either"
echo

# --- joining ---------------------------------------------------------------
printf '\033[1m%s\033[0m\n' "joining"
join_src="$(sed -n '/^cmd_join/,/^}/p' "$repo/ferry")"
# ferry builds "https://$server", so a server given with a scheme produced
# https://https://mac1:6443 and an error about the token.
contains "a server given with a scheme is accepted" "$join_src" "https://*) server="
contains "and the installer documents the bare form" \
  "$(head -20 "$repo/install.sh")" "FERRY_URL=mac1.local:6443"

# The label only lands when the kubelet creates the node object, so nodes from
# before it stay unlabelled forever. Counting them all as index 0 reports the
# lowest free index as 1 in a cluster whose second Mac already owns 1.
index_src="$(sed -n '/^free_node_index/,/^}/p' "$repo/ferry")"
contains "more than one unlabelled node is refused rather than guessed" \
  "$index_src" 'unlabelled" -gt 1'
contains "and the refusal says how to look it up" "$join_src" "kubectl get nodes -L ferry.dev/node-index"
echo

# --- the release carries what ferry opens ----------------------------------
#
# ferry reads the guest kernel, the CNI plugins, nft, the manifests and the
# control plane's scripts at runtime. A release that is missing one of them
# installs perfectly and fails at 'ferry up', or worse, at the first pod.
#
# So: every top-level path ferry refers to as "$here/..." must either be copied
# by release/build.sh or be named below as something a release deliberately does
# not carry. A new reference in ferry fails this test rather than a user's Mac.
printf '\033[1m%s\033[0m\n' "the release carries what ferry opens"

# Paths a release deliberately does not carry, each for a stated reason. A new
# entry here is a decision; a new entry appearing in 'missing' below is a bug.
not_shipped="
  build-kubelet.sh                              compiles the kubelet; a release ships it built
  kernel/build-kernel.sh                        builds the guest kernel; a release ships it built
  guest/build-nft.sh                            builds nft; a release ships it built
  ferry-cni/build.sh                            builds the plugins; a release ships them built
  ferry-cri                                     swift sources
  ferry-gpud                                    go sources
  ferry-netpol                                  go sources
  ferry-proxy                                   go sources
  ferry-storage                                 go sources
  ferry-streamer                                go sources
  experiments/03-vm-ceiling/fetch-kernel.sh     part of the build
  experiments/03-vm-ceiling/assets/vmlinux-arm64 the kata fallback kernel, 15MB spent on a worse cluster
  experiments/17-node-vm/stage.sh               downloads the node image's contents; build only
  experiments/18-node-image/build.sh            builds the node image with docker; a release ships it built
  experiments/18-node-image/rebuild-tool.sh     builds ferry-node; a release ships it built
  VERSION                                       written by release/build.sh, not copied
"
exempt() { # path
  case "$not_shipped" in *"
  $1 "*) return 0 ;; esac
  return 1
}

referenced="$(grep -o '\$here/[a-zA-Z0-9_./-]*' "$repo/ferry" \
  | sed 's|\$here/||' | sort -u)"
missing=""
for path in $referenced; do
  # bin/<name> is the binaries, checked by name below.
  case "$path" in bin|bin/*) continue ;; esac
  exempt "$path" && continue
  # The top-level component the path lives in is what build.sh copies.
  top="${path%%/*}"
  grep -q "root/$top" "$repo/release/build.sh" || missing="$missing $path"
done
if [ -z "$missing" ]; then
  ok "every runtime path ferry opens is packaged, or exempt for a stated reason"
else
  bad "release/build.sh does not ship:$missing"
fi

# ferry's own binaries are copied by name; Kubernetes' come from the version
# store, which build.sh walks with the same list ferry and the upgrade path use.
# Checking them against that variable rather than a second copy of the list is
# the point: adding a binary to FERRY_VERSIONED_BINARIES should not also require
# remembering to add it to a release.
# shellcheck source=../lib/versions.sh
. "$repo/lib/versions.sh"
for binary in ferry-cri ferry-cni ferry-streamer ferry-netpol ferry-storage ferry-gpud ferry-proxy \
              ferry-machined ferry-node; do
  if grep -q "$binary" "$repo/release/build.sh"; then ok "packages $binary"
  else bad "release/build.sh does not package $binary"; fi
done
if grep -q 'for name in \$FERRY_VERSIONED_BINARIES' "$repo/release/build.sh"; then
  ok "packages all of FERRY_VERSIONED_BINARIES ($FERRY_VERSIONED_BINARIES)"
else
  bad "release/build.sh does not walk FERRY_VERSIONED_BINARIES, so kubelet, ferry-proxyd, the control plane and etcd may be missing"
fi
echo

# --- mode 2 ----------------------------------------------------------------
#
# Mode 2 is opt-in on the Mac, but a release has to *carry* it or enabling it
# there is impossible: the controller, the tool that makes the VM, the CRD, and
# the node image the machines boot.
printf '\033[1m%s\033[0m\n' "mode 2 reaches an installed Mac"
build_src="$(cat "$repo/release/build.sh")"
contains "the release carries the Machine CRD" "$build_src" "ferry-machined/crd.yaml"
# The OCI layout, not the unpacked ext4: the layout is the compressed layers and
# ferry-node unpacks it on the far side, which keeps Docker off the installing
# Mac and a 400MB mostly-zero sparse file out of the tarball.
contains "and the node image as an OCI layout" "$build_src" "node-image/oci"
# ferry-node boots the machine's VM, so it needs the entitlement as much as
# ferry-cri does, and fails the same unhelpful way without it.
contains "and checks ferry-node's virtualization entitlement" \
  "$build_src" 'entitlements - "$dir/bin/ferry-node"'
contains "a release without the node image records that it is missing" \
  "$build_src" "node-image=\$("

# The CRD and the DNS objects live in etcd, so 'ferry down --purge' takes them
# while the enabled marker -- a file -- survives. Installing them in
# start_machines rather than only in `machines enable` is what makes a purged
# and restarted cluster come back whole, instead of running the controller
# against a cluster with no Machine kind.
machines_src="$(sed -n '/^start_machines/,/^}/p' "$repo/ferry")"
contains "starting machines installs the CRD, on every start" \
  "$machines_src" "crd.yaml"
# Enabling has to survive a restart, or a cluster comes back in mode 1 only and
# the machines that were running are simply gone.
contains "and 'machines enable' records the choice, so the cluster comes back with them" \
  "$(sed -n '/^cmd_machines_enable/,/^}/p' "$repo/ferry")" "MACHINES_MARKER"
contains "'ferry up' starts them for a cluster that asked" \
  "$(sed -n '/^cmd_up/,/^}/p' "$repo/ferry")" "machines_enabled"
# A release built without the image should say so rather than fail obscurely on
# a missing directory.
contains "a missing node image explains itself on a release" \
  "$(sed -n '/^machines_ready/,/^}/p' "$repo/ferry")" "packaged without one"

# --- choosing a mode ------------------------------------------------------
#
# docs/MACHINES.md specifies `nodeSelector: {ferry.dev/mode: shared}` as how a
# pod picks between a kernel of its own and a shared one. That selector matched
# nothing: no node carried the label on either side.
contains "the Mac node says it is vm-per-pod" \
  "$(sed -n '/^start_kubelet/,/^}/p' "$repo/ferry")" "ferry.dev/mode=vm-per-pod"
contains "and keeps its node-index label alongside" \
  "$(sed -n '/^start_kubelet/,/^}/p' "$repo/ferry")" "ferry.dev/node-index="
contains "a machine's node is labelled shared by the controller" \
  "$(cat "$repo/ferry-machined/reconcile.go")" 'modeShared = "shared"'
# --node-labels only applies when the kubelet *creates* the Node object, so a
# cluster that predates the label never gets it: ferry's own node had been in
# etcd for days and came back Ready and unlabelled, while a freshly made machine
# was labelled correctly and the vm-per-pod selector matched nothing at all.
contains "an existing Mac node is labelled too, not just a new one" \
  "$(sed -n '/^ensure_mode_label/,/^}/p' "$repo/ferry")" "ferry.dev/mode=vm-per-pod"
contains "and 'ferry up' asserts it once the node is Ready" \
  "$(sed -n '/^cmd_up/,/^}/p' "$repo/ferry")" 'ensure_mode_label "$NODE_NAME"'
contains "and it is applied where the controller already has the Node" \
  "$(cat "$repo/ferry-machined/reconcile.go")" "c.ensureModeLabel(ctx, node)"

# --- cluster DNS for machines ---------------------------------------------
#
# Mode 1's CoreDNS is a ferry-cri pod on the Mac's vmnet network; machines are
# on a vmnet network of their own and vmnet keeps them apart. So machines need
# their own CoreDNS behind a ClusterIP, with kube-proxy inside the node to
# answer it -- and ferry-node has to be told that address, which it was not.
printf '\033[1m%s\033[0m\n' "cluster DNS for machines"
for f in coredns kube-proxy; do
  succeeds "manifests/machines/$f.yaml exists" test -f "$repo/manifests/machines/$f.yaml"
done
contains "starting machines installs them, so a purge does not lose them" \
  "$(sed -n '/^start_machines/,/^}/p' "$repo/ferry")" "install_machine_dns"
contains "and ferry-node is told the DNS address" \
  "$(sed -n '/^start_machines/,/^}/p' "$repo/ferry")" '--cluster-dns "$MACHINE_DNS_IP"'
# A ClusterIP is immutable, so an existing kube-dns at another address has to be
# reported rather than applied over.
contains "an existing kube-dns at another address is refused, not overwritten" \
  "$(sed -n '/^install_machine_dns/,/^}/p' "$repo/ferry")" "cannot be changed"
# The flag that looked like the knob and went nowhere.
case "$(grep -c 'cluster-dns' "$repo/ferry-machined/main.go")" in
  0) bad "ferry-machined lost the note explaining where --cluster-dns went" ;;
  *) case "$(grep -c 'flag.String("cluster-dns"' "$repo/ferry-machined/main.go")" in
       0) ok "ferry-machined no longer declares a --cluster-dns it never read" ;;
       *) bad "ferry-machined still declares an unread --cluster-dns flag" ;;
     esac ;;
esac

# Both workloads must be pinned to machines. Unpinned, kube-proxy tolerates
# everything and lands on the Mac node as a pod VM programming a node kernel
# ferry has not got, and CoreDNS becomes a second copy serving nobody.
if command -v ruby >/dev/null 2>&1; then
  pinning="$(ruby -ryaml -e '
    objs=[]
    ["manifests/machines/kube-proxy.yaml","manifests/machines/coredns.yaml"].each do |f|
      YAML.load_stream(File.read(f)){|d| objs << d if d}
    end
    bad=[]
    objs.each do |o|
      next unless %w[Deployment DaemonSet].include?(o["kind"])
      sel = o.dig("spec","template","spec","nodeSelector")
      bad << o.dig("metadata","name") unless sel && sel["ferry.dev/mode"] == "shared"
    end
    svc = objs.find{|o| o["kind"]=="Service"}
    dep = objs.find{|o| o["kind"]=="Deployment"}
    bad << "service-selector" unless svc && svc.dig("spec","selector") == dep.dig("spec","template","metadata","labels")
    bad << "selects-mode-1-coredns" if svc && svc.dig("spec","selector","k8s-app") == "kube-dns"
    print bad.empty? ? "ok" : bad.join(",")
  ' 2>/dev/null)"
  is "every machine workload is pinned to ferry.dev/mode=shared" "$pinning" "ok"

  # Mode 1 already owns Deployment/coredns and ConfigMap/coredns in kube-system.
  # Applying a second set under those names replaces mode 1's DNS with a copy
  # pinned to nodes mode 1 does not have.
  clash="$(ruby -ryaml -e '
    def ids(files)
      s=[]
      files.each{|f| YAML.load_stream(File.read(f)){|d| s << "#{d["kind"]}/#{d.dig("metadata","name")}" if d}}
      s
    end
    print (ids(["manifests/coredns.yaml"]) & ids(["manifests/machines/coredns.yaml","manifests/machines/kube-proxy.yaml"])).join(",")
  ' 2>/dev/null)"
  empty "and collides with none of mode 1's own DNS objects" "$clash"

  # The two manifests are rendered together, and a YAML file need not end with a
  # document separator -- so concatenating them runs the kube-proxy DaemonSet
  # into the CoreDNS ServiceAccount and produces one object that is neither.
  # kube-proxy is then silently never created, machines cannot resolve anything,
  # and the apply reports no error at all. Counting the objects on both sides of
  # the join is what catches it.
  joined="$sandbox/joined.yaml"
  cp "$repo/manifests/machines/kube-proxy.yaml" "$joined"
  echo "---" >> "$joined"
  cat "$repo/manifests/machines/coredns.yaml" >> "$joined"
  counts="$(ruby -ryaml -e '
    sep = YAML.load_stream(File.read(ARGV[0])).compact.size +
          YAML.load_stream(File.read(ARGV[1])).compact.size
    joined = YAML.load_stream(File.read(ARGV[2])).compact
    has_ds = joined.any?{|o| o["kind"] == "DaemonSet"}
    print "#{sep}/#{joined.size}/#{has_ds}"
  ' "$repo/manifests/machines/kube-proxy.yaml" "$repo/manifests/machines/coredns.yaml" "$joined" 2>/dev/null)"
  is "no object is lost where the two manifests are joined" "$counts" "10/10/true"
  contains "and ferry writes the separator that keeps them apart" \
    "$(sed -n '/^install_machine_dns/,/^}/p' "$repo/ferry")" 'echo "---"'
else
  ok "ruby not present; skipping the manifest shape checks"
fi

# A release built with --without-node-image told the operator two contradictory
# things: 'machines status' said to run 'ferry node-image', and 'ferry
# node-image' on a release answered "it already carries the node image". Both
# read the recorded fact now instead of guessing from a missing directory.
dist2="$sandbox/.ferry-dist/versions/ferry-v0.2.0"
fake_release "$dist2" "v0.2.0"
sed -i '' 's/^ferry=v0.2.0$/ferry=v0.2.0\nnode-image=no/' "$dist2/VERSION"
out="$(run_ferry "$dist2" machines status)"
contains "a release without the image does not send you to a command it refuses" \
  "$out" "packaged without one"
case "$out" in
  *"ferry node-image   (slow"*) bad "still tells a release to build a node image" ;;
  *) ok "and does not offer the checkout's build command" ;;
esac
out="$(run_ferry "$dist2" node-image)"
contains "and 'node-image' does not claim an image it never had" "$out" "packaged without a node image"
echo

# --- the installer --------------------------------------------------------
printf '\033[1m%s\033[0m\n' "the installer"
succeeds "install.sh is valid /bin/sh" sh -n "$repo/install.sh"
# It runs before ferry is on the machine, so bash-only syntax in it is a syntax
# error on a Mac rather than a portability nicety.
case "$(head -1 "$repo/install.sh")" in
  "#!/bin/sh") ok "and says so in its shebang" ;;
  *) bad "install.sh should be #!/bin/sh" ;;
esac
contains "verifies the download against a checksum" \
  "$(cat "$repo/install.sh")" "shasum -a 256"
contains "clears the quarantine flag" \
  "$(cat "$repo/install.sh")" "com.apple.quarantine"
contains "refuses a Mac that cannot run pods" \
  "$(cat "$repo/install.sh")" "Apple silicon"
# A curl | sh installer that asks for a password is teaching the wrong thing
# about what ferry needs, and ferry needs root for nothing this installs.
case "$(grep -c '^[^#]*sudo' "$repo/install.sh")" in
  0) ok "never asks for sudo" ;;
  *) bad "install.sh uses sudo"; grep -n '^[^#]*sudo' "$repo/install.sh" | sed 's/^/      /' ;;
esac
# Without this the installer can only ever be exercised against a published
# GitHub release, which means the download, checksum and unpack path could not
# be run at all before shipping it.
contains "can be pointed at a mirror or a local release" \
  "$(cat "$repo/install.sh")" "FERRY_DOWNLOAD_BASE"
contains "and refuses that without a version, since there is no API to ask" \
  "$(cat "$repo/install.sh")" "needs FERRY_VERSION too"
echo

# --- what serves the installer --------------------------------------------
#
# The install command in the README is only true while the Pages site answers to
# the custom domain, and the thing that binds it is a CNAME file inside the
# published artifact. A deploy that omits it silently reverts the domain to
# imaustink.github.io -- the site stays up, so nothing looks broken, and every
# `curl -sfL https://get.ferry.kurpuis.com | sh -` in the docs stops working.
printf '\033[1m%s\033[0m\n' "what serves the installer"
pages="$repo/.github/workflows/pages.yml"
succeeds "there is a workflow to publish it" test -f "$pages"
host="$(sed -n 's|.*https://\(get\.ferry\.[a-z.]*\).*|\1|p' "$repo/install.sh" | head -1)"
is "the installer names the host it is served from" "$host" "get.ferry.kurpuis.com"
# The domain is a tracked file rather than a string in a workflow step, so it
# takes deleting something to lose it. The file is still only binding once the
# job copies it into the artifact -- with the Pages source set to GitHub
# Actions, nothing in the repository is served by itself.
succeeds "the domain is a file in the repository" test -f "$repo/CNAME"
is "naming that host, and nothing else" "$(cat "$repo/CNAME")" "$host"
contains "and the workflow copies it into the published site" "$(cat "$pages")" "cp CNAME _site/CNAME"
contains "and republishes when it changes" "$(cat "$pages")" "- CNAME"
# Served at / so the documented one-liner needs no path on the end.
contains "serving it at / as well as /install.sh" "$(cat "$pages")" "_site/index.html"
# ferry prints this host in 'token create' and in its release guards, so the two
# must not drift apart.
contains "and ferry defaults to the same host" \
  "$(grep FERRY_INSTALL_URL= "$repo/ferry")" "$host"

# `curl … | sh -` hands the script to sh on *stdin*, so the script's own stdin is
# the pipe, not the terminal. Anything in here that read a line would eat its own
# source and then run whatever was left of itself -- which is why the confirm
# prompt lives in `ferry uninstall`, a command run from a terminal, and not in
# the installer. An installer cannot ask questions.
case "$(grep -cE '(^|[^a-z])read[[:space:]]+(-[a-z]+[[:space:]]+)*[A-Za-z_]' "$repo/install.sh")" in
  0) ok "and never reads stdin, which a piped script cannot do" ;;
  *) bad "install.sh reads stdin; piped into sh that consumes its own source"
     grep -nE '(^|[^a-z])read[[:space:]]+' "$repo/install.sh" | sed 's/^/      /' ;;
esac
echo

printf '\033[1m%s\033[0m\n' "$pass passed$([ "$fail" -gt 0 ] && echo ", $fail failed")"
[ "$fail" -eq 0 ]
