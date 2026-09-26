#!/bin/sh
# ferry-macos-init: a macOS machine's boot, the counterpart of the Linux node
# image's init.sh.
#
# Run by launchd at boot, as root, before anyone logs in. ferry-node shares a
# directory into the guest as "ferry-config", one value a file: what a Linux
# machine is told on its kernel command line, which a macOS guest does not
# have. Without that share this is not a machine boot -- the golden image
# being baked or looked into -- and it does nothing.
#
#   machine card   the machine network: the address vmnet gave, the Mac as gateway
#   pod card       ferry's pod switch: ferry-darwin puts the node's pod CIDR on it
#
# Both are found by MAC address, which ferry-node writes into the share: the
# guest names its interfaces in an order of its own.
set -u
C=/private/var/ferry/config
L=/private/var/ferry/logs
R=/private/var/ferry/node
F=/usr/local/libexec/ferry
mkdir -p "$C" "$L" /private/var/log
exec >> /private/var/log/ferry-macos-node.log 2>&1
t0=$(date +%s)
log() { echo "$(date '+%H:%M:%S') ferry-macos-init: $*"; }

mount_virtiofs ferry-config "$C" 2>/dev/null || { log "no ferry-config share; not a machine boot"; exit 0; }
# The Mac reads these: a macOS guest has no console. Falls back to the guest's
# own disk when the share is missing.
if mount_virtiofs ferry-logs "$L" 2>/dev/null; then
    exec >> "$L/init.log" 2>&1
else
    L=/private/var/log
fi
log "boot, $(sw_vers -productVersion), interfaces: $(ifconfig -l)"
v() { cat "$C/$1" 2>/dev/null; }
NODE=$(v node); ADDR=$(v address); GW=$(v gateway); API=$(v api); TOKEN=$(v token)
CLUSTER_CIDR=$(v clustercidr); DNS=$(v dnssvc); TAINTS=$(v taints); REGISTRY=$(v registry)
log "machine $NODE at $ADDR, gateway $GW, cluster $CLUSTER_CIDR"

