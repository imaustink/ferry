#!/usr/bin/env bash
# Tests for the parts of the CLI that act on this Mac's files rather than on a
# cluster: what it writes into someone's kubeconfig, what it tells the kubelet,
# and what it reports about itself.
#
# Each of these was found by someone running a real workload on ferry, and each
# was invisible from inside a cluster that was working: two profiles quietly
# sharing one API server through a kubeconfig, a kubelet deleting every loaded
# image because the Mac's disk was full of photos, a version string describing
# a cluster that no longer existed.
#
#   ./tests/cli-test.sh
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

# --- image garbage collection ------------------------------------------------

printf '\033[1m%s\033[0m\n' "the kubelet does not garbage-collect images off a full Mac"
# imagefs is the Mac's data volume, so a percentage threshold measures the
# user's photos. Both kubelet configs -- the server's and a joined worker's --
# have to carry it; the report that found this had fixed only one heredoc and
# would have kept losing images on every worker.
is "both kubelet configs set the high threshold" \
  "$(grep -c '^imageGCHighThresholdPercent: 100$' "$repo/ferry")" 2
is "and the low one" \
  "$(grep -c '^imageGCLowThresholdPercent: 99$' "$repo/ferry")" 2
echo

# --- kubeconfig --merge ------------------------------------------------------

printf '\033[1m%s\033[0m\n' "kubeconfig --merge keeps two profiles apart"
if ! command -v kubectl >/dev/null 2>&1; then
  echo "  (skipped: kubectl is not installed)"
else
  # Two admin.confs shaped exactly as control-plane/up.sh writes them: the same
  # cluster, context and user names, different ports and certificates.
  admin_conf() { # dir port tag
    mkdir -p "$1/pki"
    echo "ca-$3" > "$1/pki/ca.crt"; echo "cert-$3" > "$1/pki/admin.crt"; echo "key-$3" > "$1/pki/admin.key"
    cat > "$1/admin.conf" <<YAML
apiVersion: v1
kind: Config
clusters:
- name: ferry
  cluster: {server: "https://127.0.0.1:$2", certificate-authority: $1/pki/ca.crt}
contexts:
- name: ferry
  context: {cluster: ferry, user: admin}
current-context: ferry
users:
- name: admin
  user: {client-certificate: $1/pki/admin.crt, client-key: $1/pki/admin.key}
YAML
  }
  admin_conf "$sandbox/.ferry" 6443 default
  admin_conf "$sandbox/.ferry-e2e" 18443 e2e
  mkdir -p "$sandbox/.kube"
  cat > "$sandbox/.kube/config" <<'YAML'
apiVersion: v1
kind: Config
clusters:
- name: mk
  cluster: {server: "https://192.0.2.1:8443"}
contexts:
- name: minikube
  context: {cluster: mk, user: mk}
current-context: minikube
users:
- name: mk
  user: {token: x}
YAML
  merge() { HOME="$sandbox" FERRY_PROFILE="$1" KUBECONFIG="" "$repo/ferry" kubeconfig --merge >/dev/null 2>&1; }
  field() { KUBECONFIG="$sandbox/.kube/config" kubectl config view --raw --minify --context="$1" -o jsonpath="{$2}"; }

  merge default; merge e2e
  is "the first profile's context still reaches its own API server" \
    "$(field ferry .clusters[0].cluster.server)" "https://127.0.0.1:6443"
  is "and the second profile's reaches its own" \
    "$(field ferry-e2e .clusters[0].cluster.server)" "https://127.0.0.1:18443"
  is "with its own certificate" \
    "$(field ferry-e2e '.users[0].user.client-key-data' | base64 -d)" "key-e2e"
  is "and the context that was selected is still selected" \
    "$(KUBECONFIG="$sandbox/.kube/config" kubectl config current-context)" "minikube"
  is "and nothing else in there was touched" \
    "$(field minikube .clusters[0].cluster.server)" "https://192.0.2.1:8443"

  # A profile recreated since the last merge has new certificates, and the old
  # ones already in the kubeconfig must not win.
  echo "key-e2e-recreated" > "$sandbox/.ferry-e2e/pki/admin.key"
  merge e2e
  is "merging again after a recreate takes the new certificate" \
    "$(field ferry-e2e '.users[0].user.client-key-data' | base64 -d)" "key-e2e-recreated"
  is "without leaving a second copy of the context" \
    "$(KUBECONFIG="$sandbox/.kube/config" kubectl config get-contexts -o name | grep -c '^ferry-e2e$')" 1
