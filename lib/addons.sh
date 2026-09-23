#!/usr/bin/env bash
# Addons: things everybody wants and nobody should have to hunt for.
#
# Sourced by ferry and by tests/addons-test.sh. An addon is a directory under
# addons/ holding ordinary Kubernetes manifests and an addon.conf that says what
# they are:
#
#   description=  one line for `ferry addons list`
#   version=      the upstream version the manifests are pinned to
#   namespace=    where its pods run; printed when it will not come up
#   requires=     other addons enabled first, space separated
#   source=       <url> <sha256> [<file name>], repeatable: a manifest fetched
#                 from upstream, checked, and cached so a second enable -- or
#                 one on a plane -- needs no network
#   server_side=  true to apply with --server-side, which a bundle of large CRDs
#                 needs: client-side apply keeps a copy of every object in an
#                 annotation, and a CRD past 256 KiB does not fit in one
#   check=        a shell command that succeeds once the addon works, retried
#                 until it does, repeatable
#   timeout=      seconds to wait for rollouts and checks, default 300
#
# Beside it, optionally: a kustomization.yaml, applied with kustomize, which is
# how a fetched upstream manifest gets a patch; NOTES, printed after enabling;
# and executable hooks named pre-enable, post-enable, pre-disable and
# post-disable, run with KUBECONFIG pointing at the cluster.
#
# What was applied is kept under $FERRY_HOME/addons/<name>/, which is what
# makes `list` accurate -- it used to guess from whether a namespace named after
# the addon existed -- and lets `disable` delete exactly what `enable` created,
# even after the addon's manifests have moved on in the repo.

ADDONS_DIR="${ADDONS_DIR:-$FERRY_ROOT/addons}"
ADDONS_STATE="${ADDONS_STATE:-$FERRY_HOME/addons}"
ADDONS_CACHE="${FERRY_ADDON_CACHE:-$FERRY_HOME/cache/addons}"

# addon_conf <name> <key>: every value of key, one per line.
addon_conf() {
  local file="$ADDONS_DIR/$1/addon.conf"
  [ -f "$file" ] || return 0
  sed -n "s/^$2=//p" "$file"
}

addon_enabled() { [ -f "$ADDONS_STATE/$1/manifest.yaml" ]; }

