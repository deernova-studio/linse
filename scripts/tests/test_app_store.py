import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("verify_app_store", Path(__file__).parents[1] / "verify-app-store.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StoreBundleTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleIdentifier": "app.linse.mac", "LSMinimumSystemVersion": "14.0",
                     "CFBundleVersion": "14", "CFBundleShortVersionString": "0.3.0"}
        self.entitlements = {key: True for key in (
            "com.apple.security.app-sandbox", "com.apple.security.network.client",
            "com.apple.security.files.user-selected.read-write")}
        self.privacy = {"NSPrivacyTracking": False}

    def validate(self, arch="arm64"):
        module.validate_metadata(self.info, self.entitlements, arch, self.privacy)

    def test_valid_bundle_and_rejects_intel_or_universal(self):
        self.validate()
        for arch in ("x86_64", "arm64 x86_64"):
            with self.assertRaises(ValueError):
                self.validate(arch)

    def test_catches_missing_sandbox_and_wrong_app(self):
        self.entitlements["com.apple.security.app-sandbox"] = False
        with self.assertRaises(ValueError):
            self.validate()
        self.entitlements["com.apple.security.app-sandbox"] = True
        self.info["CFBundleIdentifier"] = "app.linse.other"
        with self.assertRaises(ValueError):
            self.validate()

    def test_catches_accidental_privacy_or_target_changes(self):
        self.privacy["NSPrivacyTracking"] = True
        with self.assertRaises(ValueError):
            self.validate()
        self.privacy["NSPrivacyTracking"] = False
        self.info["LSMinimumSystemVersion"] = "15.0"
        with self.assertRaises(ValueError):
            self.validate()