fi
echo

# --- version -----------------------------------------------------------------

printf '\033[1m%s\033[0m\n' "ferry version describes what is installed"
# A release that carries v1.34.0 on a Mac whose data directory last ran v1.37.0.
release="$sandbox/release"
mkdir -p "$release/lib" "$release/bin"
cp "$repo/ferry" "$release/ferry"; cp "$repo"/lib/*.sh "$release/lib/"
printf 'ferry=v9.9.9\nkubernetes=v1.34.0\ncontrol-plane=v1.34.11\netcd=v3.6.5\n' > "$release/VERSION"
mkdir -p "$sandbox/.ferry"
printf 'kubernetes=v1.37.0\ncontrol-plane=v1.37.0\netcd=v3.6.5\n' > "$sandbox/.ferry/version"
out="$(HOME="$sandbox" FERRY_PROFILE=default "$release/ferry" version 2>&1)"
contains "reports the release's Kubernetes" "$out" "kubernetes    v1.34.0"
contains "and its control plane" "$out" "control plane v1.34.11"
lacks "not the stale cluster's, as if it were installed" "$(echo "$out" | grep -v '^  cluster')" "v1.37.0"
contains "which is reported as what the stopped cluster last ran" "$out" "last started at kubernetes v1.37.0"
echo

printf '\033[1m%s\033[0m\n' "the runtime version the node reports is one the kubelet can parse"
# Anything that is not semver is shown as ferry://Unknown -- which is what the
# first attempt at this, "dev-<sha>", came out as.
semver='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
eval "$(sed -n '/^ferry_release_version()/,/^}/p; /^ferry_runtime_version()/,/^}/p' "$repo/ferry")"
v="$(here="$release" ferry_runtime_version)"
if [[ "${v#v}" =~ $semver ]]; then ok "a release: $v"; else bad "a release gives '$v'"; fi
v="$(here="$repo" ferry_runtime_version)"
if [[ "${v#v}" =~ $semver ]]; then ok "a checkout: $v"; else bad "a checkout gives '$v'"; fi
v="$(here="$sandbox" ferry_runtime_version)"
if [[ "${v#v}" =~ $semver ]]; then ok "neither: $v"; else bad "neither gives '$v'"; fi
echo

printf '\033[1m%s\033[0m\n' "a mode 2 pod's claim has somewhere to go"
# Each link in the chain is in a different process, and dropping any one of
# them puts the claim back to Pending with no event.
contains "ferry-node serve is handed the volumes directory" \
  "$(sed -n '/"\$here\/bin\/ferry-node" serve/,/ferry-node.log/p' "$repo/ferry")" '--volumes "$FERRY_HOME/volumes"'
contains "ferry-machined is told which Mac it labels machines with" \
  "$(sed -n '/"\$here\/bin\/ferry-machined"/,/ferry-machined.log/p' "$repo/ferry")" '--host-node "$NODE_NAME"'
contains "the Mac's own node carries the same label" \
  "$(sed -n '/^ensure_mode_label()/,/^}/p' "$repo/ferry")" 'ferry.dev/host=$NODE_NAME'
contains "the machine mounts the share before its kubelet starts" \
  "$(sed -n '/ferry.volumes/,/kubelet/p' "$repo/experiments/18-node-image/init.sh")" "mount -t virtiofs ferry-volumes"
echo

printf '\033[1m%s\033[0m\n' "no environment prefix is cut off by a comment"
# `FOO=x \` followed by a comment line joins into `FOO=x # ...`: an ordinary
# shell assignment, and the command below runs without it. Nothing fails. It
# happened twice -- to karpenter's machine limits, and to FERRY_NODE_DISK_SYNC,
# which left relaxed clusters' machines on the full disk barrier.
cut_off="$(awk 'prev ~ /\\$/ && $0 ~ /^[[:space:]]*#/ {print NR": "$0} {prev=$0}' "$repo/ferry")"
if [ -z "$cut_off" ]; then ok "every continued line continues into code"
else bad "a continued line runs into a comment: $cut_off"; fi
echo

printf '\033[1m%s\033[0m\n' "a machine can pull what the Mac has loaded"
# ErrImageNeverPull on a machine for an image `ferry image load` said it
# loaded. Four processes each hold one link.
contains "ferry-node is told the registry's port" \
  "$(sed -n '/FERRY_NODE_DISK_SYNC=/,/"\$here\/bin\/ferry-node" serve/p' "$repo/ferry")" 'FERRY_NODE_REGISTRY_PORT='
contains "which reaches the guest's command line" \
  "$(cat "$repo/experiments/18-node-image/Sources/ferry-node/main.swift")" '"ferry.registry=\(port)"'
contains "the guest makes it a mirror for every registry" \
  "$(sed -n '/ferry.registry/,/starting containerd/p' "$repo/experiments/18-node-image/init.sh")" "/etc/containerd/certs.d/_default/hosts.toml"
contains "and containerd reads that directory" \
  "$(cat "$repo/experiments/18-node-image/files/containerd-config.toml")" "config_path = '/etc/containerd/certs.d'"
contains "loading an image also stores it for machines" \
  "$(sed -n '/^cmd_image_load()/,/^}/p' "$repo/ferry")" 'machine_registry_add "$layout"'
contains "and ferry build builds the registry" \
  "$(sed -n '/^cmd_build()/,/^}/p' "$repo/ferry")" 'go build -o "$here/bin/ferry-registry"'
echo

# --- NetworkPolicy on a kernel without nf_tables ------------------------------

printf '\033[1m%s\033[0m\n' "NetworkPolicies are only called enforced where they can be"
# The fallback kernel has no nf_tables, and 'ferry up' said "enforced" on it
# while every rule apply in every pod failed.
netpol="$(sed -n '/^start_netpol()/,/^}/p' "$repo/ferry")"
contains "the fallback kernel is told apart" "$netpol" '[ "$KERNEL" != "$NAT_KERNEL" ]'
contains "  and said out loud" "$netpol" "NetworkPolicies NOT enforced"
echo

# --- ferry up on a running cluster -------------------------------------------

printf '\033[1m%s\033[0m\n' "ferry up on a cluster that is already up"
up_scratch="$(mktemp -d)"
# cmd_up alone, in a subshell, against a fake checkout and a process table of
# our choosing. It returns before starting anything in every case but the last,
# and align_to_cluster_version is where it would go on.
up_with() { # running-processes recorded-durability [args...]
  (
    up="$1"; printf '%s\n' "$2" > "$up_scratch/durability"; shift 2
    here="$up_scratch"; KERNEL="$up_scratch/vmlinux"; mkdir -p "$here/bin"
    touch "$here/bin/kubelet" "$here/bin/ferry-cri" "$here/bin/ferry-cni" "$KERNEL"
    DURABILITY_MARKER="$up_scratch/durability"; unset FERRY_DURABILITY
    eval "$(sed -n '/^ferry_durability()/,/^}/p' "$repo/ferry")"
    eval "$(sed -n '/^cmd_up()/,/^}/p' "$repo/ferry")"
    align_to_cluster_version() { echo STARTING; return 1; }
    warn() { echo "$*"; }; bad() { echo "$*"; }; ok() { echo "$*"; }
    running() { case " $up " in *" $1 "*) return 0 ;; esac; return 1; }
    cmd_up "$@"
  )
}
out="$(up_with "ferry-cri kubelet" full)"; is "exits 0 when it is already up" "$?" 0
lacks "  and starts nothing" "$out" STARTING
up_with "ferry-cri kubelet" full --fast >/dev/null; is "refuses a durability it was not started with" "$?" 1
up_with "ferry-cri kubelet" relaxed --fast >/dev/null; is "and accepts the one it was" "$?" 0
out="$(up_with kubelet full)"; is "a half-up cluster still refuses" "$?" 1
contains "  and says which half" "$out" "kubelet alone"
contains "a stopped cluster is started" "$(up_with "" full)" STARTING
rm -rf "$up_scratch"
echo

# --- small helpers -----------------------------------------------------------

printf '\033[1m%s\033[0m\n' "telling whether a gateway is on the profile's pod network"
eval "$(sed -n '/^ip_in_cidr()/,/^}/p' "$repo/ferry")"
if ip_in_cidr 10.162.0.1 10.162.0.0/16; then ok "an address inside the network"; else bad "an address inside the network"; fi
if ip_in_cidr 192.168.66.1 10.162.0.0/16; then bad "the vmnet fallback is not on it"; else ok "the vmnet fallback is not on it"; fi
if ip_in_cidr 10.163.0.1 10.162.0.0/16; then bad "nor is the next profile's"; else ok "nor is the next profile's"; fi
echo

# --- a Mac that joined, and nodes added to this one --------------------------

printf '\033[1m%s\033[0m\n' "a joined Mac enforces NetworkPolicy in its pods and at its edge"
# Measured before: a deny-all on a joined node's pod let every client through,
# pod and edge alike, because nothing on that Mac served ferry-netpol's socket.
worker="$(sed -n '/^start_worker()/,/^}/p' "$repo/ferry")"
contains "start_worker runs ferry-netpol as the node" "$worker" 'start_netpol "$FERRY_RUN/kubelet.conf"'
contains "and its ferry-proxy asks it" \
  "$(echo "$worker" | sed -n '/bin\/ferry-proxy"/,/ferry-proxy.log/p')" '--netpol-socket "$FERRY_NETPOL_SOCK"'
contains "and a token lets a node's certificate read what policy needs" \
  "$(sed -n '/^cmd_token_create()/,/^}/p' "$repo/ferry")" 'ferry_netpol_rbac'
echo

printf '\033[1m%s\033[0m\n' "an added node's podCIDR is the slice its runtime is on"
nodeadd="$(sed -n '/^cmd_node_add()/,/^}/p' "$repo/ferry")"
contains "a stale Node of that name goes before the index is chosen" \
  "$(echo "$nodeadd" | sed -n '1,/free_node_index/p')" 'stale_node_gone "$name"'
contains "and the Node is made with the slice as its podCIDR" "$nodeadd" 'podCIDR: $(node_slice "$index")'
lacks "and no slice is printed as 10.244 whatever the profile" "$(cat "$repo/ferry")" '10.244.$index'
eval "$(sed -n '/^node_slice()/,/^}/p' "$repo/ferry")"
is "node_slice follows the profile's network" "$(CLUSTER_CIDR=10.171.0.0/16 node_slice 2)" "10.171.2.0/24"
echo

printf '\033[1m%s\033[0m\n' "nft runs by PATH inside a pod, which is how portmap runs it"
contains "a bundle wanting /lib's loader is repackaged, not kept" \
  "$(cat "$repo/guest/build-nft.sh")" "grep -qa '/.ferry/lib/ld-musl-aarch64.so.1'"
contains "and a release refuses one" \
  "$(cat "$repo/release/build.sh")" "grep -qa '/.ferry/lib/ld-musl-aarch64.so.1'"
if [ -f "$repo/guest/nft/nft" ]; then
  if grep -qa '/.ferry/lib/ld-musl-aarch64.so.1' "$repo/guest/nft/nft"; then
    ok "and this checkout's bundle names the loader it ships"
  else
    bad "and this checkout's bundle names the loader it ships"; echo "      run ./guest/build-nft.sh"
  fi
fi
echo

printf '\033[1m%s\033[0m\n' "CoreDNS stays on the address the kubelets were told"
contains "it is pinned to the first node" "$(cat "$repo/manifests/coredns.yaml")" 'kubernetes.io/hostname: "__DNS_NODE__"'
contains "and ferry says which node that is" "$(sed -n '/^install_dns()/,/^}/p' "$repo/ferry")" 's|__DNS_NODE__|$NODE_NAME|g'
echo

printf '\033[1m%s\033[0m\n' "$pass passed$([ "$fail" -gt 0 ] && echo ", $fail failed")"
[ "$fail" -eq 0 ]