addon_names() {
  local dir
  for dir in "$ADDONS_DIR"/*/; do
    [ -d "$dir" ] && basename "$dir"
  done
}

addon_sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# addon_fetch <url> <sha256> <dest>: from the cache when it has it, which is
# checked again on the way out, and from the network otherwise.
addon_fetch() {
  local url="$1" want="$2" dest="$3" cached="$ADDONS_CACHE/$2"
  if [ -f "$cached" ] && [ "$(addon_sha256 "$cached")" = "$want" ]; then
    cp "$cached" "$dest"; return 0
  fi
  mkdir -p "$ADDONS_CACHE"
  if ! curl -fsSL --retry 2 -o "$cached.part" "$url"; then
    rm -f "$cached.part"
    echo "could not fetch $url, and it is not in $ADDONS_CACHE" >&2
    return 1
  fi
  local got; got="$(addon_sha256 "$cached.part")"
  if [ "$got" != "$want" ]; then
    rm -f "$cached.part"
    echo "$url changed upstream: sha256 $got, pinned $want" >&2
    return 1
  fi
  mv "$cached.part" "$cached"
  cp "$cached" "$dest"
}

# addon_render <name> <workdir>: writes <workdir>/manifest.yaml, the one file
# that is applied and later deleted.
addon_render() {
  local name="$1" work="$2" src="$ADDONS_DIR/$1" file
  mkdir -p "$work/tree"
  local dns=""; [ -n "${FERRY_RUN:-}" ] && dns="$(cat "$FERRY_RUN/cri/dns" 2>/dev/null)"
  for file in "$src"/*.yaml; do
    [ -f "$file" ] || continue
    sed -e "s|__CLUSTER_DNS__|$dns|g" -e "s|__NODE_NAME__|${NODE_NAME:-}|g" \
        -e "s|__LOAD_BALANCER_IP__|${LAN_IP:-}|g" \
      "$file" > "$work/tree/$(basename "$file")"
  done
  local url sha as
  local fetched=()
  while read -r url sha as; do
    [ -n "$url" ] || continue
    as="${as:-$(basename "$url")}"
    addon_fetch "$url" "$sha" "$work/tree/$as" || return 1
    fetched+=("$work/tree/$as")
  done < <(addon_conf "$name" source)

  if [ -f "$work/tree/kustomization.yaml" ]; then
    kubectl kustomize "$work/tree" > "$work/manifest.yaml" || return 1
  else
    # Fetched files first: they are usually the CRDs the local ones use.
    : > "$work/manifest.yaml"
    local seen=" "
    for file in ${fetched[@]+"${fetched[@]}"} "$work"/tree/*.yaml; do
      [ -f "$file" ] || continue
      case "$seen" in *" $file "*) continue ;; esac
      seen="$seen$file "
      { echo "---"; echo "# source: $(basename "$file")"; cat "$file"; echo; } >> "$work/manifest.yaml"
    done
  fi
}

# Every Deployment, StatefulSet and DaemonSet in a manifest, as kind/ns/name.
# custom-columns rather than a jsonpath over .items: a manifest of one object
# comes back as that object, not as a List, and .items is then empty.
addon_workloads() {
  kubectl get -f "$1" --ignore-not-found --no-headers \
    -o custom-columns=K:.kind,NS:.metadata.namespace,N:.metadata.name 2>/dev/null |
    awk '$1 ~ /^(Deployment|StatefulSet|DaemonSet)$/ {print $1 "/" $2 "/" $3}'
}

# addon_wait <name> <manifest>: every rollout finished and every check passing,
# within the addon's timeout. Says what is stuck when it gives up.
addon_wait() {
  local name="$1" manifest="$2"
  local timeout; timeout="${FERRY_ADDON_TIMEOUT:-$(addon_conf "$name" timeout)}"
  timeout="${timeout:-300}"
  local deadline=$(( $(date +%s) + timeout )) kind ns obj left

  for obj in $(addon_workloads "$manifest"); do
    kind="${obj%%/*}"; obj="${obj#*/}"; ns="${obj%%/*}"; obj="${obj#*/}"
    left=$(( deadline - $(date +%s) )); [ "$left" -gt 0 ] || left=1
    if ! kubectl -n "$ns" rollout status "$kind/$obj" --timeout="${left}s" >/dev/null 2>&1; then
      echo "$kind $ns/$obj did not roll out within ${timeout}s"
      addon_why "$ns"
      return 1
    fi
  done

  local check
  while IFS= read -r check; do
    [ -n "$check" ] || continue
    until sh -c "$check" >/dev/null 2>&1; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "check did not pass within ${timeout}s: $check"
        sh -c "$check" 2>&1 | tail -5 | sed 's/^/    /'
        return 1
      fi
      sleep 2
    done
  done < <(addon_conf "$name" check)
}

# What a namespace's pods are waiting on. An image without linux/arm64 shows up
# here, as does a pod the scheduler could not place.
addon_why() {
  local ns="$1"
  kubectl -n "$ns" get pods -o wide 2>&1 | sed 's/^/    /'
  kubectl -n "$ns" get pods -o jsonpath='{range .items[*].status.containerStatuses[*]}{.name}: {.state.waiting.reason} {.state.waiting.message}{"\n"}{end}' 2>/dev/null |
    grep -v ': *$' | sed 's/^/    /'
  kubectl -n "$ns" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null |
    tail -5 | sed 's/^/    /'
}

addon_hook() { # name hook
  local hook="$ADDONS_DIR/$1/$2"
  [ -x "$hook" ] || return 0
  ADDON_DIR="$ADDONS_DIR/$1" ADDON_STATE="$ADDONS_STATE/$1" "$hook" 2>&1 | sed 's/^/  /'
  return "${PIPESTATUS[0]}"
}