# The two cards, found by the MAC addresses ferry-node gave them: the guest's
# interface names do not follow attach order.
by_mac() {
    want=$(echo "$1" | tr 'A-F' 'a-f')
    for i in $(ifconfig -l); do
        ifconfig "$i" 2>/dev/null | awk -v w="$want" '$1 == "ether" && tolower($2) == w {found=1} END {exit !found}' && { echo "$i"; return; }
    done
}
n=0; until MACHINE_IF=$(by_mac "$(v mac)"); [ -n "$MACHINE_IF" ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
POD_IF=$(by_mac "$(v podmac)")
log "machine network on ${MACHINE_IF:-?}, pod switch on ${POD_IF:-?}"

# The machine card, static: DHCP is off on the machine network, and
# IPConfiguration would otherwise give it a link-local address and keep asking.
ip=${ADDR%/*}; prefix=${ADDR#*/}
mask=$(awk -v p="$prefix" 'BEGIN { m = 0; for (i = 0; i < 32; i++) m = m * 2 + (i < p); printf "%d.%d.%d.%d", int(m/16777216)%256, int(m/65536)%256, int(m/256)%256, m%256 }')
# Configured as a network service, with its router and a DNS server, not only
# an address on an interface. configd decides from its services which
# resolvers are reachable, and getaddrinfo skips the ones it says are not: with
# `ipconfig set MANUAL`, which gives an address and no router, every resolver
# read Not Reachable, and a pod could not resolve a cluster name the node's
# own dscacheutil resolved fine. 1.1.1.1 is what a Linux machine gets.
svc=$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v d="$MACHINE_IF" '
    /^\([0-9*]+\) / { sub(/^\([0-9*]+\) /, ""); name = $0 }
    index($0, "Device: " d ")") { print name; exit }')
if [ -n "$svc" ]; then
    networksetup -setmanual "$svc" "$ip" "$mask" "$GW"
    networksetup -setdnsservers "$svc" 1.1.1.1
    log "network service \"$svc\": $ip/$mask via $GW, dns 1.1.1.1"
else
    log "no network service for $MACHINE_IF; configuring the interface alone"
    ipconfig set "$MACHINE_IF" MANUAL "$ip" "$mask"
fi
# Either way the address arrives asynchronously, and a default route through a
# gateway not yet on-link is refused -- which leaves the node answering ping
# on its own segment and unable to reach the API server off it.
n=0; until ifconfig "$MACHINE_IF" | grep -q "inet $ip " || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
n=0; until route -n get default 2>/dev/null | grep -q "gateway: $GW" || [ $n -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
route -n get default 2>/dev/null | grep -q "gateway: $GW" \
    || route -q -n add default "$GW" 2>/dev/null || route -q -n change default "$GW"
# The pod card is ferry-darwin's once the pod CIDR is known; nothing asks
# DHCP for it.
[ -n "$POD_IF" ] && ipconfig set "$POD_IF" NONE 2>/dev/null
log "$MACHINE_IF $ip/$prefix, default via $(route -n get default 2>/dev/null | awk '/gateway/ {print $2}') ($(( $(date +%s) - t0 )) s)"

# PersistentVolumes: ferry-storage makes each one a directory on the Mac, and
# ferry-node shares the Mac's volumes directory into every machine; mounted at
# the same path it has on the Mac, one PersistentVolume names one directory
# wherever its pod lands -- a Linux machine does the same in init.sh.
VOLUMES=$(v volumes)
if [ -n "$VOLUMES" ]; then
    mkdir -p "$VOLUMES"
    if mount_virtiofs ferry-volumes "$VOLUMES" 2>/dev/null; then
        log "PersistentVolumes: the Mac's $VOLUMES"
    else
        log "no ferry-volumes share; PersistentVolumes will not mount here"; VOLUMES=""
    fi
fi

rm -rf "$R"; mkdir -p "$R/kubelet" "$R/logs" "$R/containerlogs" "$R/podlogs" "$R/volume-plugins" "$R/pki"
cat > "$R/bootstrap.conf" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: ferry, cluster: {server: "$API", certificate-authority: $C/ca.crt}}]
users: [{name: bootstrap, user: {token: "$TOKEN"}}]
contexts: [{name: bootstrap, context: {cluster: ferry, user: bootstrap}}]
current-context: bootstrap
EOF
# A macos-vm machine is one pod's VM: mode 1, for macOS.
MODE=$(v mode); MODE=${MODE:-shared-macos}; MAXPODS=$(v maxpods); MAXPODS=${MAXPODS:-110}
sed -e "s|__DNS__|$DNS|" -e "s|__CA__|$C/ca.crt|" -e "s|__MAXPODS__|$MAXPODS|" "$F/kubelet.yaml.in" > "$R/kubelet.yaml"

mirror=""
[ -n "$REGISTRY" ] && mirror="http://$GW:$REGISTRY"
"$F/ferry-darwin" -endpoint "$R/cri.sock" -state /private/var/ferry/darwin -mirror "$mirror" \
    -shim "$F/podnet.dylib" -iface "$POD_IF" -cluster-cidr "$CLUSTER_CIDR" \
    -api "$API" -ca "$C/ca.crt" -cluster-dns "$DNS" -volumes-root "$R/kubelet/pods" -node-name "$NODE" \
    ${VOLUMES:+-host-volumes "$VOLUMES"} \
    $([ "$MODE" = macos-vm ] && echo -pod-vm) \
    > "$L/runtime.log" 2>&1 &
# The kubelet exits at startup if its runtime is not serving yet.
n=0; until [ -S "$R/cri.sock" ] || [ $n -ge 600 ]; do sleep 0.1; n=$((n + 1)); done
log "ferry-darwin serving ($(( $(date +%s) - t0 )) s)"

FERRY_CONTAINER_LOGS_DIR="$R/containerlogs" "$F/kubelet" \
    --config="$R/kubelet.yaml" \
    --bootstrap-kubeconfig="$R/bootstrap.conf" --kubeconfig="$R/kubelet.conf" \
    --node-labels=ferry.dev/mode="$MODE" \
    ${TAINTS:+--register-with-taints="$TAINTS"} \
    --hostname-override="$NODE" --node-ip="$ip" \
    --root-dir="$R/kubelet" --cert-dir="$R/pki" --v=2 > "$L/kubelet.log" 2>&1 &
log "kubelet started ($(( $(date +%s) - t0 )) s)"
wait
