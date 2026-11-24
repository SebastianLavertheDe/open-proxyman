#!/usr/bin/env python3
"""Run the real minimap geometry and date formatter on any Swift host.

Native font, glyph, selection and scrolling checks live in AppearanceDisplayChecks
and require macOS. This runner deliberately tests only the portable model code.
"""
import argparse
from pathlib import Path
from foundation_test_support import build_foundation_module
import subprocess
import tempfile


def declaration(path: Path, name: str) -> str:
    source = path.read_text()
    start = source.index(f"enum {name} {{")
    end = source.index("\n}", start) + 2
    return source[start:end]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    geometry = declaration(root / "Sources/ProxyMirrorCore/UI/CodeDocument.swift", "CodeViewportGeometry")
    clock = declaration(root / "Sources/ProxyMirrorCore/UI/PresentationSettings.swift", "PresentationTime")
    harness = r'''
import Foundation
// Only the settings container is stubbed. The formatter and geometry above are
// extracted verbatim from production source.
final class AppSettings {
    static let shared = AppSettings()
    var use24HourClock = true
    var showFullDate = false
}
'''
    checks = r'''
var checks = 0
func expect<T: Equatable>(_ actual: T, _ expected: T) {
    precondition(actual == expected, "Expected \(expected), got \(actual)")
    checks += 1
}
expect(CodeViewportGeometry.origin(at: 0, documentHeight: 1000, viewportHeight: 200), 0)
expect(CodeViewportGeometry.origin(at: 1, documentHeight: 1000, viewportHeight: 200), 800)
expect(CodeViewportGeometry.origin(at: 0.5, documentHeight: 1000, viewportHeight: 200), 400)
expect(CodeViewportGeometry.origin(at: -2, documentHeight: 1000, viewportHeight: 200), 0)
expect(CodeViewportGeometry.origin(at: 2, documentHeight: 1000, viewportHeight: 200), 800)
expect(CodeViewportGeometry.origin(at: 1, documentHeight: 80, viewportHeight: 200), 0)
expect(CodeViewportGeometry.visibleRange(origin: 400, documentHeight: 1000, viewportHeight: 200), 0.4...0.6)
expect(CodeViewportGeometry.visibleRange(origin: 800, documentHeight: 1000, viewportHeight: 200), 0.8...1)
expect(CodeViewportGeometry.visibleRange(origin: 0, documentHeight: 80, viewportHeight: 200), 0...1)
expect(CodeViewportGeometry.visibleRange(origin: 0, documentHeight: 0, viewportHeight: 200), 0...1)
let date = Date(timeIntervalSince1970: 13 * 3600 + 4 * 60 + 5.123)
let utc = TimeZone(secondsFromGMT: 0)!
let east = TimeZone(secondsFromGMT: 8 * 3600)!
let west = TimeZone(secondsFromGMT: -5 * 3600 - 30 * 60)!
let english = Locale(identifier: "en_US_POSIX")
let chinese = Locale(identifier: "zh_CN")
expect(PresentationTime.string(from: date, uses24HourClock: true, includesDate: false, timeZone: utc, locale: english), "13:04:05.123")
expect(PresentationTime.string(from: date, uses24HourClock: false, includesDate: false, timeZone: utc, locale: english), "01:04:05.123 PM")
expect(PresentationTime.string(from: date, uses24HourClock: true, includesDate: true, timeZone: utc, locale: english), "1970-01-01 13:04:05.123 +00:00")
expect(PresentationTime.string(from: date, uses24HourClock: false, includesDate: true, timeZone: utc, locale: english), "1970-01-01 01:04:05.123 PM +00:00")
expect(PresentationTime.string(from: date, uses24HourClock: true, includesDate: true, timeZone: east, locale: english), "1970-01-01 21:04:05.123 +08:00")
expect(PresentationTime.string(from: date, uses24HourClock: true, includesDate: true, timeZone: west, locale: english), "1970-01-01 07:34:05.123 -05:30")
expect(PresentationTime.string(from: date, uses24HourClock: true, includesDate: false, timeZone: east, locale: english), "21:04:05.123")
expect(PresentationTime.string(from: date, uses24HourClock: true, includesDate: true, timeZone: utc, locale: english), "1970-01-01 13:04:05.123 +00:00")
let settings = AppSettings()
settings.showFullDate = true
expect(PresentationTime.string(from: date, settings: settings, timeZone: east, locale: english), "1970-01-01 21:04:05.123 +08:00")
settings.use24HourClock = false
expect(PresentationTime.string(from: date, settings: settings, timeZone: east, locale: english), "1970-01-01 09:04:05.123 PM +08:00")
// Region-sensitive AM/PM symbols must not contaminate another locale's cache.
expect(PresentationTime.string(from: date, uses24HourClock: false, includesDate: false, timeZone: utc, locale: chinese), "01:04:05.123 下午")
expect(PresentationTime.string(from: date, uses24HourClock: false, includesDate: false, timeZone: utc, locale: english), "01:04:05.123 PM")
expect(PresentationTime.string(from: date, uses24HourClock: true, includesDate: false, timeZone: utc, locale: chinese), "13:04:05.123")
expect(PresentationTime.string(from: date, uses24HourClock: true, includesDate: true, timeZone: east, locale: chinese), "1970-01-01 21:04:05.123 +08:00")
print("Display models: \(checks) checks passed")
'''
    with tempfile.TemporaryDirectory(prefix="pm-display-models-") as directory:
        path = Path(directory)
        module_flags = build_foundation_module(args.swiftc, path)
        source = path / "main.swift"
        source.write_text("@_exported import ProxyMirrorFoundation\n" + harness + geometry + "\n" + clock + "\n" + checks)
        executable = path / "checks"
        subprocess.run([args.swiftc, *module_flags, str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
