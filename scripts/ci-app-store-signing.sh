#!/bin/bash
# Import only App Store distribution credentials into an ephemeral hosted runner.
set -euo pipefail
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ] || [ "${RUNNER_OS:-}" != macOS ] || [ -z "${RUNNER_TEMP:-}" ]; then
  echo '仅允许在 GitHub 托管的 macOS runner 中运行。' >&2
  exit 2
fi
KEYCHAIN_PATH="$RUNNER_TEMP/linse-app-store.keychain-db"
CERTIFICATE_PATH="$RUNNER_TEMP/linse-app-store.p12"
PROFILE_PATH="$RUNNER_TEMP/linse-app-store.provisionprofile"
PROFILE_INFO="$RUNNER_TEMP/linse-app-store-profile.plist"
EXPORT_OPTIONS="$RUNNER_TEMP/linse-app-store-export.plist"
case "${1:-}" in
  cleanup)
    if [ -f "$PROFILE_INFO" ]; then
      PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_INFO")
      if [[ "$PROFILE_UUID" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
        rm -f "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.provisionprofile"
      fi
    fi
    rm -f "$CERTIFICATE_PATH" "$PROFILE_PATH" "$PROFILE_INFO" "$EXPORT_OPTIONS"
    if [ -e "$KEYCHAIN_PATH" ]; then security delete-keychain "$KEYCHAIN_PATH"; fi
    exit 0
    ;;
  install) ;;
  *) echo 'Usage: ci-app-store-signing.sh install|cleanup' >&2; exit 2 ;;
esac
for required in APP_STORE_CERTIFICATE_P12_BASE64 APP_STORE_CERTIFICATE_PASSWORD APP_STORE_PROFILE_BASE64 APPLE_TEAM_ID; do
  if [ -z "${!required:-}" ]; then echo "缺少 $required" >&2; exit 1; fi
done
[[ "$APPLE_TEAM_ID" == LVWWAF3DBK ]] || { echo '签名团队不匹配。' >&2; exit 1; }
umask 077
export CERTIFICATE_PATH PROFILE_PATH PROFILE_INFO EXPORT_OPTIONS
python3 - <<'PY'
import base64, os
from pathlib import Path
for key, target in [('APP_STORE_CERTIFICATE_P12_BASE64', 'CERTIFICATE_PATH'),
                    ('APP_STORE_PROFILE_BASE64', 'PROFILE_PATH')]:
    Path(os.environ[target]).write_bytes(base64.b64decode(''.join(os.environ[key].split()), validate=True))
PY
security cms -D -i "$PROFILE_PATH" > "$PROFILE_INFO"
python3 - <<'PY'
import datetime, os, plistlib, re
from pathlib import Path
profile = plistlib.loads(Path(os.environ['PROFILE_INFO']).read_bytes())
entitlements = profile['Entitlements']
identifier = entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier'))
if identifier != 'LVWWAF3DBK.app.linse.mac' or profile['TeamIdentifier'] != ['LVWWAF3DBK']:
    raise SystemExit('描述文件必须属于 LVWWAF3DBK.app.linse.mac')
if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices') or entitlements.get('get-task-allow') or entitlements.get('com.apple.security.get-task-allow'):
    raise SystemExit('需要 Mac App Store 分发描述文件，不能使用开发或 Developer ID 描述文件')
if profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    raise SystemExit('描述文件已过期')
if not re.fullmatch(r'[A-Fa-f0-9-]{36}', profile['UUID']):
    raise SystemExit('描述文件 UUID 格式不正确')
options = dict(method='app-store-connect', destination='export', teamID='LVWWAF3DBK',
               signingStyle='manual', provisioningProfiles={'app.linse.mac': profile['UUID']},
               stripSwiftSymbols=True, uploadSymbols=True, manageAppVersionAndBuildNumber=False)
Path(os.environ['EXPORT_OPTIONS']).write_bytes(plistlib.dumps(options))
PY
KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
echo "::add-mask::$KEYCHAIN_PASSWORD"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 7200 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -P "$APP_STORE_CERTIFICATE_PASSWORD" -k "$KEYCHAIN_PATH" \
  -t cert -f pkcs12 -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/productsign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
APP_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk -F '"' '/"(Apple Distribution:|3rd Party Mac Developer Application:)/ {print $2}')
INSTALLER_IDENTITY=$(security find-identity -v "$KEYCHAIN_PATH" | awk -F '"' '/"3rd Party Mac Developer Installer:/ {print $2}')
for identity in "$APP_IDENTITY" "$INSTALLER_IDENTITY"; do
  if [ "$(printf '%s\n' "$identity" | awk 'NF {n++} END {print n+0}')" -ne 1 ] || [[ "$identity" != *"(LVWWAF3DBK)" ]]; then
    echo 'p12 必须包含该团队唯一有效的商店应用证书、Mac Installer Distribution 证书及各自私钥。' >&2
    exit 1
  fi
done
export APP_IDENTITY INSTALLER_IDENTITY
python3 - <<'PY'
import os, plistlib
from pathlib import Path
p=Path(os.environ['EXPORT_OPTIONS'])
v=plistlib.loads(p.read_bytes())
v['signingCertificate']=os.environ['APP_IDENTITY']
v['installerSigningCertificate']=os.environ['INSTALLER_IDENTITY']
p.write_bytes(plistlib.dumps(v))
PY
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_INFO")
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.provisionprofile"
{
  printf 'APP_STORE_SIGNING_IDENTITY=%s\n' "$APP_IDENTITY"
  printf 'APP_STORE_PROFILE_UUID=%s\n' "$PROFILE_UUID"
  printf 'APP_STORE_EXPORT_OPTIONS=%s\n' "$EXPORT_OPTIONS"
} >> "$GITHUB_ENV"
rm -f "$CERTIFICATE_PATH" "$PROFILE_PATH"
