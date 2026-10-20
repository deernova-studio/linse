#!/usr/bin/env python3
"""Validate the actual Mac app bundle before distribution."""
import argparse
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path


def validate_metadata(info, entitlements, architectures, privacy):
    if info.get("CFBundleIdentifier") != "app.linse.mac":
        raise ValueError("Unexpected bundle identifier")
    if info.get("LSMinimumSystemVersion") != "14.0":
        raise ValueError("macOS deployment target must remain 14.0")
    if architectures.strip() != "arm64":
        raise ValueError("The store app must contain arm64 only")
    for key in ("com.apple.security.app-sandbox", "com.apple.security.network.client",
                "com.apple.security.files.user-selected.read-write"):
        if entitlements.get(key) is not True:
            raise ValueError(f"Missing required entitlement: {key}")
    if any(k.startswith("com.apple.security.temporary-exception") for k in entitlements):
        raise ValueError("Unexpected sandbox exception")
    if privacy.get("NSPrivacyTracking") is not False:
        raise ValueError("Tracking must remain disabled")
    if not re.fullmatch(r"[1-9][0-9]{0,8}", str(info.get("CFBundleVersion", ""))):
        raise ValueError("Invalid build number")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", info.get("CFBundleShortVersionString", "")):
        raise ValueError("Invalid marketing version")


def validate_app(app, *, local=False, archive=False):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    entitlements = plistlib.loads(subprocess.check_output(
        ["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL))
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True)
    privacy = plistlib.loads((app / "Contents/Resources/PrivacyInfo.xcprivacy").read_bytes())
    validate_metadata(info, entitlements, arch, privacy)
    if not local:
        signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)],
                                   check=True, capture_output=True, text=True).stderr
        if "TeamIdentifier=LVWWAF3DBK" not in signature:
            raise ValueError("Unexpected signing team")
        # macOS apps without restricted entitlements may legitimately omit a profile.
        # Xcode export and Apple's upload validation check any required provisioning.
        if not archive and not any(prefix in signature for prefix in
            ("Authority=Apple Distribution:", "Authority=3rd Party Mac Developer Application:")):
            raise ValueError("Export requires an App Store distribution signature")
    print(f"Validated: arm64, macOS 14, sandbox, privacy manifest, {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, help="Application bundle or exported store PKG")
    parser.add_argument("--local", action="store_true", help="Accept an ad-hoc signature for sandbox testing")
    parser.add_argument("--archive", action="store_true", help="Accept an Xcode development-signed archive before export")
    args = parser.parse_args()
    if args.app.suffix == ".pkg":
        if args.local or args.archive:
            parser.error("An exported package must use distribution signatures")
        signature = subprocess.check_output(["pkgutil", "--check-signature", str(args.app)], text=True)
        if "3rd Party Mac Developer Installer: ruixing shi (LVWWAF3DBK)" not in signature:
            raise ValueError("Unexpected installer signature")
        with tempfile.TemporaryDirectory(prefix="linse-store-verify-") as directory:
            expanded = Path(directory) / "expanded"
            subprocess.run(["pkgutil", "--expand-full", str(args.app), str(expanded)], check=True)
            apps = list(expanded.rglob("临色.app"))
            if len(apps) != 1:
                raise ValueError("Expected exactly one Linse application in the package")
            validate_app(apps[0])
    else:
        validate_app(args.app, local=args.local, archive=args.archive)


if __name__ == "__main__":
    main()
