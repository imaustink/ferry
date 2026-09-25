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
netpol="$(sed -n '/^netpol_verdict()/,/^}/p' "$repo/ferry")"
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
    FERRY_CONFIG="$up_scratch/config.yaml"; rm -f "$FERRY_CONFIG"
    MACHINES_MARKER="$up_scratch/machines-enabled"
    eval "$(grep '^FERRY_CONFIG_API=' "$repo/ferry")"
    for fn in ferry_config_get ferry_config_set ferry_config_migrate durability_normalize; do
      eval "$(sed -n "/^$fn()/,/^}/p" "$repo/ferry")"
    done
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
# The levels are named for what they survive now. The old names are what
# every existing cluster has recorded, so they have to keep meaning the same.
up_with "ferry-cri kubelet" relaxed --disposable >/dev/null; is "--disposable is the level 'relaxed' recorded" "$?" 0
up_with "ferry-cri kubelet" process-crash --durability relaxed >/dev/null; is "  and the old name on the flag is the new level" "$?" 0
up_with "ferry-cri kubelet" full --durability power-loss >/dev/null; is "  as 'full' is power-loss" "$?" 0
up_with "ferry-cri kubelet" power-loss --disposable >/dev/null; is "  and a disposable ask of a power-loss cluster is refused" "$?" 1
out="$(up_with "" full --durability sometimes)"; is "a level that is not one is refused" "$?" 2
contains "  naming the ones that are" "$out" "expected 'power-loss' or 'process-crash'"
lacks "  before anything starts" "$out" STARTING
out="$(up_with kubelet full)"; is "a half-up cluster still refuses" "$?" 1
contains "  and says which half" "$out" "kubelet alone"
contains "a stopped cluster is started" "$(up_with "" full)" STARTING
rm -rf "$up_scratch"
echo

# --- the config file ---------------------------------------------------------

printf '\033[1m%s\033[0m\n' "a cluster's choices are a file, not markers"
# The benchmark harness passed --durability once, --purge kept the marker, and
# four columns were measured on a setting nobody chose for them.
cfg_scratch="$sandbox/config"
mkdir -p "$cfg_scratch"
# In this shell rather than a subshell, so the counts below are counted.
FERRY_CONFIG="$cfg_scratch/config.yaml"
DURABILITY_MARKER="$cfg_scratch/durability"; MACHINES_MARKER="$cfg_scratch/machines-enabled"
unset FERRY_DURABILITY
eval "$(grep '^FERRY_CONFIG_API=' "$repo/ferry")"
for fn in ferry_config_get ferry_config_set ferry_config_unset ferry_config_migrate \
          durability_normalize ferry_durability machines_enabled; do
  eval "$(sed -n "/^$fn()/,/^}/p" "$repo/ferry")"
done
cat > "$FERRY_CONFIG" <<'YAML'
# a comment someone wrote
apiVersion: ferry.dev/v1alpha1
kind: FerryConfig
durability: "relaxed"   # quoted, and commented
# machines: true
YAML
is "a value is read without its quotes or its comment" "$(ferry_config_get durability)" relaxed
is "  and an old name still means its level" "$(ferry_durability)" process-crash
is "a commented-out key is not a value" "$(ferry_config_get machines)" ""
ferry_config_set durability power-loss
is "setting a key replaces it in place" "$(grep -c '^durability:' "$FERRY_CONFIG")" 1
is "  and says what was set" "$(ferry_config_get durability)" power-loss
contains "  keeping every comment around it" "$(cat "$FERRY_CONFIG")" "# a comment someone wrote"
ferry_config_set machines true
is "a new key is added" "$(ferry_config_get machines)" true
if machines_enabled; then ok "  and machines are on because the file says so"; else bad "  and machines are on because the file says so"; fi
ferry_config_unset machines
is "unsetting removes only that key" "$(ferry_config_get machines)$(ferry_config_get durability)" power-loss
FERRY_DURABILITY=relaxed; is "the environment still wins for one run" "$(ferry_durability)" process-crash
unset FERRY_DURABILITY

