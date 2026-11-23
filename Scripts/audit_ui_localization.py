#!/usr/bin/env python3
"""Reject unclassified direct UI text; keep explicit, reviewed technical exceptions."""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
EXCEPTIONS = ROOT / "Docs/localization-ui-exceptions.json"
VISIBLE = re.compile(
    r'\b(?:Text|Button|Toggle|Menu|Label|Picker|GroupBox|TextField|SecureField|Section|Window|'
    r'WindowGroup|CommandMenu|TableColumn|LabeledContent)\(\s*"|'
    r'\.(?:help|accessibilityLabel|accessibilityHint|navigationTitle|alert|confirmationDialog)\(\s*"|'
    r'\b(?:messageText|informativeText|prompt)\s*=\s*"|'
    r'\b(?:setAccessibilityLabel|setAccessibilityHelp|addButton)\([^\n]*"'
)


def candidates():
    paths = list((ROOT / "Sources/ProxyMirrorCore/UI").rglob("*.swift"))
    paths += [ROOT / "Sources/ProxyMirror/App/ProxyMirrorApp.swift",
              ROOT / "Sources/ProxyMirror/App/LocalControl.swift"]
    result = {}
    for path in sorted(paths):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            source = line.strip()
            if source.startswith("//") or not VISIBLE.search(source):
                continue
            key = (str(path.relative_to(ROOT)), source)
            result[key] = number
    return result


def audit():
    entries = json.loads(EXCEPTIONS.read_text())["exceptions"]
    allowed = {}
    for entry in entries:
        if not entry.get("category") or not entry.get("reason"):
            raise ValueError("Every exception needs a reviewed category and reason")
        key = (entry["path"], entry["source"])
        if key in allowed:
            raise ValueError(f"Duplicate UI exception: {key[0]}")
        allowed[key] = entry
    actual = candidates()
    failures = []
    for (path, source), line in actual.items():
        if (path, source) not in allowed:
            failures.append(f"{path}:{line}: unclassified UI literal: {source}")
    for path, source in allowed.keys() - actual.keys():
        failures.append(f"{path}: obsolete UI exception: {source}")
    if failures:
        raise ValueError("\n".join(failures))
    return len(actual)


if __name__ == "__main__":
    try:
        print(f"PASS: direct UI text is localized or explicitly classified ({audit()} technical/data exceptions)")
    except (OSError, ValueError, KeyError) as error:
        print(f"UI localization audit failed: {error}", file=sys.stderr)
        sys.exit(1)