addon_apply() { # name manifest
  local args=(apply -f "$2")
  [ "$(addon_conf "$1" server_side)" = true ] && args=(apply --server-side --force-conflicts -f "$2")
  local out
  out="$(kubectl "${args[@]}" 2>&1)" && return 0
  # A custom resource applied alongside its own CRD fails the first time,
  # before the CRD is established. Once it is, the second pass succeeds.
  case "$out" in
    *"ensure CRDs are installed first"*|*"no matches for kind"*)
      kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null 2>&1
      out="$(kubectl "${args[@]}" 2>&1)" && return 0 ;;
  esac
  echo "$out" | grep -v -E ' (created|configured|unchanged|serverside-applied)$' | tail -20 | sed 's/^/    /'
  return 1
}

addon_enable() { # name [--no-wait]
  local name="$1" wait=true
  [ "${2:-}" = --no-wait ] && wait=false
  [ -d "$ADDONS_DIR/$name" ] || { bad "no addon called $name"; return 1; }

  local dep
  for dep in $(addon_conf "$name" requires); do
    addon_enabled "$dep" && continue
    addon_enable "$dep" "${2:-}" || { bad "$name needs $dep, which did not come up"; return 1; }
    echo
  done

  local version; version="$(addon_conf "$name" version)"
  bold "enabling $name${version:+ $version}"
  local work; work="$(mktemp -d)"
  if ! addon_render "$name" "$work" 2> "$work/err"; then
    bad "could not render $name"; sed 's/^/    /' "$work/err"; rm -rf "$work"; return 1
  fi
  addon_hook "$name" pre-enable || { bad "pre-enable failed"; rm -rf "$work"; return 1; }
  local started; started="$(date +%s)"
  if ! addon_apply "$name" "$work/manifest.yaml"; then
    bad "kubectl could not apply $name"; rm -rf "$work"; return 1
  fi
  # Recorded as soon as anything is applied, so a half-enabled addon can still
  # be disabled cleanly.
  mkdir -p "$ADDONS_STATE/$name"
  cp "$work/manifest.yaml" "$ADDONS_STATE/$name/manifest.yaml"
  echo "$version" > "$ADDONS_STATE/$name/version"
  rm -rf "$work"
  ok "applied"

  if [ "$wait" = true ]; then
    if ! addon_wait "$name" "$ADDONS_STATE/$name/manifest.yaml" | sed 's/^/  /'; then
      bad "$name did not become ready; it is left applied. ferry addons disable $name removes it"
      return 1
    fi
    ok "ready in $(( $(date +%s) - started ))s"
  fi
  addon_hook "$name" post-enable || warn "post-enable hook failed"
  [ -f "$ADDONS_DIR/$name/NOTES" ] && { echo; sed 's/^/  /' "$ADDONS_DIR/$name/NOTES"; }
  return 0
}

addon_disable() { # name
  local name="$1" manifest="$ADDONS_STATE/$1/manifest.yaml" work=""
  if [ ! -f "$manifest" ]; then
    # Enabled before ferry kept a record, or never: delete what enabling it now
    # would create, which is the best guess there is.
    [ -d "$ADDONS_DIR/$name" ] || { bad "no addon called $name"; return 1; }
    work="$(mktemp -d)"
    addon_render "$name" "$work" 2>/dev/null || { bad "could not render $name"; rm -rf "$work"; return 1; }
    manifest="$work/manifest.yaml"
  fi
  bold "disabling $name"
  local other
  for other in $(addon_names); do
    [ "$other" != "$name" ] && addon_enabled "$other" || continue
    case " $(addon_conf "$other" requires) " in
      *" $name "*) warn "$other is enabled and requires $name" ;;
    esac
  done
  addon_hook "$name" pre-disable || true
  local out
  if ! out="$(kubectl delete -f "$manifest" --ignore-not-found --timeout=180s 2>&1)"; then
    bad "kubectl could not delete everything"
    echo "$out" | grep -v ' deleted' | tail -10 | sed 's/^/    /'
    [ -n "$work" ] && rm -rf "$work"
    return 1
  fi
  [ -n "$work" ] && rm -rf "$work"
  rm -rf "${ADDONS_STATE:?}/$name"
  addon_hook "$name" post-disable || true
  ok "removed"
}