# A cluster from before the file: its markers are read, then moved.
rm -f "$FERRY_CONFIG"; echo relaxed > "$DURABILITY_MARKER"; : > "$MACHINES_MARKER"
is "an unmigrated cluster's durability marker is still read" "$(ferry_durability)" process-crash
if machines_enabled; then ok "  and its machines marker"; else bad "  and its machines marker"; fi
ferry_config_migrate
is "migrating writes the durability into the file, in its new name" "$(ferry_config_get durability)" process-crash
is "  and machines" "$(ferry_config_get machines)" true
if [ ! -e "$DURABILITY_MARKER" ] && [ ! -e "$MACHINES_MARKER" ]; then ok "  and removes both markers"
else bad "  and removes both markers"; fi
# A file someone wrote wins over a marker nobody remembers.
ferry_config_set durability power-loss; echo relaxed > "$DURABILITY_MARKER"
ferry_config_migrate
is "migration never overwrites what the file already says" "$(ferry_config_get durability)" power-loss
unset FERRY_CONFIG DURABILITY_MARKER MACHINES_MARKER
# Through the CLI, against a state directory of our own.
# FERRY_PROFILES too, or the profile is registered in the real ~/.ferry-profiles.
cfg_env=(env FERRY_HOME="$cfg_scratch/home" FERRY_RUN="$cfg_scratch/run" FERRY_PROFILE=cfgtest FERRY_PROFILES="$cfg_scratch/profiles")
mkdir -p "$cfg_scratch/home"
# --machines false, so the answers do not depend on whether mode 2 is built here.
out="$("${cfg_env[@]}" "$repo/ferry" init --purpose ci --machines false --yes </dev/null 2>&1)"
contains "ferry init writes a config file from flags alone" "$out" "wrote $cfg_scratch/home/config.yaml"
cfg="$(cat "$cfg_scratch/home/config.yaml" 2>/dev/null)"
contains "  versioned like a Kubernetes config" "$cfg" "apiVersion: ferry.dev/v1alpha1"
contains "  with the purpose it was given" "$cfg" "purpose: ci"
contains "  and that purpose's durability" "$cfg" "durability: process-crash"
out="$("${cfg_env[@]}" "$repo/ferry" init --yes </dev/null 2>&1)"; rc=$?
is "  and will not overwrite it unasked" "$rc" 1
contains "  saying how to change it instead" "$out" "ferry init --force"
out="$("${cfg_env[@]}" "$repo/ferry" init --purpose prod --yes --force </dev/null 2>&1)"; rc=$?
is "a purpose that is not one is refused" "$rc" 2
contains "  before any file is written" "$(cat "$cfg_scratch/home/config.yaml")" "purpose: ci"
out="$("${cfg_env[@]}" FERRY_POD_MEMORY_MIB=1024 "$repo/ferry" config 2>&1)"
contains "ferry config says where a value came from" "$out" "process-crash    file"
contains "  including one the environment set for this run" "$out" "FERRY_POD_MEMORY_MIB, this run only"
"${cfg_env[@]}" "$repo/ferry" config set podMemoryMiB 768 >/dev/null 2>&1
is "a pass-through setting is written" "$("${cfg_env[@]}" "$repo/ferry" config get podMemoryMiB)" 768
out="$("${cfg_env[@]}" "$repo/ferry" config set podMemoryMiB lots 2>&1)"; rc=$?
is "  and validated" "$rc" 2
out="$("${cfg_env[@]}" "$repo/ferry" config set nonsense 1 2>&1)"; rc=$?
is "an unknown key is refused" "$rc" 2
contains "  naming the ones there are" "$out" "settings: purpose durability"
contains "ferry init writes a default runtime" "$cfg" "defaultRuntime: ferry-vm"
out="$("${cfg_env[@]}" "$repo/ferry" config set defaultRuntime ferry-kata 2>&1)"; rc=$?
is "a default runtime that is not one is refused" "$rc" 2
contains "  naming the ones that are" "$out" "ferry-vm | ferry-shared | none"
"${cfg_env[@]}" "$repo/ferry" config set defaultRuntime ferry-shared >/dev/null 2>&1
out="$("${cfg_env[@]}" "$repo/ferry" config 2>&1)"
contains "a ferry-shared default says it waits for machines" "$out" "ferry-shared waits for machines"
is "  and is none in effect until they run" \
  "$(cd "$repo" && "${cfg_env[@]}" bash -c 'eval "$(sed -n "/^ferry_config_get()/,/^}/p;/^ferry_default_runtime()/,/^}/p;/^ferry_default_runtime_effective()/,/^}/p;/^machines_enabled()/,/^}/p" ferry)"; FERRY_CONFIG="$FERRY_HOME/config.yaml"; MACHINES_MARKER=/nonexistent; ferry_default_runtime_effective')" none
