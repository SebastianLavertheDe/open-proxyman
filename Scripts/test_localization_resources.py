#!/usr/bin/env python3
"""Exercise malformed-resource and placeholder rejection with real checker code."""
import tempfile
from pathlib import Path
import os
import plistlib
import re
import sys
import subprocess
import unittest
from unittest.mock import patch

import check_localization as checker
import audit_ui_localization as ui_audit

class LocalizationResourceChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="proxymirror-localization-checks-")
        self.path = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def strings(self, content):
        file = self.path / "Fixture.strings"
        file.write_text(content)
        return checker.load_strings(file)

    def test_quoted_unicode_and_comments(self):
        self.assertEqual(self.strings('/* context */ "greeting" = "你好"; // trailing\n'), {"greeting": "你好"})

    def test_duplicate_key_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.strings('"greeting" = "Hello"; "greeting" = "Other";')

    def test_raw_text_is_not_a_key(self):
        with self.assertRaisesRegex(ValueError, "stable lower_snake_case"):
            self.strings('"保存设置" = "Save Settings";')

    def test_missing_semicolon_rejected(self):
        with self.assertRaises(ValueError):
            self.strings('"greeting" = "Hello"')

    def test_empty_translation_rejected(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            self.strings('"greeting" = "";')

    def test_literal_percentage(self):
        self.assertEqual(checker.signature("100%% ready"), ())
        self.assertEqual(checker.signature("%ld%% ready"), ("Int",))

    def test_unknown_percentage_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unescaped"):
            checker.signature("100%")

    def test_printf_types(self):
        self.assertEqual(checker.signature("%1$@ / %2$ld / %3$lld / %4$.2f"), ("String", "Int", "Int64", "Double"))

    def test_positional_reordering(self):
        self.assertEqual(checker.signature("%2$ld for %1$@"), checker.signature("%1$@: %2$ld"))

    def test_conflicting_position_rejected(self):
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            checker.signature("%1$ld / %1$@")

    def test_mixed_positions_rejected(self):
        with self.assertRaisesRegex(ValueError, "Mixed"):
            checker.signature("%@ / %2$ld")

    def test_noncontiguous_positions_rejected(self):
        with self.assertRaisesRegex(ValueError, "Non-contiguous"):
            checker.signature("%2$ld requests")

    def test_plural_variant_can_reference_later_argument(self):
        self.assertEqual(checker.signature("%2$ld requests", allow_sparse=True), ("Int",))

    def test_missing_english_plural_rejected(self):
        file = self.path / "Fixture.stringsdict"
        file.write_bytes(plistlib.dumps({"request_count": {
            "NSStringLocalizedFormatKey": "%#@count@",
            "count": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                      "NSStringFormatValueTypeKey": "ld", "other": "%ld requests"}
        }}))
        with self.assertRaisesRegex(ValueError, "missing"):
            checker.load_plurals(file, "en")
        self.assertIn("request_count", checker.load_plurals(file, "zh-Hans"))

    def plural(self, outer="%#@count@", one="%ld request", other="%ld requests", fallback=None, variables=None):
        entry = {"NSStringLocalizedFormatKey": outer, **(variables or {"count": {
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "ld",
            "one": one, "other": other,
        }})}
        file = self.path / "Fixture.stringsdict"
        file.write_bytes(plistlib.dumps({"request_count": entry}))
        return checker.load_plurals(file, "en", None if fallback is None else {"request_count": fallback})

    def test_plural_branch_rejects_out_of_range_position(self):
        with self.assertRaisesRegex(ValueError, "position 99.*outside"):
            self.plural(one="%99$ld request", other="%99$ld requests")

    def test_placeholder_position_zero_rejected(self):
        with self.assertRaisesRegex(ValueError, "Invalid placeholder position 0"):
            self.plural(one="%0$ld request")

    def test_large_position_is_rejected_without_allocating_a_range(self):
        with self.assertRaisesRegex(ValueError, "Non-contiguous"):
            checker.signature("%999999999999$ld requests")

    def test_plural_branch_preserves_argument_types_by_position(self):
        with self.assertRaisesRegex(ValueError, "placeholder 1 expects String, got Int"):
            self.plural(outer="%1$@ · %2$#@count@", one="%1$ld request", fallback="%1$@ · %2$ld requests")

    def test_plural_branch_can_use_later_global_position(self):
        self.assertIn("request_count", self.plural(outer="%1$@ · %2$#@count@",
                                                  one="%2$ld request", other="%2$ld requests",
                                                  fallback="%1$@ · %2$ld requests"))

    def test_implicit_plural_branch_uses_its_count_argument(self):
        self.assertIn("request_count", self.plural(outer="%1$@ · %2$#@count@", fallback="%1$@ · %2$ld requests"))

    def test_plural_branch_allows_valid_global_reordering(self):
        self.assertIn("request_count", self.plural(outer="%2$#@count@ for %1$@",
                                                  one="%2$ld request for %1$@", other="for %1$@: %2$ld requests",
                                                  fallback="%1$@ · %2$ld requests"))

    def test_plural_branch_can_omit_the_number(self):
        self.assertIn("request_count", self.plural(one="One request"))

    def test_plural_branch_can_reference_other_call_arguments(self):
        # A plural decision can use argument 1 while its text renders arguments 2/3.
        self.assertIn("request_count", self.plural(one="%2$@ expected in %3$ld hour",
                                                  other="%2$@ expected in %3$ld hours",
                                                  fallback="%1$ld / %2$@ / %3$ld"))

    def test_plural_outer_reference_is_checked_against_fallback(self):
        with self.assertRaisesRegex(ValueError, "position 2.*outside"):
            self.plural(outer="%2$#@count@", fallback="%ld requests")

    def test_multiple_plural_variables_keep_their_own_positions(self):
        variables = {
            "first": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "ld",
                      "one": "%ld request", "other": "%ld requests"},
            "second": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                       "one": "%lld byte", "other": "%2$lld bytes"},
        }
        self.assertIn("request_count", self.plural(outer="%2$#@second@ / %1$#@first@",
                                                  variables=variables, fallback="%1$ld requests / %2$lld bytes"))

    def test_unused_plural_variable_rejected(self):
        with self.assertRaisesRegex(ValueError, "unused plural variable"):
            self.plural(outer="%ld requests")

    def test_actual_resources(self):
        catalogues, _ = checker.catalogue()
        self.assertGreater(sum(map(len, catalogues["en"].values())), 0)


