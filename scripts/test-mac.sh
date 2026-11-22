#!/bin/bash
# Builds and runs the Mac logic tests (mac/Tests) against the AppKit-free sources.
set -euo pipefail

cd "$(dirname "$0")/.."
cache="$(mktemp -d "${TMPDIR:-/tmp}/prilo-mac-tests.XXXXXX")"
trap 'rm -rf "$cache"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$cache" \
    mac/Protocol.swift mac/InputProcessing.swift mac/Tests/main.swift -o "$cache/prilo-tests"
"$cache/prilo-tests"