out="$("${cfg_env[@]}" "$repo/ferry" init --force --yes --machines false --default-runtime ferry-shared </dev/null 2>&1)"; rc=$?
is "ferry init refuses a ferry-shared default with no machines" "$rc" 1

# A machine's disk follows the cluster unless machineDurability says.
machine_sync() { # config-durability config-machine-durability
  (
    FERRY_CONFIG="$cfg_scratch/md.yaml"; DURABILITY_MARKER=/nonexistent
    printf 'durability: %s\n%s\n' "$1" "${2:+machineDurability: $2}" > "$FERRY_CONFIG"
    unset FERRY_DURABILITY FERRY_MACHINE_DURABILITY
    for fn in ferry_config_get durability_normalize ferry_durability durability_is_process_crash \
              ferry_machine_durability machine_disk_sync; do
      eval "$(sed -n "/^$fn()/,/^}/p" "$repo/ferry")"
    done
    machine_disk_sync
  )
}
is "a power-loss cluster's machines fsync, as before" "$(machine_sync power-loss "")" fsync
is "a process-crash cluster's machines drop the barrier, as before" "$(machine_sync process-crash "")" none
is "machineDurability power-loss is the full barrier" "$(machine_sync process-crash power-loss)" full
is "  and os-crash is fsync whatever the cluster is" "$(machine_sync process-crash os-crash)" fsync
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
contains "start_worker follows the control plane's ferry-netpol as the node" "$worker" \
  'start_netpol_follower "$server" "$FERRY_RUN/kubelet.conf"'
contains "and its ferry-proxy asks it" \
  "$(echo "$worker" | sed -n '/bin\/ferry-proxy"/,/ferry-proxy.log/p')" '--netpol-socket "$FERRY_NETPOL_SOCK"'
