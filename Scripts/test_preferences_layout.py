#!/usr/bin/env python3
"""Check that the native snapshot gate rejects obscured or clipped settings headers."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from test_preferences_ui import verify_header_layout


class PreferencesHeaderLayoutChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pm-header-layout-check-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "workspace.layout.json"
        self.layout = {
            "version": 1,
            "contentLayout": {"x": 0, "y": 0, "width": 970, "height": 750},
            "header": {"x": 220, "y": 698, "width": 750, "height": 52},
            "headerVisible": {"x": 220, "y": 698, "width": 750, "height": 52},
            "headerHidden": False,
            "fullSizeContentView": False,
        }

    def verify(self, layout=None):
        self.path.write_text(json.dumps(self.layout if layout is None else layout))
        return verify_header_layout(self.path)

    def test_visible_header_passes(self):
        self.assertEqual(self.verify(), self.layout)

    def test_header_under_title_bar_fails(self):
        self.layout["header"]["y"] += 28
        self.layout["headerVisible"] = copy.deepcopy(self.layout["header"])
        with self.assertRaisesRegex(AssertionError, "contentLayout"):
            self.verify()

    def test_parent_clipping_fails(self):
        self.layout["headerVisible"]["height"] = 24
        with self.assertRaisesRegex(AssertionError, "headerVisible"):
            self.verify()

    def test_hidden_header_fails(self):
        self.layout["headerHidden"] = True
        with self.assertRaisesRegex(AssertionError, "hidden"):
            self.verify()

    def test_compressed_header_fails(self):
        self.layout["header"]["height"] = 20
        with self.assertRaisesRegex(AssertionError, "compressed"):
            self.verify()

    def test_horizontal_clipping_fails(self):
        self.layout["headerVisible"]["width"] = 120
        with self.assertRaisesRegex(AssertionError, "headerVisible"):
            self.verify()

    def test_missing_geometry_fails(self):
        del self.layout["header"]
        with self.assertRaises((AssertionError, KeyError)):
            self.verify()

    def test_invalid_geometry_fails(self):
        self.layout["header"]["height"] = float("nan")
        with self.assertRaisesRegex(AssertionError, "Invalid"):
            self.verify()

    def test_subpixel_rounding_is_allowed(self):
        self.layout["headerVisible"]["y"] += 0.25
        self.verify()

    def test_visibility_does_not_depend_on_style_flag(self):
        self.layout["fullSizeContentView"] = True
        self.verify()


if __name__ == "__main__":
    unittest.main()
