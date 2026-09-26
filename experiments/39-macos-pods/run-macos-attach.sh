#!/usr/bin/env bash
# kubectl attach against macOS pods: output as it arrives, stdin with and
# without a terminal, and `kubectl run -i --rm`, which is attach underneath.
# Boots mac-0 if it is not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod ticker catter termy --ignore-not-found >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: ticker, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  containers: [{name: t, image: $img, command: [/bin/sh, -c, 'i=0; while true; do i=\$((i+1)); echo "tick \$i"; sleep 1; done']}]
---
apiVersion: v1
kind: Pod
metadata: {name: catter, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers: [{name: c, image: $img, command: [/bin/cat], stdin: true, stdinOnce: true}]
---
apiVersion: v1
kind: Pod
metadata: {name: termy, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  containers: [{name: s, image: $img, command: [/bin/sh], stdin: true, tty: true}]
EOF
k wait --for=condition=Ready pod/ticker pod/catter pod/termy --timeout=120s >/dev/null

echo "=== kubectl attach ticker, for four seconds"
k attach ticker > "$here/build/attach.out" 2>&1 &
a=$!
sleep 4; kill $a 2>/dev/null; wait $a 2>/dev/null
sed 's/^/    /' "$here/build/attach.out" | grep -v "If you don't see"

echo "=== echo ... | kubectl attach -i catter   (stdin, stdinOnce)"
echo "hello through attach" | k attach -i catter 2>&1 | grep -v "If you don't see" | sed 's/^/    /'
for _ in $(seq 20); do [ "$(k get pod catter -o jsonpath='{.status.phase}')" = Succeeded ] && break; sleep 1; done
echo "    catter: $(k get pod catter -o jsonpath='{.status.phase}'), log: $(k logs catter 2>&1)"

echo "=== kubectl attach -it termy   (a terminal)"
# Typed, not pasted: input that arrives before attach has the terminal in raw
# mode and connected is lost to the shell's line editor, as it would be at a
# real keyboard typing ahead of a prompt.
(sleep 2; printf 'echo "shell on $(tty), $(stty size) rows/cols"\n'; sleep 1; printf 'exit\n') \
    | script -q /dev/null kubectl attach -it termy 2>&1 \
    | tr -d '\r' | grep -E "shell on|sh-3" | grep -v 'echo "shell' | sed 's/^/    /'

echo "=== kubectl run -i --rm   (attach underneath)"
echo "a line for run" | k run runner -i --rm --restart=Never --image=$img \
    --overrides='{"spec":{"runtimeClassName":"ferry-macos-shared"}}' --command -- \
    /bin/sh -c 'read x; echo "run -i read: $x, on $(sw_vers -productName) $(sw_vers -productVersion)"' 2>&1 \
    | grep -v "If you don't see\|deleted" | sed 's/^/    /'

k delete pod ticker catter termy --wait=false >/dev/null 2>&1
