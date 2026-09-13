#!/usr/bin/env bash
# Run the reference CNI IPAM plugin, unmodified, as a native macOS binary.
#
# host-local is what ferry's RotatingAddresses reimplements. This drives a full
# ADD/DEL lifecycle against it -- allocation, the on-disk lease store, release --
# on darwin/arm64, with no Linux anywhere.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

out="$here/build"
state="$here/state"
rm -rf "$state"; mkdir -p "$out" "$state"

echo "==> building host-local for darwin/arm64"
GOFLAGS=-mod=mod GOOS=darwin GOARCH=arm64 \
  go build -o "$out/host-local" github.com/containernetworking/plugins/plugins/ipam/host-local
file "$out/host-local"

# A ferry-shaped network config: one node's /24 out of the cluster /16, the
# whole /16 routed on-link because the pod switch is one flat segment.
cat > "$out/netconf.json" <<EOF
{
  "cniVersion": "1.0.0",
  "name": "ferry",
  "type": "ferry-vm",
  "ipam": {
    "type": "host-local",
    "dataDir": "$state",
    "ranges": [[{"subnet": "10.244.7.0/24", "rangeStart": "10.244.7.2", "gateway": "10.244.7.1"}]],
    "routes": [{"dst": "10.244.0.0/16"}]
  }
}
EOF

export CNI_NETNS=/proc/self/ns/net   # stands in for the pod VM's own root netns
export CNI_IFNAME=eth1               # eth1 is ferry's cluster NIC; eth0 is vmnet
export CNI_PATH="$out"

run() { CNI_COMMAND="$1" CNI_CONTAINERID="$2" "$out/host-local" < "$out/netconf.json"; }

for pod in pod-alpha pod-beta pod-gamma; do
  echo "==> ADD $pod"
  run ADD "$pod"
done

echo "==> lease store"
for f in "$state"/ferry/*; do
  [ -f "$f" ] && echo "  $(basename "$f") -> $(tr -d '\n' < "$f")"
done

echo "==> DEL pod-beta"
run DEL pod-beta && echo "  exit 0"

echo "==> lease store after release"
ls "$state/ferry" | grep -v lock | sed 's/^/  /'
