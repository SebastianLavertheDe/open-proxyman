#!/usr/bin/env python3
"""Exercise the bundle gate with complete resources and deliberately broken copies."""
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

from prepare_app_resources import normalize_localizations, write_licenses
from test_localization_bundle import CORE_BUNDLE, LANGUAGES, ROOT, read_strings, verify_resources, verify_selection_count


class LocalizationPackagingChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pm-language-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Fixture.app"
        self.contents = self.app / "Contents"
        self.resources = self.contents / "Resources"
        self.resources.mkdir(parents=True)
        self.info = {"CFBundleLocalizations": list(LANGUAGES), "CFBundleDevelopmentRegion": "en",
                     "CFBundleIdentifier": "test.ProxyMirror.Localization"}
        self.write_info()
        self.core = self.resources / CORE_BUNDLE
        shutil.copytree(ROOT / "Sources/ProxyMirrorCore/Resources", self.core)
        for language in LANGUAGES:
            shutil.copytree(ROOT / "Resources" / f"{language}.lproj", self.resources / f"{language}.lproj")

    def write_info(self):
        (self.contents / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_complete_source_resources_pass(self):
        self.assertGreater(verify_resources(self.app), 0)

    def test_lowercase_swiftpm_localization_is_normalized(self):
        (self.core / "zh-Hans.lproj").rename(self.core / "zh-hans.lproj")
        normalize_localizations(self.core)
        self.assertIn("zh-Hans.lproj", [path.name for path in self.core.iterdir()])
        self.assertGreater(verify_resources(self.app), 0)

    def test_nested_macos_bundle_localization_is_normalized(self):
        entries = list(self.core.iterdir())
        resources = self.core / "Contents/Resources"
        resources.mkdir(parents=True)
        for path in entries:
            path.rename(resources / path.name)
        (resources / "zh-Hans.lproj").rename(resources / "zh-hans.lproj")
        normalize_localizations(self.core)
        self.assertIn("zh-Hans.lproj", [path.name for path in resources.iterdir()])
        self.assertGreater(verify_resources(self.app), 0)

    def test_ambiguous_language_directories_fail(self):
        duplicate = self.core / "zh-hans.lproj"
        if duplicate.exists():
            self.skipTest("Filesystem does not allow case-distinct directories")
        duplicate.mkdir()
        with self.assertRaisesRegex(ValueError, "found 2"):
            normalize_localizations(self.core)

    def test_missing_language_is_not_silently_accepted(self):
        shutil.rmtree(self.core / "zh-Hans.lproj")
        with self.assertRaisesRegex(ValueError, "found 0"):
            normalize_localizations(self.core)

    def test_licenses_are_rewritten_as_plain_text(self):
        destination = self.resources / "ThirdParty"
        write_licenses(destination)
        self.assertEqual((destination / "ScriptingLibraries-LICENSE").read_text(encoding="utf-8"),
                         (ROOT / "ThirdParty/ScriptingLibraries.md").read_text(encoding="utf-8"))
        self.assertEqual((destination / "Zstandard-LICENSE").read_text(encoding="utf-8"),
                         (ROOT / "Sources/ProxyMirrorZstd/LICENSE").read_text(encoding="utf-8"))
        self.assertFalse(list(destination.glob("*.md")))

    def test_native_count_grouping_is_accepted_in_both_languages(self):
        for number in ("1000", "1,000"):
            verify_selection_count({"count": 1000, "text": f"{number} requests selected"}, "en")
            verify_selection_count({"count": 1000, "text": f"已选择 {number} 条请求"}, "zh-Hans")
        verify_selection_count({"count": 1, "text": "1 request selected"}, "en")

    def test_native_count_validation_still_rejects_wrong_text(self):
        for count, text in ((1000, "1,001 requests selected"), (1, "1 requests selected"),
                            (1000, "1,000 request selected"), (0, "0 request selected")):
            with self.assertRaises(ValueError):
                verify_selection_count({"count": count, "text": text}, "en")

    def test_missing_bundle_fails(self):
        shutil.rmtree(self.core)
        with self.assertRaises(ValueError):
            verify_resources(self.app)

    def test_matching_missing_tables_in_both_languages_fail(self):
        for language in LANGUAGES:
            (self.core / f"{language}.lproj/Settings.strings").unlink()
        with self.assertRaises(ValueError):
            verify_resources(self.app)

    def test_matching_missing_keys_in_both_languages_fail(self):
        for language in LANGUAGES:
            (self.core / f"{language}.lproj/Diagnostics.strings").write_text(
                '"interface_label" = "Changed";\n')
        with self.assertRaises(ValueError):
            verify_resources(self.app)

    def test_changed_translation_fails(self):
        path = self.core / "en.lproj/Diagnostics.strings"
        path.write_text(path.read_text().replace("Application Language", "A stale translation"))
        with self.assertRaises(ValueError):
            verify_resources(self.app)

    def test_missing_metadata_fails(self):
        (self.resources / "en.lproj/InfoPlist.strings").unlink()
        with self.assertRaises(OSError):
            verify_resources(self.app)

    def test_metadata_language_swap_fails(self):
        english = self.resources / "en.lproj/InfoPlist.strings"
        english.write_bytes((self.resources / "zh-Hans.lproj/InfoPlist.strings").read_bytes())
        with self.assertRaises(ValueError):
            verify_resources(self.app)

    def test_unsupported_language_declaration_fails(self):
        self.info["CFBundleLocalizations"] = ["en", "zh-Hans", "fr"]
        self.write_info()
        with self.assertRaises(ValueError):
            verify_resources(self.app)

    def test_development_language_must_match_fallback(self):
        self.info["CFBundleDevelopmentRegion"] = "zh-Hans"
        self.write_info()
        with self.assertRaises(ValueError):
            verify_resources(self.app)

    def test_symlinked_resource_bundle_is_rejected(self):
        moved = Path(self.temporary.name) / "Outside.bundle"
        self.core.rename(moved)
        self.core.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(ValueError):
            verify_resources(self.app)

    def test_native_string_encodings(self):
        path = Path(self.temporary.name) / "Native.strings"
        for payload in (b"\xff\xfe" + '"label" = "中文";'.encode("utf-16-le"),
                        plistlib.dumps({"label": "中文"}, fmt=plistlib.FMT_BINARY)):
            path.write_bytes(payload)
            self.assertEqual(read_strings(path), {"label": "中文"})

    def test_duplicate_keys_are_rejected(self):
        path = Path(self.temporary.name) / "Duplicate.strings"
        path.write_text('"label" = "A";\n"label" = "B";\n')
        with self.assertRaises(ValueError):
            read_strings(path)


if __name__ == "__main__":
    unittest.main()
