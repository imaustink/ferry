#!/usr/bin/env bash
# shareProcessNamespace puts every container of a pod in one PID namespace.
#
# ferry-cri never asked for it. The framework has it -- a pause process as PID
# 1 that each container joins -- but makePod did not read the pod's PID mode,
# so each container was PID 1 of a namespace of its own and the field was
# accepted without complaint. Nothing showed it until v0.6.0 began running
# preStop hooks: NATS's `nats-server -sl=ldm=<pidfile>` then signalled the
# wrong process, fell through to starting a second server, and that server held
# 4222 and 8222 so the real one crashlooped on "address already in use".
#
# Any chart whose preStop or sidecar signals a sibling by PID is exposed the
# same way, and silently: a `kill` of the wrong PID 1 still exits 0. So the end
# to end case has the hook send a signal the kubelet never sends, and checks
# that a pod without the field does *not* receive it -- a test that passes
# either way proves nothing.
#
#   ./tests/share-process-namespace-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
note() { skip=$((skip + 1)); printf '  \033[33m-\033[0m %s\n' "$1"; }

runtime="$repo/ferry-cri/Sources/ferry-cri/PodRuntime.swift"

echo "the pod's PID mode reaches the framework"
# Anchored, so a commented-out line does not count.
if grep -qE '^[[:space:]]*c\.shareProcessNamespace = cfg\.linux\.securityContext\.namespaceOptions\.pid == \.pod$' "$runtime"; then
  ok "makePod sets shareProcessNamespace from namespace_options.pid"
else
  bad "makePod sets shareProcessNamespace from namespace_options.pid"
fi

echo
echo "end to end: a preStop signals its sibling by PID"

ferry="$repo/ferry"
kubeconfig="$("$ferry" kubeconfig 2>/dev/null)"

if [ -z "$kubeconfig" ] || [ ! -f "$kubeconfig" ] || ! kubectl --kubeconfig "$kubeconfig" get nodes >/dev/null 2>&1; then
  note "no cluster up; skipped (run 'ferry up' to include this)"
else
  k() { kubectl --kubeconfig "$kubeconfig" "$@"; }
  work="$(mktemp -d)"
  trap 'rm -rf "$work"; k delete pod ferry-pidns-shared ferry-pidns-private --ignore-not-found --wait=false >/dev/null 2>&1' EXIT

  # The server outlives TERM for a few seconds, as a real one draining does.
  # Without that it can exit on the kubelet's own TERM before the sidecar's
  # hook runs, and the hook fails with "No such process" whichever namespace
  # it ran in. `$$$$` is `$$` once the kubelet has expanded `$(...)` syntax.
  pod() { # name shared
    cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  shareProcessNamespace: $2
  terminationGracePeriodSeconds: 15
  containers:
  - name: server
    image: busybox:1.36
    command: ["sh", "-c", "echo \$\$\$\$ > /run/shared/server.pid; trap 'echo USR1 from preStop' USR1; trap 'sleep 5; exit 0' TERM; while true; do sleep 1; done"]
    volumeMounts: [{name: shared, mountPath: /run/shared}]
  - name: sidecar
    image: busybox:1.36
    command: ["sh", "-c", "trap 'exit 0' TERM; while true; do sleep 1; done"]
    volumeMounts: [{name: shared, mountPath: /run/shared}]
    lifecycle:
      preStop:
        exec:
          command: ["sh", "-c", "kill -USR1 \$(cat /run/shared/server.pid)"]
  volumes:
  - name: shared
    emptyDir: {}
YAML
  }
  pod ferry-pidns-shared true > "$work/shared.yaml"
  pod ferry-pidns-private false > "$work/private.yaml"
  k delete -f "$work/shared.yaml" -f "$work/private.yaml" --ignore-not-found --wait=true >/dev/null 2>&1
  k apply -f "$work/shared.yaml" -f "$work/private.yaml" >/dev/null

  if ! k wait --for=condition=Ready pod/ferry-pidns-shared pod/ferry-pidns-private --timeout=180s >/dev/null 2>&1; then
    bad "the test pods start"
  else
    # PID 1 is the pause process, and the sidecar sees the server.
    procs="$(k exec ferry-pidns-shared -c sidecar -- ps -o pid,args 2>/dev/null)"
    echo "$procs" | awk '$1 == 1' | grep -q 'vminitd pause' \
      && ok "PID 1 of a shared pod is the pause process" \
      || { bad "PID 1 of a shared pod is the pause process"; echo "$procs" | sed 's/^/      /'; }
    echo "$procs" | grep -q '/run/shared/server.pid' \
      && ok "a container sees its sibling's processes" \
      || bad "a container sees its sibling's processes"
    k exec ferry-pidns-private -c sidecar -- ps -o args 2>/dev/null | grep -q '/run/shared/server.pid' \
      && bad "a pod without the field keeps its containers apart" \
      || ok "a pod without the field keeps its containers apart"

    # Through the real preStop path: the pod is deleted and the kubelet runs
    # the hook. The log is followed from before, because it goes with the pod.
    for name in ferry-pidns-shared ferry-pidns-private; do
      k logs -f "$name" -c server > "$work/$name.log" 2>&1 &
      follower=$!
      sleep 1
      k delete pod "$name" --wait=true >/dev/null 2>&1
      wait "$follower" 2>/dev/null
    done
    grep -q 'USR1 from preStop' "$work/ferry-pidns-shared.log" \
      && ok "a preStop signals its sibling by PID" \
      || bad "a preStop signals its sibling by PID"
    grep -q 'USR1 from preStop' "$work/ferry-pidns-private.log" \
      && bad "without the field the signal does not reach it (the test can fail)" \
      || ok "without the field the signal does not reach it (the test can fail)"
  fi
fi

echo
printf '%s passed, %s failed' "$pass" "$fail"
[ "$skip" -gt 0 ] && printf ', %s skipped' "$skip"
echo
[ "$fail" -eq 0 ]
