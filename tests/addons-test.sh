#!/usr/bin/env bash
# Tests for the addon mechanism in lib/addons.sh, without a cluster.
#
# What is checked is what went wrong, or would have, before there was a
# mechanism: `list` guessing from namespace names, a pinned upstream manifest
# changing underneath its pin, an enable on a plane having nothing to apply,
# and `disable` deleting whatever the repo holds now rather than what was
# applied then.
#
#   ./tests/addons-test.sh
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
lacks() { # description haystack needle
  case "$2" in *"$3"*) bad "$1"; echo "      '$2' contains '$3'" ;; *) ok "$1" ;; esac
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { :; }

# --- the addons in the repo ----------------------------------------------------

bold "every addon in the repo is well formed"
FERRY_ROOT="$repo" FERRY_HOME="$sandbox/home"
# shellcheck source=../lib/addons.sh
. "$repo/lib/addons.sh"
for name in $(addon_names); do
  dir="$repo/addons/$name"
  [ -n "$(addon_conf "$name" description)" ] && [ -n "$(addon_conf "$name" version)" ] \
    && ok "$name has a description and a version" || bad "$name lacks a description or version"
  while read -r url sha as; do
    [ -n "$url" ] || continue
    case "$url" in https://*) ;; *) bad "$name: source is not https: $url" ;; esac
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] && ok "$name pins $(basename "${as:-$url}") by sha256" \
      || bad "$name: source $url has no sha256"
    # Every version in a URL is the one the addon says it is, or the list lies.
    version="$(addon_conf "$name" version)"
    case "$url" in *"$version"*) ;; *) bad "$name: $url is not $version" ;; esac
  done < <(addon_conf "$name" source)
  for hook in pre-enable post-enable pre-disable post-disable; do
    [ -e "$dir/$hook" ] || continue
    [ -x "$dir/$hook" ] && ok "$name/$hook is executable" || bad "$name/$hook is not executable"
  done
  for dep in $(addon_conf "$name" requires); do
    [ -d "$repo/addons/$dep" ] && ok "$name requires $dep, which exists" || bad "$name requires missing $dep"
  done
  # Images in the repo's own YAML must name a tag: `:latest` is a different
  # program every week, and a pod here is an arm64 VM that needs the build to
  # exist. Upstream files are checked by `ferry addons images`.
  for file in "$dir"/*.yaml; do
    [ -f "$file" ] || continue
    for image in $(sed -nE 's/^[[:space:]-]*image:[[:space:]]*"?([^"[:space:]]+).*/\1/p' "$file"); do
      case "${image##*/}" in
        *:latest) bad "$name: $image is :latest" ;;
        *:*|*@*)  ok "$name runs $image" ;;
        *)        bad "$name: $image has no tag" ;;
      esac
    done
  done
done
lacks "the registry is not on 5000, which AirPlay holds" \
  "$(grep -h 'hostPort' "$repo/addons/registry/registry.yaml")" "5000"

# --- addon.conf ----------------------------------------------------------------

bold "addon.conf is read the way it is documented"
ADDONS_DIR="$sandbox/addons"; ADDONS_STATE="$sandbox/state"; ADDONS_CACHE="$sandbox/cache"
mkdir -p "$ADDONS_DIR/demo"
printf 'hello: world\n' > "$sandbox/upstream.yaml"
upstream_sha="$(shasum -a 256 "$sandbox/upstream.yaml" | cut -d' ' -f1)"
cat > "$ADDONS_DIR/demo/addon.conf" <<EOF
# check=a comment, not a check
#check=false
description=a demo, with = in it
version=v1
requires=a b
source=file://$sandbox/upstream.yaml $upstream_sha
check=true
check=test 1 -eq 1
EOF
is "a value may contain '='" "$(addon_conf demo description)" "a demo, with = in it"
is "a repeated key gives every value, and commented ones none" \
  "$(addon_conf demo check | tr '\n' '|')" "true|test 1 -eq 1|"
is "a missing key is empty" "$(addon_conf demo namespace)" ""
is "a missing addon.conf is empty" "$(addon_conf nothing description)" ""

# --- fetching ------------------------------------------------------------------

bold "a pinned source is fetched once, checked, and served from cache"
addon_fetch "file://$sandbox/upstream.yaml" "$upstream_sha" "$sandbox/got.yaml" 2>/dev/null
is "fetched content" "$(cat "$sandbox/got.yaml")" "hello: world"
[ -f "$ADDONS_CACHE/$upstream_sha" ] && ok "cached under its sha256" || bad "not cached"
mv "$sandbox/upstream.yaml" "$sandbox/upstream.gone"
rm -f "$sandbox/got.yaml"
addon_fetch "file://$sandbox/upstream.yaml" "$upstream_sha" "$sandbox/got.yaml" 2>/dev/null \
  && ok "the cache answers when the network cannot" || bad "offline fetch failed with a cache"
