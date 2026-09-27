#!/usr/bin/env bash
# Builds the host tool and the guest agent. Both are arm64 macOS binaries; the
# host tool is ad-hoc signed with com.apple.security.virtualization at its final
# path, which is all Virtualization.framework asks of a local tool.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
mkdir -p build

echo "==> macvm (host)"
swiftc -O -o build/macvm macvm.swift -framework Virtualization -framework AppKit
codesign --force --sign - --entitlements entitlements.plist build/macvm

echo "==> ferry-macagent (guest)"
swiftc -O -target arm64-apple-macos26.0 -o build/ferry-macagent agent.swift
codesign --force --sign - build/ferry-macagent

echo "==> ready: build/macvm build/ferry-macagent"
