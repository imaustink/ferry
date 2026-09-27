#!/usr/bin/env bash
# Builds this experiment's host tool (macvm, extended with `build` mode) and
# the Go driver (mkimage-run). The guest agent is unchanged from experiment
# 39 and is not rebuilt here -- it's already baked into the golden bundle
# this experiment clones (see run-demo.sh).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
mkdir -p build

echo "==> macvm (host, with 'build' mode)"
swiftc -O -o build/macvm macvm.swift -framework Virtualization -framework AppKit
codesign --force --sign - --entitlements entitlements.plist build/macvm

echo "==> mkimage-run (the Dockerfile-with-RUN driver)"
( cd mkimage-run && go build -o mkimage-run . )

echo "==> ready: build/macvm, mkimage-run/mkimage-run"