mv "$sandbox/upstream.gone" "$sandbox/upstream.yaml"

printf 'hello: someone else\n' > "$sandbox/changed.yaml"
rm "$ADDONS_CACHE/$upstream_sha"
err="$(addon_fetch "file://$sandbox/changed.yaml" "$upstream_sha" "$sandbox/x.yaml" 2>&1)" \
  && bad "a changed upstream was accepted" || ok "a changed upstream is refused"
contains "and says so, with both hashes" "$err" "changed upstream"
[ -e "$ADDONS_CACHE/$upstream_sha" ] && bad "the changed bytes were cached" || ok "and nothing is cached"
addon_fetch "file://$sandbox/upstream.yaml" "$upstream_sha" "$sandbox/got.yaml" 2>/dev/null

echo "tampered" > "$ADDONS_CACHE/$upstream_sha"
addon_fetch "file://$sandbox/upstream.yaml" "$upstream_sha" "$sandbox/y.yaml" 2>/dev/null
is "a corrupted cache entry is fetched again" "$(cat "$sandbox/y.yaml")" "hello: world"

# --- rendering -----------------------------------------------------------------

bold "rendering substitutes, orders, and uses kustomize when asked"
cat > "$ADDONS_DIR/demo/local.yaml" <<'EOF'
dns: __CLUSTER_DNS__
node: __NODE_NAME__
lb: __LOAD_BALANCER_IP__
EOF
mkdir -p "$sandbox/run/cri"; echo 10.9.0.2 > "$sandbox/run/cri/dns"
FERRY_RUN="$sandbox/run" NODE_NAME=ferry-mac-t LAN_IP=192.0.2.7 addon_render demo "$sandbox/r1"
manifest="$(cat "$sandbox/r1/manifest.yaml")"
contains "cluster DNS substituted" "$manifest" "dns: 10.9.0.2"
contains "node name substituted" "$manifest" "node: ferry-mac-t"
contains "LoadBalancer address substituted" "$manifest" "lb: 192.0.2.7"
first="$(grep -m1 '^# source:' "$sandbox/r1/manifest.yaml")"
is "fetched sources come first, ahead of what uses their CRDs" "$first" "# source: upstream.yaml"
is "each file once" "$(grep -c '^# source:' "$sandbox/r1/manifest.yaml")" "2"

if command -v kubectl >/dev/null; then
  cat > "$ADDONS_DIR/demo/cm.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: demo}
data: {a: "1"}
EOF
  printf 'hello: world\n' > "$sandbox/upstream.yaml"
  cat > "$ADDONS_DIR/demo/kustomization.yaml" <<'EOF'
resources: [cm.yaml]
namespace: demo-ns
EOF
  addon_render demo "$sandbox/r2" 2>/dev/null
  contains "a kustomization is built, not concatenated" "$(cat "$sandbox/r2/manifest.yaml")" "namespace: demo-ns"
  rm "$ADDONS_DIR/demo/kustomization.yaml" "$ADDONS_DIR/demo/cm.yaml"
fi

# --- state ---------------------------------------------------------------------

bold "enabled means recorded, not guessed"
list="$(addon_list)"
lacks "nothing is enabled with no record" "$list" "enabled"
mkdir -p "$ADDONS_STATE/demo"; : > "$ADDONS_STATE/demo/manifest.yaml"; echo v1 > "$ADDONS_STATE/demo/version"
contains "a record makes it enabled" "$(addon_list)" "(enabled)"
echo v0 > "$ADDONS_STATE/demo/version"
contains "an older record says to enable again" "$(addon_list)" "enabled at v0; enable again for v1"

# --- image references ----------------------------------------------------------

bold "image references resolve to the registry a pull would ask"
is "bare name"          "$(image_ref_parts busybox)"                       "registry-1.docker.io library/busybox latest"
is "tag with no domain" "$(image_ref_parts registry:3.1.1)"                "registry-1.docker.io library/registry 3.1.1"
is "user repository"    "$(image_ref_parts envoyproxy/gateway:v1.9.1)"     "registry-1.docker.io envoyproxy/gateway v1.9.1"
is "other registry"     "$(image_ref_parts quay.io/jetstack/cert-manager-webhook:v1.21.2)" "quay.io jetstack/cert-manager-webhook v1.21.2"
is "port in domain"     "$(image_ref_parts localhost:5001/app)"            "localhost:5001 app latest"
is "tag and digest"     "$(image_ref_parts registry.k8s.io/x/c:v1@sha256:abc)" "registry.k8s.io x/c sha256:abc"

echo
if [ "$fail" -eq 0 ]; then printf '\033[1m%s\033[0m\n' "$pass passed"
else printf '\033[1m%s\033[0m\n' "$fail of $((pass + fail)) failed"; exit 1; fi
