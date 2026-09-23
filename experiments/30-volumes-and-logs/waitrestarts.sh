#!/usr/bin/env bash
# Waits until pod $1 has restarted its first container $2 times.
set -euo pipefail
until [ "$(kubectl get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}')" -ge "$2" ]; do
  sleep 1
done
