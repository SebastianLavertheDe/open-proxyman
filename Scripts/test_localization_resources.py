#!/usr/bin/env python3
"""Exercise malformed-resource and placeholder rejection with real checker code."""
import tempfile
from pathlib import Path
import plistlib
import unittest

import check_localization as checker

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

    def test_actual_resources(self):
        catalogues, _ = checker.catalogue()
        self.assertGreater(sum(map(len, catalogues["en"].values())), 0)

if __name__ == "__main__":
    unittest.main()
