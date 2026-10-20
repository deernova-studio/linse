#!/bin/bash
# Store builds use an Xcode application target; Developer ID DMGs use package.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${LINSE_VERSION:-0.3.0}"
BUILD_NUMBER="${LINSE_BUILD_NUMBER:-14}"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo '版本号须为 x.y.z，构建号须为最多 9 位的正整数。' >&2
  exit 2
fi
OUTPUT="build/app-store/Linse-${VERSION}-build${BUILD_NUMBER}"
ARCHIVE="$OUTPUT/Linse.xcarchive"
BUILD_ARGS=(-project macOS/Linse.xcodeproj -scheme Linse -configuration Release
  -destination 'generic/platform=macOS' -derivedDataPath build/AppStoreDerived
  "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" ARCHS=arm64)
case "${1:-}" in
  build)
    xcodebuild "${BUILD_ARGS[@]}" build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
    python3 scripts/verify-app-store.py build/AppStoreDerived/Build/Products/Release/临色.app --local
    ;;
  archive)
    if [ -e "$ARCHIVE" ]; then
      echo "归档已存在：$ARCHIVE。请使用新的构建号。" >&2
      exit 1
    fi
    mkdir -p "$OUTPUT"
    if [ -n "${APP_STORE_SIGNING_IDENTITY:-}" ] && [ -n "${APP_STORE_PROFILE_UUID:-}" ]; then
      xcodebuild "${BUILD_ARGS[@]}" archive -archivePath "$ARCHIVE" CODE_SIGN_STYLE=Manual \
        "CODE_SIGN_IDENTITY=$APP_STORE_SIGNING_IDENTITY" "PROVISIONING_PROFILE_SPECIFIER=$APP_STORE_PROFILE_UUID"
    else
      # Local Xcode account manages development/distribution signing.
      xcodebuild "${BUILD_ARGS[@]}" archive -archivePath "$ARCHIVE" -allowProvisioningUpdates
    fi
    python3 scripts/verify-app-store.py "$ARCHIVE/Products/Applications/临色.app" --archive
    ;;
  export)
    OPTIONS="${APP_STORE_EXPORT_OPTIONS:-macOS/ExportOptions.plist}"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUTPUT/export" \
      -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates
    shopt -s nullglob
    PACKAGES=("$OUTPUT/export/"*.pkg)
    [ "${#PACKAGES[@]}" -eq 1 ] || { echo '未找到唯一的商店 PKG。' >&2; exit 1; }
    python3 scripts/verify-app-store.py "${PACKAGES[0]}"
    ;;
  upload)
    for required in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APP_STORE_APP_ID; do
      if [ -z "${!required:-}" ]; then echo "缺少 $required" >&2; exit 1; fi
    done
    [[ "$APP_STORE_APP_ID" =~ ^[0-9]+$ ]] || { echo 'APP_STORE_APP_ID 必须是 Apple 后台的数字 ID。' >&2; exit 1; }
    shopt -s nullglob
    PACKAGES=("$OUTPUT/export/"*.pkg)
    if [ "${#PACKAGES[@]}" -ne 1 ]; then echo '请先成功导出唯一的商店 PKG。' >&2; exit 1; fi
    python3 scripts/verify-app-store.py "${PACKAGES[0]}"
    xcrun altool --validate-app -f "${PACKAGES[0]}" -t macos \
      -u "$APPLE_ID" -p '@env:APPLE_APP_SPECIFIC_PASSWORD'
    xcrun altool --upload-package "${PACKAGES[0]}" --type macos \
      --apple-id "$APP_STORE_APP_ID" --bundle-id app.linse.mac \
      --bundle-version "$BUILD_NUMBER" --bundle-short-version-string "$VERSION" \
      --team-id "${APPLE_TEAM_ID:-LVWWAF3DBK}" \
      -u "$APPLE_ID" -p '@env:APPLE_APP_SPECIFIC_PASSWORD'
    ;;
  *) echo 'Usage: bash scripts/app-store.sh build|archive|export|upload' >&2; exit 2 ;;
esac
