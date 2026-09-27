#!/bin/sh
# Runs inside a macOS guest, as root: makes it a Kubernetes node.
#
# Everything it needs is in the read-only virtiofs share the host attached as
# "ferry": ferry's darwin kubelet, a CRI runtime, the cluster's CA, a bootstrap
# kubeconfig and a kubelet config. The kubelet asks for its own certificate
# with the bootstrap token, as a ferry machine's does. Holds until the host
# drops a file named `done` into the share.
set -u
S=/private/var/ferry/share
R=/private/var/ferry/node
mkdir -p "$S" && mount_virtiofs ferry "$S" || { echo "mount_virtiofs failed"; exit 1; }
rm -rf "$R"; mkdir -p "$R/bin" "$R/kubelet" "$R/logs" "$R/containerlogs" "$R/podlogs" "$R/volume-plugins" "$R/pki"
cp "$S/kubelet" "$S/runtime" "$R/bin/"
name=$(cat "$S/node-name")
# The kubelet takes its node address from the interfaces as it starts, so the
# guest's DHCP lease has to be in place first.
n=0; until addr=$(ipconfig getifaddr en0) || [ $n -ge 30 ]; do sleep 1; n=$((n + 1)); done
echo "--- guest $(sw_vers -productVersion), address ${addr:-none}, node $name"

t0=$(date +%s)
"$R/bin/runtime" $(cat "$S/runtime-args") > "$R/logs/runtime.log" 2>&1 &
# The kubelet exits at startup if the CRI endpoint is not serving yet, as the
# Mac's does -- ferry up waits for ferry-cri first, and so does this.
n=0; until [ -S "$R/cri.sock" ] || [ $n -ge 600 ]; do sleep 0.5; n=$((n + 1)); done
echo "--- runtime serving after $(( $(date +%s) - t0 )) s"
FERRY_CONTAINER_LOGS_DIR="$R/containerlogs" "$R/bin/kubelet" \
    --config="$S/kubelet.yaml" \
    --bootstrap-kubeconfig="$S/bootstrap.conf" --kubeconfig="$R/kubelet.conf" \
    --node-labels="$(cat "$S/node-labels")" \
    --register-with-taints="$(cat "$S/node-taints")" \
    --hostname-override="$name" --root-dir="$R/kubelet" --cert-dir="$R/pki" \
    --v=2 > "$R/logs/kubelet.log" 2>&1 &
echo "STARTED"

n=0
until [ -e "$S/done" ] || [ $n -ge 900 ]; do sleep 1; n=$((n + 1)); done
echo "--- held $(( $(date +%s) - t0 )) s"
echo "--- kubelet's certificate"
ls -l "$R/pki" | sed 's/^/    /'
echo "--- last kubelet errors"
grep -E '^E[0-9]{4}' "$R/logs/kubelet.log" | tail -8 | cut -c1-220 | sed 's/^/    /'
echo "--- runtime log tail"
tail -40 "$R/logs/runtime.log" | cut -c1-220 | sed 's/^/    /'
pkill -f "$R/bin/kubelet"; pkill -f "$R/bin/runtime"