leader="$(sed -n '/^start_netpol()/,/^}/p' "$repo/ferry")"
contains "the control plane serves the other Macs' nodes their rules" "$leader" '--listen "0.0.0.0:$NETPOL_PEER_PORT"'
contains "presenting the API server's certificate" "$leader" '--tls-cert "$FERRY_HOME/pki/apiserver.crt"'
PORT_SHIFT=3000
eval "$(sed -n '/^NETPOL_PEER_PORT=/p' "$repo/ferry")"
follower="$(sed -n '/^start_netpol_follower()/,/^}/p' "$repo/ferry")"
server="192.168.1.29:$(( 6443 + PORT_SHIFT ))"
eval "$(echo "$follower" | grep -m1 'local upstream=' | sed 's/^ *local //; s/ flags=() conf$//')"
is "a joined Mac finds the peer port one above the API server's" "$upstream" "192.168.1.29:$NETPOL_PEER_PORT"
# Measured before: pods on a Mac joined to a cluster on 10.182.0.0/16 were told
# DNS was at 10.244.0.2, and resolved nothing.
lacks "a joined Mac's DNS is not the default CIDR's whatever the cluster's" "$worker" 'clusterDNS: [10.244.0.2]'
dns_line="$(echo "$worker" | grep -m1 'dns="${CLUSTER_CIDR')"
CLUSTER_CIDR=10.182.0.0/16; dns=10.244.0.2; eval "$dns_line"
is "  it is .2 of the first node's slice of the cluster's" "$dns" 10.182.0.2
# Measured before: every kubelet credential in the cluster could list every
# pod, which is wider than the Node authorizer allows. Nothing grants it now,
# and a cluster that has it loses it.
token="$(sed -n '/^cmd_token_create()/,/^}/p' "$repo/ferry")"
contains "a token takes the old grant away" "$token" 'ferry_netpol_rbac_remove'
contains "and so does starting the control plane" "$leader" 'ferry_netpol_rbac_remove'
lacks "and nothing in ferry makes it any more" "$(cat "$repo/ferry")" 'metadata: {name: ferry-node-netpol}'
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

printf '\033[1m%s\033[0m\n' "every node presents a certificate of its own"
# Measured before: added nodes ran on the first node's certificate, which the
# Node authorizer refuses for any other name, so the whole system:node role was
# bound to every node and any kubelet credential could list every pod and
# Secret. With the binding gone and no certificate of its own, an added node
# went NotReady in 46 s (experiments/37-node-credentials).
up="$(cat "$repo/control-plane/up.sh")"
contains "starting the control plane deletes the old binding" "$up" \
  'kubectl delete clusterrolebinding ferry:system-nodes --ignore-not-found'
lacks "and nothing binds system:node any more" "$up" 'name: system:node
'
contains "NodeRestriction keeps a node's writes to its own objects" "$up" '--enable-admission-plugins=NodeRestriction'
contains "and a node can still read the cluster's shape" "$up" '--clusterrole=system:node-proxier'
contains "node add starts the kubelet on its own credential" "$nodeadd" 'kubeconfig="$(node_credential "$name")"'
lacks "  never on the first node's" "$nodeadd" 'start_kubelet "$name" "$run" "$FERRY_HOME/kubelet.conf"'
contains "a restart or upgrade of an added node signs one if it has none" \
  "$(sed -n '/^node_layout()/,/^}/p' "$repo/ferry")" 'node_credential "$name"'
contains "and a running one is moved onto its own before the binding goes" \
  "$(sed -n '/^start_control_plane()/,/^}/p' "$repo/ferry" | sed -n '1,/up.sh/p')" 'migrate_node_credentials'
# Which kubelets it moves is read from their command lines, which are long: the
# kubeconfig comes after the kubelet's whole path and --config, well past the
# 80 columns ps can cut a command at. Two real processes stand in for kubelets,
# one on the first node's credential and one on its own.
if command -v python3 >/dev/null 2>&1; then
  (
    FERRY_HOME="$sandbox/migrate-home"; FERRY_RUN="$sandbox/migrate-run"
    mkdir -p "$FERRY_HOME" "$FERRY_RUN"
    long="$sandbox/a/path/as/long/as/a/checkout/bin/versions/v1.34.0/kubelet --config=$FERRY_RUN/node-1/kubelet.yaml"
    python3 -c 'import time; time.sleep(30)' $long "--kubeconfig=$FERRY_HOME/kubelet.conf" --v=2 &
    shared=$!
    python3 -c 'import time; time.sleep(30)' $long "--kubeconfig=$FERRY_HOME/pki/nodes/w2.conf" --v=2 &
    own=$!
    echo "$shared" > "$FERRY_RUN/node-1-kubelet.pid"
    echo "$own" > "$FERRY_RUN/node-2-kubelet.pid"
    node_layout() { echo "run=$FERRY_RUN/node-$1 kubeconfig=$FERRY_HOME/pki/nodes/w$1.conf logfile=/dev/null"; }
    stop_kubelet() { :; }
    start_kubelet() { echo "restarted $1 on $3" >> "$FERRY_RUN/restarts"; }
    ok() { :; }
    mkdir -p "$FERRY_RUN/node-1" "$FERRY_RUN/node-2"
    echo w1 > "$FERRY_RUN/node-1/node-name"; echo w2 > "$FERRY_RUN/node-2/node-name"
    eval "$(sed -n '/^migrate_node_credentials()/,/^}/p' "$repo/ferry")"
    COLUMNS=80 migrate_node_credentials
    kill "$shared" "$own" 2>/dev/null
    cat "$FERRY_RUN/restarts" 2>/dev/null
  ) > "$sandbox/migrate.out" 2>&1
  moved="$(cat "$sandbox/migrate.out")"
  contains "a kubelet on the first node's credential is moved, long command and all" "$moved" \
    "restarted w1 on $sandbox/migrate-home/pki/nodes/w1.conf"
  lacks "  and one already on its own is left running" "$moved" "restarted w2"
fi
if command -v openssl >/dev/null 2>&1; then
  FERRY_HOME="$sandbox/nodecred"; mkdir -p "$FERRY_HOME/pki"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FERRY_HOME/pki/ca.key" \
    -out "$FERRY_HOME/pki/ca.crt" -days 1 -subj /CN=test-ca 2>/dev/null
  printf 'users:\n- name: kubelet\n  user:\n    client-certificate: %s\n    client-key: %s\n' \
    "$FERRY_HOME/pki/kubelet.crt" "$FERRY_HOME/pki/kubelet.key" > "$FERRY_HOME/kubelet.conf"
  eval "$(sed -n '/^node_credential()/,/^}/p' "$repo/ferry")"
  conf="$(node_credential worker-1 2>&1)"
  crt="$FERRY_HOME/pki/nodes/worker-1.crt"
  is "node_credential names the node's kubeconfig" "$conf" "$FERRY_HOME/pki/nodes/worker-1.conf"
  is "  whose certificate is system:node:worker-1 in system:nodes" \
    "$(openssl x509 -in "$crt" -noout -subject -nameopt RFC2253 2>/dev/null)" \
    "subject=O=system:nodes,CN=system:node:worker-1"
  if openssl verify -CAfile "$FERRY_HOME/pki/ca.crt" "$crt" >/dev/null 2>&1; then
    ok "  signed by the cluster CA"; else bad "  signed by the cluster CA"; fi
  contains "  for client auth only" "$(openssl x509 -in "$crt" -noout -ext extendedKeyUsage 2>/dev/null)" \
    "TLS Web Client Authentication"
  is "  with a key only its owner reads" "$(stat -f %Lp "$FERRY_HOME/pki/nodes/worker-1.key")" 600
  contains "  and the kubeconfig presents it" "$(cat "$conf")" "client-certificate: $crt"
  lacks "  not the first node's" "$(cat "$conf")" "pki/kubelet.crt"
  before="$(cat "$crt")"; node_credential worker-1 >/dev/null
  is "a second start keeps the same certificate" "$(cat "$crt")" "$before"
  cp "$FERRY_HOME/pki/nodes/worker-1.crt" "$FERRY_HOME/pki/nodes/worker-2.crt"
  cp "$FERRY_HOME/pki/nodes/worker-1.key" "$FERRY_HOME/pki/nodes/worker-2.key"
  node_credential worker-2 >/dev/null
  is "one named for another node is signed again" \
    "$(openssl x509 -in "$FERRY_HOME/pki/nodes/worker-2.crt" -noout -subject -nameopt RFC2253 2>/dev/null)" \
    "subject=O=system:nodes,CN=system:node:worker-2"
  rm "$FERRY_HOME/pki/ca.key"
  # A subshell: node_credential says so with bad, which here is the counter.
  if (node_credential worker-3) >/dev/null 2>&1; then bad "no CA key, no certificate"
  else ok "no CA key, no certificate"; fi
  unset FERRY_HOME
  # The first node's is control-plane/pki.sh's, made once with the CA. A node
  # renamed since would present a name the Node authorizer grants nothing.
  PKI_DIR="$sandbox/pki" NODE_NAME=mac-a "$repo/control-plane/pki.sh" >/dev/null 2>&1
  admin="$(cat "$sandbox/pki/admin.crt")"
  PKI_DIR="$sandbox/pki" NODE_NAME=mac-b "$repo/control-plane/pki.sh" >/dev/null 2>&1
  is "pki.sh signs the first node's again for its new name" \
    "$(openssl x509 -in "$sandbox/pki/kubelet.crt" -noout -subject -nameopt RFC2253 2>/dev/null)" \
    "subject=O=system:nodes,CN=system:node:mac-b"
  is "  and leaves everything else it made" "$(cat "$sandbox/pki/admin.crt")" "$admin"
fi
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
