#!/bin/bash
# 仅构建 Apple 芯片（arm64）应用；本地使用临时签名，--release 使用 Developer ID 正式签名。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="0.2.10"
BUILD_NUMBER="12"
RELEASE=false
case "${1:-}" in
  "") APP="build/临色.app" ;;
  --dev) APP="build/dev/临色.app" ;;
  --release)
    RELEASE=true
    APP="build/release-candidates/Linse-${VERSION}-build${BUILD_NUMBER}/临色.app"
    if [ -e "$APP" ]; then
      echo "发布候选应用已存在：${APP}。请保留该版本，更新版本号后再构建。" >&2
      exit 1
    fi
    if [ -z "${SIGNING_IDENTITY:-}" ]; then
      IDENTITIES=()
      while IFS= read -r identity; do
        IDENTITIES+=("$identity")
      done < <(security find-identity -v -p codesigning | awk -F '"' '/"Developer ID Application:/ { print $2 }')
      if [ "${#IDENTITIES[@]}" -ne 1 ]; then
        echo '请用 SIGNING_IDENTITY 指定一个有效的 Developer ID Application 签名身份。' >&2
        exit 1
      fi
      SIGNING_IDENTITY="${IDENTITIES[0]}"
    fi
    if [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
      echo '正式构建必须使用完整的 Developer ID Application 签名身份名称。' >&2
      exit 1
    fi
    ;;
  *) echo "Usage: $0 [--dev|--release]" >&2; exit 2 ;;
esac
BUILD_ARGS=(--triple arm64-apple-macosx14.0 -c release)
if "$RELEASE"; then
  BUILD_ARGS+=(--scratch-path .build/distribution-arm64 --disable-local-rpath)
fi
xcrun swift build "${BUILD_ARGS[@]}" --product LinseMac
BINARY="$(xcrun swift build "${BUILD_ARGS[@]}" --show-bin-path)/LinseMac"
if [ "$(xcrun lipo -archs "$BINARY")" != arm64 ]; then
  echo 'macOS 应用必须仅包含 arm64 架构。' >&2
  exit 1
fi
mkdir -p "$(dirname "$APP")"
STAGING=$(mktemp -d "$(dirname "$APP")/.package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/临色.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BINARY" "$STAGED_APP/Contents/MacOS/Linse"
[ -f Assets/icon.icns ] && cp Assets/icon.icns "$STAGED_APP/Contents/Resources/icon.icns"
cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>临色</string>
  <key>CFBundleDisplayName</key><string>临色</string>
  <key>CFBundleIdentifier</key><string>app.linse.mac</string>
  <key>CFBundleExecutable</key><string>Linse</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict></plist>
PLIST
plutil -lint "$STAGED_APP/Contents/Info.plist"
if "$RELEASE"; then
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$STAGED_APP"
else
  codesign --force --sign - "$STAGED_APP"
fi
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
if [ -f "$APP/Contents/MacOS/Linse" ] && /usr/sbin/lsof -t "$APP/Contents/MacOS/Linse" >/dev/null 2>&1; then
  echo "应用正在运行，请先关闭对应版本再更新：$APP" >&2
  exit 1
fi
rm -rf "$APP"
mv "$STAGED_APP" "$APP"
if "$RELEASE"; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$(dirname "$APP")/Linse-${VERSION}-macOS-arm64-signed.zip"
  echo '正式签名完成；尚未完成 Apple 公证。请运行 scripts/notarize.sh 后再对外分发。'
fi
echo "$APP"
