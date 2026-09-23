#!/usr/bin/env bash
# can-i.sh for every node, impersonated and then with its own kubeconfig, and
# whose certificate each kubeconfig holds.
# usage: all-nodes.sh <name>=<kubeconfig>...   with KUBECONFIG pointing at the cluster (admin)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
first="${1%%=*}"
for pair in "$@"; do
  node="${pair%%=*}" conf="${pair#*=}"
  cert="$(KUBECONFIG="$conf" kubectl config view --raw --minify \
            -o jsonpath='{.users[0].user.client-certificate}')"
  echo "== $node ($(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253))"
  echo " impersonated:"
  "$here/can-i.sh" "$node" "$first"
  echo " its own kubeconfig:"
  AS_KUBECONFIG="$conf" "$here/can-i.sh" "$node" "$first"
done
