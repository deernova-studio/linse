#!/bin/bash
# 不装 iOS 模拟器也能做的检查：用 iOS 模拟器 SDK 编译 LinseCore 和 LinseUI
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target LinseUI --scratch-path .build/ios --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --triple arm64-apple-ios17.0-simulator
