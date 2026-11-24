#!/usr/bin/env python3
"""Exercise production lookup against actual SwiftPM-processed resources.

The isolated package contains unchanged localization production sources and
generated accessors. It does not build the macOS GUI or modify its lockfile.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAIN = r'''
import Foundation

var count = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message); count += 1
}
let bundle = Bundle.module
let directories = try FileManager.default.contentsOfDirectory(atPath: bundle.resourceURL!.path)
print("Processed localization directories: " + directories.filter { $0.hasSuffix(".lproj") }.sorted().joined(separator: ", "))
check(AppLanguage.simplifiedChinese.rawValue == "zh-Hans", "Persisted language identifier remains canonical")
check(LocalizationResources.hasLanguages(bundle), "Actual processed bundle contains both supported languages")
for language in AppLanguage.allCases {
    check(LocalizationResources.languageBundle(language, in: bundle) != nil, "Processed language bundle resolves")
    let context = LocalizationContext(language: language, resources: bundle, reportMissing: { _, _ in
        preconditionFailure("Processed lookup must not fall back")
    })
    let expected = language == .english ? "Subject: user.example" : "主题：user.example"
    check(context.render(table: "Tools", key: "certificate_subject", arguments: ["user.example"], englishFallback: "Wrong") == expected,
          "Real processed strings render with their native language")
}
check(L10n.startupIssue == nil, "Raw SwiftPM launch locates its real resources")
let selected = ProcessInfo.processInfo.environment["PM_SETTINGS_LANGUAGE"]!
check(L10n.effectiveLanguage == selected, "Runtime language uses the canonical requested identifier")
check(Strings.Tools.certificateSubject("user.example") == (selected == "en" ? "Subject: user.example" : "主题：user.example"),
      "Production generated interface renders processed resources")

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("pm-processed-app-\(UUID().uuidString)", isDirectory: true)
defer { try? manager.removeItem(at: root) }
let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
#if os(macOS)
let appResources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
let info = appURL.appendingPathComponent("Contents/Info.plist")
#else
let appResources = appURL
let info = appURL.appendingPathComponent("Info.plist")
#endif
try manager.createDirectory(at: appResources, withIntermediateDirectories: true)
try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.processed.\(UUID().uuidString)"], format: .xml, options: 0).write(to: info)
let app = Bundle(url: appURL)!
var queriedDevelopment = false
let missing = LocalizationResources.resolve(in: app, developmentBundle: { queriedDevelopment = true; return bundle })
check(missing.bundle == nil && missing.issue != nil && !queriedDevelopment, "A packaged App missing resources never consults development resources")
let embedded = app.resourceURL!.appendingPathComponent(LocalizationResources.expectedBundleName, isDirectory: true)
try manager.copyItem(at: bundle.bundleURL, to: embedded)
// The original bundle is still loaded in this process. Give the relocated
// fixture a separate identity so Darwin's CFBundle cache cannot alias it back
// to that original; an actual App launch only loads its embedded copy.
let copiedInfo = ["Contents/Info.plist", "Info.plist"].map { embedded.appendingPathComponent($0) }
    .first { manager.fileExists(atPath: $0.path) } ?? embedded.appendingPathComponent("Info.plist")
var copiedMetadata = (try PropertyListSerialization.propertyList(from: Data(contentsOf: copiedInfo), format: nil)) as? [String: Any] ?? [:]
copiedMetadata["CFBundleIdentifier"] = "test.processed.embedded.\(UUID().uuidString)"
try PropertyListSerialization.data(fromPropertyList: copiedMetadata, format: .xml, options: 0).write(to: copiedInfo)
let relocated = LocalizationResources.resolve(in: app, developmentBundle: { queriedDevelopment = true; return nil })
check(relocated.bundle?.bundleURL.standardizedFileURL.path == embedded.standardizedFileURL.path && relocated.issue == nil && !queriedDevelopment, "Embedded processed resources are accepted after relocation")
let chinese = LocalizationContext(language: .simplifiedChinese, resources: relocated.bundle, reportMissing: { _, _ in preconditionFailure("Embedded lookup failed") })
check(chinese.render(table: "Tools", key: "certificate_subject", arguments: ["user.example"], englishFallback: "Wrong") == "主题：user.example", "Relocated processed Chinese resources are readable")
let chineseDirectory = LocalizationResources.languageBundle(.simplifiedChinese, in: relocated.bundle!)!.bundleURL
try manager.removeItem(at: chineseDirectory)
let damaged = LocalizationResources.resolve(in: app, developmentBundle: { queriedDevelopment = true; return bundle })
check(damaged.bundle == nil && damaged.issue != nil && !queriedDevelopment, "An embedded bundle missing a required language remains invalid")
print("Processed localization: \(count) checks passed (\(selected))")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default=shutil.which("swift"))
    args = parser.parse_args()
    if not args.swift:
        parser.error("swift is required")
    with tempfile.TemporaryDirectory(prefix="pm-processed-localization-") as temporary:
        package = Path(temporary)
        target = package / "Sources/ProcessedLocalizationChecks"
        target.mkdir(parents=True)
        shutil.copytree(ROOT / "Sources/ProxyMirrorCore/Resources", target / "Resources")
        for source in ["Localization/AppLanguage.swift", "Localization/LocalizationResources.swift",
                       "Localization/LocalizationContext.swift", "UI/PresentationLocalization.swift",
                       "Localization/Generated/Strings.swift", "Localization/Generated/EnglishFallbacks.swift"]:
            shutil.copy2(ROOT / "Sources/ProxyMirrorCore" / source, target / Path(source).name)
        (target / "main.swift").write_text(MAIN)
        (package / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ProcessedLocalizationChecks", defaultLocalization: "en", targets: [
    .executableTarget(name: "ProcessedLocalizationChecks", resources: [.process("Resources")])
])
''')
        command = [args.swift, "build", "--package-path", str(package), "-j", "2"]
        subprocess.run(command, cwd=package, check=True, timeout=180)
        binaries = subprocess.check_output([*command, "--show-bin-path"], cwd=package, text=True, timeout=30).strip()
        for language in ("en", "zh-Hans"):
            environment = dict(os.environ, PM_SETTINGS_LANGUAGE=language)
            environment.pop("PM_LOCALIZATION_RESOURCE_DIR", None)
            subprocess.run([str(Path(binaries) / "ProcessedLocalizationChecks")], cwd=package,
                           env=environment, check=True, timeout=30)


if __name__ == "__main__":
    main()
