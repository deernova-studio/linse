#!/bin/bash
# 构建 release 并打成 build/临色.app（ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product LinseMac
APP="build/临色.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LinseMac "$APP/Contents/MacOS/Linse"
[ -f Assets/icon.icns ] && cp Assets/icon.icns "$APP/Contents/Resources/icon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>临色</string>
  <key>CFBundleDisplayName</key><string>临色</string>
  <key>CFBundleIdentifier</key><string>app.linse.mac</string>
  <key>CFBundleExecutable</key><string>Linse</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
