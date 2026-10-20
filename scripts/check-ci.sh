#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  "") METAL_AVAILABLE=$(xcrun swift -e 'import Metal; print(MTLCreateSystemDefaultDevice() == nil ? "no" : "yes")') ;;
  --portable) METAL_AVAILABLE=no ;;
  *) echo "Usage: $0 [--portable]" >&2; exit 2 ;;
esac
for script in scripts/*.sh; do
  bash -n "$script"
done
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
case "$METAL_AVAILABLE" in
  yes)
    xcrun swift test
    COVERAGE='Swift 全套测试已执行；缺少外部 RAW 样片或可选模拟服务的项目会明确跳过。'
    ;;
  no)
    xcrun swift test --filter 'AIClientTests|FeatureTests|LocalAIConfigurationTests|LutPersistenceTests'
    COVERAGE='本轮执行无需 Metal 的 AI 协议、配置、XMP 和 LUT 持久化测试。GPU 渲染、编辑状态与 RAW 回归需在真实 Mac 上验证。'
    ;;
  *) echo '无法确定 Metal 设备状态。' >&2; exit 1 ;;
esac
xcrun swift build --triple arm64-apple-macosx14.0 -c release --product LinseMac
bash scripts/check-ios.sh
echo "$COVERAGE"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n\n%s\n' "$COVERAGE" 'Mac arm64 Release 与 iOS 共享代码编译通过；此项不包含 iPhone / iPad 界面或真机验证。' >> "$GITHUB_STEP_SUMMARY"
fi