class GeneratedAccessorChecks(unittest.TestCase):
    """Use actual SwiftGen; a fingerprint-shaped comment is not proof of output."""

    @classmethod
    def setUpClass(cls):
        cls.generator = checker.swiftgen_executable()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pm-accessor-checks-")
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name)
        resources = self.path / "Resources"
        english = {"cancel": "Cancel", "delete": "Delete"}
        for language in ("en", "zh-Hans"):
            folder = resources / (language + ".lproj")
            folder.mkdir(parents=True)
            (folder / "Common.strings").write_bytes(plistlib.dumps(english))
        override = patch.object(checker, "RESOURCES", resources)
        override.start()
        self.addCleanup(override.stop)
        self.catalogues = {"en": {"Common": english}}
        self.generated = self.path / "Generated"
        self.generated.mkdir()
        self.expected = checker.render_accessors(self.catalogues, self.generator)
        (self.generated / "Strings.swift").write_bytes(self.expected)

    def test_matching_real_swiftgen_output_passes(self):
        checker.verify_generated(self.catalogues, self.generated, self.generator)

    def test_wrong_accessor_is_rejected_with_unchanged_fingerprint(self):
        original = self.expected.decode("utf-8")
        modified, count = re.subn(r'(static var cancel: String \{\s+L10n\.render\(table: "Common", key: ")cancel(")',
                                  r'\1delete\2', original, count=1)
        self.assertEqual(count, 1)
        marker = "// Resource fingerprint: " + checker.fingerprint()
        self.assertIn(marker, modified)
        (self.generated / "Strings.swift").write_text(modified)
        with self.assertRaisesRegex(ValueError, "differ from real SwiftGen output"):
            checker.verify_generated(self.catalogues, self.generated, self.generator)
        self.assertEqual((self.generated / "Strings.swift").read_text(), modified, "Verification must not rewrite sources")

    def test_missing_generator_fails_closed(self):
        with patch.object(checker.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "SwiftGen 6.6.3 is required"):
                checker.verify_generated(self.catalogues, self.generated)

    def test_generator_version_is_not_taken_from_a_dependency(self):
        wrong = subprocess.CompletedProcess([], 0, "SwiftGen v6.6.2 (SwiftGenKit v6.6.3)\n", "")
        with patch.object(checker.subprocess, "run", return_value=wrong):
            with self.assertRaisesRegex(ValueError, "Expected SwiftGen 6.6.3"):
                checker.swiftgen_executable(self.generator)


class UILocalizationAuditChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pm-ui-audit-checks-")
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name)
        for relative in ("Sources/ProxyMirrorCore/UI", "Sources/ProxyMirrorCore/DesktopApplication", "Sources/ProxyMirror"):
            (self.path / relative).mkdir(parents=True)
        override = patch.object(ui_audit, "ROOT", self.path)
        override.start()
        self.addCleanup(override.stop)

    def test_moved_desktop_application_is_audited(self):
        source = 'Text("Untranslated desktop text")'
        path = "Sources/ProxyMirrorCore/DesktopApplication/ProxyMirrorApp.swift"
        (self.path / path).write_text(source)
        self.assertIn((path, source), ui_audit.candidates())

    def test_thin_application_entry_remains_audited(self):
        source = 'Text("Untranslated entry text")'
        path = "Sources/ProxyMirror/main.swift"
        (self.path / path).write_text(source)
        self.assertIn((path, source), ui_audit.candidates())

    def test_missing_source_directory_fails_instead_of_silently_skipping(self):
        (self.path / "Sources/ProxyMirrorCore/DesktopApplication").rmdir()
        with self.assertRaisesRegex(ValueError, "Missing UI audit source directory"):
            ui_audit.candidates()


class DefaultGateChecks(unittest.TestCase):
    def test_regeneration_rejects_wrong_generator_before_running_it(self):
        with tempfile.TemporaryDirectory(prefix="pm-generator-version-") as folder:
            directory = Path(folder)
            marker = directory / "unexpected-generation"
            generator = directory / "swiftgen"
            generator.write_text("#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n"
                                 "if sys.argv[1:] == ['--version']:\n"
                                 " print('SwiftGen v6.6.2 (SwiftGenKit v6.6.3)')\n"
                                 "else:\n Path(" + repr(str(marker)) + ").touch()\n")
            generator.chmod(0o700)
            result = subprocess.run(["bash", str(checker.ROOT / "Scripts/generate_localization.sh")],
                                    env=dict(os.environ, SWIFTGEN_BIN=str(generator)), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Expected SwiftGen 6.6.3", result.stderr)
            self.assertFalse(marker.exists(), "A mismatched generator must not produce any output")

    def test_default_gate_rejects_wrong_accessor_with_original_fingerprint(self):
        catalogues, _ = checker.catalogue()
        generated = checker.render_accessors(catalogues).decode("utf-8")
        modified, count = re.subn(r'(static var cancel: String \{\s+L10n\.render\(table: "Common", key: ")cancel(")',
                                  r'\1delete\2', generated, count=1)
        self.assertEqual(count, 1)
        self.assertIn("// Resource fingerprint: " + checker.fingerprint(), modified)
        with tempfile.TemporaryDirectory(prefix="pm-default-gate-") as folder:
            directory = Path(folder)
            (directory / "Strings.swift").write_text(modified)
            (directory / "EnglishFallbacks.swift").write_text(checker.english_support(catalogues["en"]))
            with patch.object(checker, "GENERATED", directory), patch.object(sys, "argv", ["check_localization.py"]):
                with self.assertRaisesRegex(ValueError, "differ from real SwiftGen output"):
                    checker.main()

if __name__ == "__main__":
    unittest.main()
