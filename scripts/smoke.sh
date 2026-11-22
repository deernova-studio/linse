#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  "") ;;
  --portable) echo 'UNVERIFIED S1-S8: portable mode; no product runtime smoke executed.'; exit 0 ;;
  *) echo "Usage: $0 [--portable]" >&2; exit 2 ;;
esac
METAL_AVAILABLE=$(xcrun swift -e 'import Metal; print(MTLCreateSystemDefaultDevice() == nil ? "no" : "yes")')
if [[ "$METAL_AVAILABLE" == no ]]; then
  echo 'UNVERIFIED S1-S8: no Metal device; run on a physical Apple Silicon Mac.'
  exit 0
fi
# Standalone workflow driver, intentionally not a Swift package test target.
SMOKE_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/linse-smoke-build.XXXXXX")
trap 'rm -rf "$SMOKE_BUILD_DIR"' EXIT
xcrun swiftc -parse-as-library -O -target arm64-apple-macosx14.0 \
  Sources/LinseCore/*.swift scripts/smoke/Flows.swift -o "$SMOKE_BUILD_DIR/linse-smoke"
"$SMOKE_BUILD_DIR/linse-smoke"
