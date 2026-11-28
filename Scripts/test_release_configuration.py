#!/usr/bin/env python3
"""Exercise release metadata without touching a real app or signing identity."""
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from configure_release import configure, signing_identity


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pm-release-config-")
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Fixture.app"
        self.path = self.app / "Contents/Info.plist"
        self.path.parent.mkdir(parents=True)
        self.original = plistlib.dumps({"CFBundleVersion": "4", "CFBundleShortVersionString": "1.1.1", "unrelated": True})
        self.path.write_bytes(self.original)

    def test_development_build_remains_byte_identical(self):
        configure(self.app, {})
        self.assertEqual(self.path.read_bytes(), self.original)

    def test_numeric_release_metadata_preserves_other_fields(self):
        configure(self.app, {"PM_RELEASE_VERSION": "1.2.3", "PM_BUILD_NUMBER": "123"})
        self.assertEqual(plistlib.loads(self.path.read_bytes()), {
            "CFBundleVersion": "123", "CFBundleShortVersionString": "1.2.3", "unrelated": True,
        })

    def test_partial_and_invalid_metadata_never_write(self):
        for environment in [
            {"PM_RELEASE_VERSION": "1.2.3"}, {"PM_BUILD_NUMBER": "5"},
            {"PM_RELEASE_VERSION": "v1.2.3", "PM_BUILD_NUMBER": "5"},
            {"PM_RELEASE_VERSION": "1.2.3<xml>", "PM_BUILD_NUMBER": "5"},
            {"PM_RELEASE_VERSION": "1.2.3", "PM_BUILD_NUMBER": "0"},
            {"PM_RELEASE_VERSION": "1.2.3", "PM_BUILD_NUMBER": "-1"},
            {"PM_RELEASE_VERSION": "１.２.３", "PM_BUILD_NUMBER": "5"},
            {"PM_RELEASE_VERSION": "1.2.3", "PM_BUILD_NUMBER": "1５"},
        ]:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                configure(self.app, environment)
            self.assertEqual(self.path.read_bytes(), self.original)


class ReleaseIdentityTests(unittest.TestCase):
    fingerprint = "A" * 40
    team = "AB12CD34EF"
    name = "Developer ID Application: Example Company (AB12CD34EF)"

    def identity(self, requested=None, team=None, identities=None):
        output = identities or f'  1) {self.fingerprint} "{self.name}"\n     1 valid identities found\n'
        with patch("prepare_transparent_signing.subprocess.check_output", return_value=output) as call:
            selected = signing_identity({"PM_DEVELOPER_ID": requested or self.name,
                                         "PM_NOTARY_TEAM_ID": team or self.team}, "/isolated/release.keychain-db")
        self.assertEqual(call.call_args.args[0][-1], "/isolated/release.keychain-db")
        return selected

    def test_exact_name_and_fingerprint_select_only_the_imported_keychain(self):
        self.assertEqual(self.identity(), self.fingerprint)
        self.assertEqual(self.identity(requested=self.fingerprint.lower()), self.fingerprint)

    def test_substring_ad_hoc_development_and_ambiguous_identities_fail(self):
        for requested in ("Example Company", "-", "Apple Development: Example Company (AB12CD34EF)"):
            with self.subTest(requested=requested), self.assertRaises(ValueError):
                self.identity(requested=requested)
        duplicate = f'  1) {self.fingerprint} "{self.name}"\n  2) {"B" * 40} "{self.name}"\n'
        with self.assertRaises(ValueError):
            self.identity(identities=duplicate)

    def test_mismatched_notary_team_fails(self):
        with self.assertRaisesRegex(ValueError, "PM_NOTARY_TEAM_ID"):
            self.identity(team="XX12YY34ZZ")


if __name__ == "__main__":
    unittest.main()
