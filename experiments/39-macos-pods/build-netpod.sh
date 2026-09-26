#!/usr/bin/env bash
# Builds the per-pod-address pieces into build/netpod, laid out the way a pod's
# root would be: bin/ for the workload, lib/ for the shim podexec injects.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/build/netpod"
rm -rf "$out"; mkdir -p "$out/bin" "$out/lib"
# Both slices: Apple's own tools are arm64e, and dyld will not insert an arm64
# library into an arm64e process -- it aborts the process instead.
clang -O2 -dynamiclib -arch arm64 -arch arm64e -o "$out/lib/podnet.dylib" "$here/podnet.c"
clang -O2 -o "$out/bin/podsrv" "$here/podsrv.c"
clang -O2 -Wno-deprecated-declarations -o "$out/podexec" "$here/podexec.c"
ls -l "$out" "$out/bin" "$out/lib" | grep -v total
