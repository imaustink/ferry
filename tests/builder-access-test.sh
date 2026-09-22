#!/usr/bin/env bash
# Reaching the builder is not the same as being able to use it.
#
# `ferry image build` runs buildkitd privileged, and it has to listen on the
# pod's real address: the Mac talks to pods over the pod network and there is
# no other path -- `kubectl port-forward` dials the pod's address too, so a
# listener bound to the pod's localhost is unreachable from everywhere,
# including from the developer it is for. That address is on a network every
# pod shares. Anything that can drive that daemon can run arbitrary builds as
# root inside the builder VM and read the whole build cache.
#
# Two things stand in the way, and the second is the one that always works:
#
#   a NetworkPolicy   correct, and inert on a kernel without nftables -- which
#                     is the stock guest kernel, where `nft` fails with "cache
#                     initialization failed" and ClusterIPs already fall back
#                     to a host proxy. It is applied because it does enforce on
#                     a kernel built by `ferry kernel`, but it cannot be the
#                     only thing.
#
#   mutual TLS        does not care what the guest kernel can do. buildkitd is
#                     given a CA, which makes a client certificate mandatory,
#                     and the Mac holds the only one.
#
#   ./tests/builder-access-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
note() { skip=$((skip + 1)); printf '  \033[33m-\033[0m %s\n' "$1"; }

contains() { # description file needle
  # -e, because a needle that starts with a dash is a flag otherwise.
  if grep -qF -e "$3" "$2"; then ok "$1"; else bad "$1"; echo "      '$3' is not in $(basename "$2")"; fi
}

ferry="$repo/ferry"

echo "the builder demands a certificate"

contains "buildkitd is given a CA, which makes a client cert mandatory" "$ferry" '- --tlscacert'
contains "buildkitd is given its own certificate" "$ferry" '- /certs/tls.crt'
contains "the client presents one" "$ferry" '--tlscert "$pki/client.crt"'
contains "the client verifies a name, not an address" "$ferry" '--tlsservername "$FERRY_BUILDER_CN"'
contains "the server certificate carries that name" "$ferry" 'subjectAltName=DNS:%s'

echo
echo "and is denied to the cluster as well"

contains "a policy selects the builder" "$ferry" 'kind: NetworkPolicy'
contains "it denies ingress rather than allowing some" "$ferry" 'policyTypes: [Ingress]'

echo
echo "nothing outlives the builder"

contains "--stop removes the policy" "$ferry" 'delete networkpolicy "$FERRY_BUILDER_POD"'
contains "--stop removes the server key from the cluster" "$ferry" 'delete secret "$FERRY_BUILDER_POD-tls"'

echo
echo "end to end: an unauthenticated client is refused"

kubeconfig="$("$ferry" kubeconfig 2>/dev/null)"
if [ -z "$kubeconfig" ] || [ ! -f "$kubeconfig" ] || ! kubectl --kubeconfig "$kubeconfig" get nodes >/dev/null 2>&1; then
  note "no cluster up; skipped (run 'ferry up' to include this)"
elif ! command -v buildctl >/dev/null 2>&1; then
  note "buildctl not installed; skipped (brew install buildkit)"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  printf 'FROM ghcr.io/linuxcontainers/alpine:3.20\nRUN true\n' > "$work/Dockerfile"

  # Starting the builder is what `ferry image build` does; this borrows it
  # rather than reimplementing the manifest, so the test cannot drift from it.
  if ! "$ferry" image build -q -t ferry-builder-access-test:dev "$work" >/dev/null 2>&1; then
    bad "the authenticated client can build"
  else
    ok "the authenticated client can build"

    ns="${FERRY_BUILDER_NS:-kube-system}"
    ip="$(kubectl --kubeconfig "$kubeconfig" -n "$ns" get pod ferry-builder \
          -o jsonpath='{.status.podIP}' 2>/dev/null)"
    pki="$(dirname "$kubeconfig")/pki/builder"

    if [ -z "$ip" ]; then
      note "builder has no address; the refusal checks were skipped"
    else
      # What any pod on the network could do before: connect and talk plain
      # gRPC. The daemon must not answer.
      if buildctl --addr "tcp://$ip:1234" debug workers >/dev/null 2>&1; then
        bad "a plaintext client is refused"
      else
        ok "a plaintext client is refused"
      fi

      # And TLS alone is not enough -- encryption without a client certificate
      # is not authentication.
      if buildctl --addr "tcp://$ip:1234" --tlscacert "$pki/ca.crt" \
           --tlsservername ferry-builder debug workers >/dev/null 2>&1; then
        bad "a client without a certificate is refused"
      else
        ok "a client without a certificate is refused"
      fi
    fi
  fi
fi

echo
printf '%s passed, %s failed' "$pass" "$fail"
[ "$skip" -gt 0 ] && printf ', %s skipped' "$skip"
echo
[ "$fail" -eq 0 ]
