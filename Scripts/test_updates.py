#!/usr/bin/env python3
"""Portable checks for the real update-packaging configuration helper."""
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("configure_updates.py")
spec = importlib.util.spec_from_file_location("configure_updates", SCRIPT)
configuration_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configuration_module)
PUBLIC_KEY = base64.b64encode(bytes(range(32))).decode("ascii")
FEED = "https://updates.example.test/ProxyMirror/appcast.xml"


class UpdateConfigurationTests(unittest.TestCase):
    def test_manual_build_has_no_feed(self):
        self.assertIsNone(configuration_module.update_configuration("", ""))

    def test_signed_feed_and_user_controlled_defaults(self):
        value = configuration_module.update_configuration(FEED, PUBLIC_KEY)
        self.assertEqual(value["SUFeedURL"], FEED)
        self.assertEqual(value["SUPublicEDKey"], PUBLIC_KEY)
        self.assertTrue(value["SURequireSignedFeed"])
        self.assertTrue(value["SUVerifyUpdateBeforeExtraction"])
        self.assertFalse(value["SUEnableAutomaticChecks"])
        self.assertFalse(value["SUAutomaticallyUpdate"])
        self.assertFalse(value["SUAllowsAutomaticUpdates"])

    def test_both_settings_are_required(self):
        for feed, key in [(FEED, ""), ("", PUBLIC_KEY)]:
            with self.subTest(feed=feed), self.assertRaises(ValueError):
                configuration_module.update_configuration(feed, key)

    def test_feed_rejects_unsafe_or_invalid_urls(self):
        for feed in ["http://updates.example.test/appcast.xml", "file:///tmp/feed.xml",
                     "https://user:secret@example.test/feed", "https://@example.test/feed",
                     "https://example.test/feed#fragment", "https:///feed",
                     "https://example.test:99999/feed", "https://example.test:abc/feed"]:
            with self.subTest(feed=feed), self.assertRaises(ValueError):
                configuration_module.update_configuration(feed, PUBLIC_KEY)

    def test_key_must_be_base64_ed25519_length(self):
        for key in ["%%%", "YQ==", base64.b64encode(bytes(33)).decode("ascii")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                configuration_module.update_configuration(FEED, key)

    def test_cli_writes_real_staged_plist(self):
        with tempfile.TemporaryDirectory(prefix="pm-update-config-") as folder:
            app = Path(folder, "ProxyMirror.app")
            app.joinpath("Contents").mkdir(parents=True)
            path = app.joinpath("Contents", "Info.plist")
            path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.ProxyMirror", "CFBundleVersion": "4"}))
            environment = dict(os.environ, PM_APPCAST_URL=FEED, PM_UPDATE_PUBLIC_KEY=PUBLIC_KEY)
            completed = subprocess.run([sys.executable, str(SCRIPT), str(app)], env=environment,
                                       capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            value = plistlib.loads(path.read_bytes())
            self.assertEqual(value["CFBundleIdentifier"], "test.ProxyMirror")
            self.assertEqual(value["SUFeedURL"], FEED)
            self.assertTrue(value["SURequireSignedFeed"])

    def test_failed_configuration_preserves_plist(self):
        with tempfile.TemporaryDirectory(prefix="pm-update-invalid-") as folder:
            app = Path(folder, "ProxyMirror.app")
            app.joinpath("Contents").mkdir(parents=True)
            path = app.joinpath("Contents", "Info.plist")
            original = plistlib.dumps({"CFBundleIdentifier": "test.ProxyMirror"})
            path.write_bytes(original)
            environment = dict(os.environ, PM_APPCAST_URL=FEED, PM_UPDATE_PUBLIC_KEY="invalid")
            completed = subprocess.run([sys.executable, str(SCRIPT), str(app)], env=environment,
                                       capture_output=True, text=True)
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
