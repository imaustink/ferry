#!/usr/bin/env bash
# Which upstream CNI plugins compile for darwin/arm64, and which need Linux?
#
# The split is the whole point of the experiment: IPAM is pure computation and
# builds native, everything else wants netlink and a netns. That line is exactly
# where ferry already cuts -- the hypervisor is the thing that makes a netns.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

P=github.com/containernetworking/plugins/plugins

# Resolve the transitive deps first. Without this every plugin fails with
# "missing go.sum entry" and the survey reports Linux-only for the wrong reason.
echo "==> resolving dependencies"
GOFLAGS=-mod=mod go get "$P/meta/portmap@v1.9.1" >/dev/null 2>&1
GOFLAGS=-mod=mod go get "$P/main/bridge@v1.9.1" >/dev/null 2>&1
GOFLAGS=-mod=mod go get "$P/ipam/dhcp@v1.9.1" >/dev/null 2>&1

# The runtime half. ferry does not just need plugins to build -- it needs the
# CNI runtime itself, because ferry-cri is the thing that would drive the chain.
echo "==> the CNI runtime for darwin/arm64"
GOFLAGS=-mod=mod go get github.com/containernetworking/cni/libcni@v1.3.1 >/dev/null 2>&1
if GOOS=darwin GOARCH=arm64 go build -o /dev/null \
     github.com/containernetworking/cni/libcni \
     github.com/containernetworking/cni/pkg/invoke \
     github.com/containernetworking/cni/pkg/types/100 >/dev/null 2>&1; then
  echo "  darwin OK    libcni + pkg/invoke + pkg/types/100"
else
  echo "  FAILED       libcni"
fi

echo "==> building each plugin for darwin/arm64"
for p in \
  ipam/host-local ipam/static ipam/dhcp \
  main/bridge main/ptp main/macvlan main/ipvlan main/host-device main/loopback main/vlan main/tap \
  meta/portmap meta/bandwidth meta/tuning meta/firewall meta/sbr meta/vrf meta/bridge-ext
do
  if GOOS=darwin GOARCH=arm64 go build -o /dev/null "$P/$p" >/dev/null 2>&1; then
    echo "  darwin OK    $p"
  else
    echo "  linux-only   $p"
  fi
done
