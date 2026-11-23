#!/usr/bin/env python3
"""Run the shared settings-routing assertions against the production Foundation models."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    source = (ROOT / "Tests/ProxyMirrorCoreChecks/SettingsChecks.swift").read_text()
    start = source.index("private func checkSettingsSearchDestinations(")
    end = source.index("private func checkSystemBypassSettings(", start)
    fixture = r'''
import Foundation
struct CoreAssertions {
    let report: (Bool, String) -> Void
    func expect(_ condition: Bool, _ message: String) { report(condition, message) }
}
''' + source[start:end] + r'''
@main struct Runner {
    static func main() {
        var checks = 0
        checkSettingsSearchDestinations(CoreAssertions { passed, message in
            precondition(passed, message)
            checks += 1
        })
        let language = ProcessInfo.processInfo.environment["PM_SETTINGS_LANGUAGE"] ?? "en"
        precondition(PreferencesPage.general.title == (language == "en" ? "General" : "常规"),
                     "The displayed page title must use the selected native resource")
        for target in SettingsSearchTarget.allCases {
            precondition(SettingsSearchTarget.results(for: target.title).contains(target),
                         "Every displayed setting title must remain searchable")
            checks += 1
        }
        print("PASS: \(checks) production settings search routes [\(language)]")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="pm-settings-search-") as folder:
        folder = Path(folder)
        entry = folder / "Checks.swift"
        entry.write_text(fixture)
        binary = folder / "checks"
        compiler = shutil.which(args.swiftc) or args.swiftc
        runtime = ROOT / "Sources/ProxyMirrorCore/Localization"
        generated = runtime / "Generated"
        dependencies = [
            runtime / "AppLanguage.swift",
            runtime / "LocalizationResources.swift",
            runtime / "LocalizationContext.swift",
            ROOT / "Sources/ProxyMirrorCore/UI/PresentationLocalization.swift",
            *sorted(generated.glob("*.swift")),
        ]
        if not (generated / "Strings.swift").is_file():
            parser.error("Generate the localization accessors before running this test.")
        subprocess.run([compiler, "-swift-version", "5", "-module-cache-path", str(folder / "modules"),
                        *map(str, dependencies),
                        str(ROOT / "Sources/ProxyMirrorCore/UI/Settings/PreferencesPage.swift"),
                        str(ROOT / "Sources/ProxyMirrorCore/UI/Settings/SettingsSearchTarget.swift"),
                        str(entry), "-o", str(binary)], check=True, timeout=120)
        for language in ("en", "zh-Hans"):
            env = {**os.environ, "PM_SETTINGS_LANGUAGE": language,
                   "PM_LOCALIZATION_RESOURCE_DIR": str(ROOT / "Sources/ProxyMirrorCore/Resources")}
            subprocess.run([str(binary)], env=env, check=True, timeout=15)


if __name__ == "__main__":
    main()
