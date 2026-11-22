#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  ""|--portable) ;;
  *) echo "Usage: $0 [--portable]" >&2; exit 2 ;;
esac
for script in scripts/*.sh; do
  bash -n "$script"
done
xcrun swift build --triple arm64-apple-macosx14.0 -c release --product LinseMac
bash scripts/check-ios.sh
SMOKE_LOG=$(mktemp "${TMPDIR:-/tmp}/linse-smoke-log.XXXXXX")
trap 'rm -f "$SMOKE_LOG"' EXIT
bash scripts/smoke.sh "$@" | tee "$SMOKE_LOG"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n\n' 'Mac arm64 Release 与 iOS 共享代码编译通过；不代表设备或模拟器运行验收。' >> "$GITHUB_STEP_SUMMARY"
  cat "$SMOKE_LOG" >> "$GITHUB_STEP_SUMMARY"
fi