addon_list() {
  bold "addons"
  local name version description state
  for name in $(addon_names); do
    version="$(addon_conf "$name" version)"
    description="$(addon_conf "$name" description)"
    state=""
    if addon_enabled "$name"; then
      state="enabled"
      local was; was="$(cat "$ADDONS_STATE/$name/version" 2>/dev/null)"
      [ "$was" != "$version" ] && state="enabled at $was; enable again for $version"
      printf '  \033[32m✓\033[0m %-18s %-9s %s (%s)\n' "$name" "$version" "$description" "$state"
    else
      printf '    %-18s %-9s %s\n' "$name" "$version" "$description"
    fi
  done
  echo
  echo "  ferry addons enable <name>     ferry addons disable <name>"
}

# The images an addon runs, and whether each has a linux/arm64 build -- which a
# pod here must have, since it is an arm64 VM. Asks the registries directly,
# anonymously, the way a pull would.
addon_images() { # name
  local name="$1" work; work="$(mktemp -d)"
  addon_render "$name" "$work" || { rm -rf "$work"; return 1; }
  local image
  for image in $(grep -oE '^[[:space:]-]*image:[[:space:]]*"?[^"[:space:]]+' "$work/manifest.yaml" |
                   sed -E 's/.*image:[[:space:]]*"?//' | sort -u); do
    case "$(image_platforms "$image" 2>/dev/null)" in
      *linux/arm64*) ok "$image" ;;
      "")            warn "$image (could not ask its registry)" ;;
      *)             bad "$image has no linux/arm64 build" ;;
    esac
  done
  rm -rf "$work"
}

# image_ref_parts <ref>: "<registry host> <repository> <tag or digest>", by the
# rules a pull uses: the first component is a registry only if it looks like a
# host, and a bare name is Docker Hub's library.
image_ref_parts() {
  local ref="$1" domain="docker.io" path tag
  case "$ref" in
    */*) case "${ref%%/*}" in *.*|*:*|localhost) domain="${ref%%/*}"; ref="${ref#*/}" ;; esac ;;
  esac
  [ "$domain" = docker.io ] && { domain=registry-1.docker.io; case "$ref" in */*) ;; *) ref="library/$ref" ;; esac; }
  path="${ref%@*}"; tag=latest
  case "${path##*/}" in *:*) tag="${path##*:}"; path="${path%:*}" ;; esac
  case "$ref" in *@*) tag="${ref#*@}" ;; esac
  echo "$domain $path $tag"
}

# image_platforms <ref>: os/arch of each image in a manifest list, one per line.
image_platforms() {
  local domain path tag
  read -r domain path tag < <(image_ref_parts "$1")
  local accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
  local url="https://$domain/v2/$path/manifests/$tag" auth="" challenge
  challenge="$(curl -sIL "$url" -H "Accept: $accept" | grep -i '^www-authenticate:')"
  case "$challenge" in
    *[Bb]earer*)
      local realm service
      realm="$(echo "$challenge" | sed -nE 's/.*realm="([^"]+)".*/\1/p' | head -1)"
      service="$(echo "$challenge" | sed -nE 's/.*service="([^"]+)".*/\1/p' | head -1)"
      local token; token="$(curl -fsS "$realm?service=$service&scope=repository:$path:pull" | jq -r '.token // .access_token')"
      auth="Authorization: Bearer $token" ;;
  esac
  local body; body="$(curl -fsSL "$url" -H "Accept: $accept" ${auth:+-H "$auth"})" || return 1
  if echo "$body" | jq -e '.manifests' >/dev/null 2>&1; then
    echo "$body" | jq -r '.manifests[].platform | select(.) | "\(.os)/\(.architecture)"' | grep -v unknown
  else
    # A single image: its platform lives in the config blob.
    local digest; digest="$(echo "$body" | jq -r '.config.digest')"
    curl -fsSL "https://$domain/v2/$path/blobs/$digest" ${auth:+-H "$auth"} | jq -r '"\(.os)/\(.architecture)"'
  fi
}
