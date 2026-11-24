#!/usr/bin/env python3
"""Compile the real preference model, backup preference payload and translations.

Only the platform types (Combine publisher, LAN configuration and unrelated rule
validators) are stubbed. No preference implementation is duplicated in the test.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STUBS = r'''
import Foundation
protocol ObservableObject {}
final class ObservableObjectPublisher { func send() {} }
private let testPublisher = ObservableObjectPublisher()
extension ObservableObject { var objectWillChange: ObservableObjectPublisher { testPublisher } }
struct LANAccess {
    init(address: String, device: String, allowedPeerRanges: [String]) {}
}
enum RequestCode { enum Format: String { case curl, httpie, python } }
enum NetworkAccessPolicy { static func validationError(for ranges: [String]) -> String? { nil } }
enum SystemProxyBypassList { static func validationError(_ ranges: [String]) -> String? { nil } }
'''
MAIN = r'''
import Foundation
var passed = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
    passed += 1
}
final class NotificationCounter { var value = 0 }
let sourceName = "ProxyMirror.PreferencesPortable.Source." + UUID().uuidString
let targetName = "ProxyMirror.PreferencesPortable.Target." + UUID().uuidString
let sourceDefaults = UserDefaults(suiteName: sourceName)!
let targetDefaults = UserDefaults(suiteName: targetName)!
defer {
    sourceDefaults.removePersistentDomain(forName: sourceName)
    targetDefaults.removePersistentDomain(forName: targetName)
}
let source = AppSettings(defaults: sourceDefaults)
let target = AppSettings(defaults: targetDefaults)
expect(source.fontSize == 12 && source.useMonospacedFont && !source.scrollBeyondLastLine, "appearance defaults")
expect(source.contentLayout == "vertical" && source.appIconStyle == "earth", "layout and icon defaults")
expect(source.contentDividerIsVertical, "default Vertical layout separates Request and Response with a vertical divider")
expect(source.autoStartRecording && !source.warnBeforeQuit && source.showUpdateNotifications, "launch defaults")
expect(source.applicationLanguage == "system" && source.mcpEnabled && source.mcpRedactSensitiveData, "language and private MCP defaults")
expect(!source.preserveOriginalHeaders && source.restorePreviousSystemProxy, "tool and proxy defaults")
expect(source.automaticTrafficCleanup && source.cleanupMemoryLimitMB == 3072 && source.cleanupIntervalMinutes == 5, "cleanup defaults")
let changes = NotificationCounter()
let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
    object: sourceDefaults, queue: nil) { _ in changes.value += 1 }
source.fontSize = 18
expect(changes.value > 0, "same-process consumers receive preference change notification")
NotificationCenter.default.removeObserver(observer)
source.useMonospacedFont = false; source.scrollBeyondLastLine = true
source.contentLayout = "horizontal"; source.appIconStyle = "mars"; source.appearance = "dark"
source.autoStartRecording = false; source.warnBeforeQuit = true; source.showUpdateNotifications = false
source.applicationLanguage = "en"; source.mcpEnabled = false; source.mcpRedactSensitiveData = false
source.preserveOriginalHeaders = true; source.restorePreviousSystemProxy = false
source.automaticTrafficCleanup = false; source.cleanupMemoryLimitMB = 4096; source.cleanupIntervalMinutes = 10
let saved = RuleBackup.Preferences(source)
expect(saved.valid, "new preference payload validates")
let data = try JSONEncoder().encode(saved)
let payload = try JSONDecoder().decode(RuleBackup.Preferences.self, from: data)
payload.apply(to: target)
expect(target.fontSize == 18 && !target.useMonospacedFont && target.scrollBeyondLastLine, "appearance backup roundtrip")
expect(target.contentLayout == "horizontal" && target.appIconStyle == "mars" && target.appearance == "dark", "layout, icon and theme backup roundtrip")
expect(!target.autoStartRecording && target.warnBeforeQuit && !target.showUpdateNotifications, "behavior backup roundtrip")
expect(target.applicationLanguage == "en" && !target.mcpEnabled && !target.mcpRedactSensitiveData, "MCP and language backup roundtrip")
expect(target.preserveOriginalHeaders && !target.restorePreviousSystemProxy, "tools and restore backup roundtrip")
expect(!target.automaticTrafficCleanup && target.cleanupMemoryLimitMB == 4096 && target.cleanupIntervalMinutes == 10, "cleanup backup roundtrip")
let reloaded = AppSettings(defaults: targetDefaults)
expect(reloaded.fontSize == 18 && reloaded.contentLayout == "horizontal" && !reloaded.mcpEnabled, "real UserDefaults reload")
expect(!reloaded.contentDividerIsVertical, "persisted Horizontal layout uses a horizontal divider for stacked panes")
source.fontSize = .nan; expect(source.fontSize == 12, "nonfinite font size normalizes")
source.fontSize = 100; expect(source.fontSize == 32, "large font size bounds")
source.fontSize = -1; expect(source.fontSize == 8, "small font size bounds")
source.contentLayout = "invalid"; expect(source.contentLayout == "vertical" && source.contentDividerIsVertical, "invalid layout falls back to side-by-side panes")
source.appIconStyle = "invalid"; expect(source.appIconStyle == "earth", "invalid icon fallback")
source.applicationLanguage = "invalid"; expect(source.applicationLanguage == "system", "invalid language fallback")
source.cleanupMemoryLimitMB = 0; source.cleanupIntervalMinutes = 100
expect(source.cleanupMemoryLimitMB == 64 && source.cleanupIntervalMinutes == 60, "cleanup bounds")
var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let extras = object["extras"] as! [String: Any]
for (key, invalid) in [("fontSize", 7 as Any), ("fontSize", 33 as Any), ("contentLayout", "bad" as Any),
    ("appIconStyle", "bad" as Any), ("applicationLanguage", "bad" as Any), ("cleanupMemoryLimitMB", 63 as Any),
    ("cleanupMemoryLimitMB", 65537 as Any), ("cleanupIntervalMinutes", 0 as Any), ("cleanupIntervalMinutes", 61 as Any),
    ("appearance", "bad" as Any)] {
    var mutated = extras; mutated[key] = invalid; object["extras"] = mutated
    let invalidPayload = try JSONDecoder().decode(RuleBackup.Preferences.self,
        from: JSONSerialization.data(withJSONObject: object))
    expect(!invalidPayload.valid, "reject invalid imported " + key)
}
object.removeValue(forKey: "extras")
let partial = try JSONDecoder().decode(RuleBackup.Preferences.self, from: JSONSerialization.data(withJSONObject: object))
target.fontSize = 14; target.mcpRedactSensitiveData = true; target.applicationLanguage = "zh-Hans"
partial.apply(to: target)
expect(target.fontSize == 14 && target.mcpRedactSensitiveData && target.applicationLanguage == "zh-Hans", "partial preference payload preserves omitted fields")
target.port = 9091; target.warnBeforeQuit = true; target.showMenuBarIcon = true
target.defaultCopyFormat = .python; target.contentLayout = "horizontal"; target.fontSize = 20
target.showInvisibles = true; target.showMinimap = true
target.resetAppearanceDefaults()
expect(target.fontSize == 12 && target.useMonospacedFont && !target.scrollBeyondLastLine
    && !target.showInvisibles && !target.showMinimap && target.appIconStyle == "earth" && target.appearance == "system", "appearance-only reset")
expect(target.port == 9091 && target.warnBeforeQuit && target.showMenuBarIcon && target.defaultCopyFormat == .python
    && target.applicationLanguage == "zh-Hans" && target.contentLayout == "horizontal", "appearance reset preserves unrelated settings")
print("PASS: \(passed) preference persistence, backup, bounds, notifications, appearance reset and language checks")
'''


def preference_payload(source):
    start = source.index("    struct Preferences: Codable, Equatable {")
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return "import Foundation\nstruct RuleBackup {\n" + source[start:cursor] + "\n}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    with tempfile.TemporaryDirectory(prefix="pm-preferences-models-") as folder:
        directory = Path(folder)
        settings = (ROOT / "Sources/ProxyMirrorCore/Model/AppSettings.swift").read_text().replace("import Combine\n", "")
        (directory / "AppSettings.swift").write_text(settings)
        (directory / "Preferences.swift").write_text(preference_payload((ROOT / "Sources/ProxyMirrorCore/Export/RuleBackup.swift").read_text()))
        (directory / "Stubs.swift").write_text(STUBS)
        (directory / "main.swift").write_text(MAIN)
        executable = directory / "preference-checks"
        subprocess.run([compiler, "-swift-version", "5", "-module-cache-path", str(directory / "modules"),
                        str(directory / "Stubs.swift"), str(directory / "AppSettings.swift"), str(directory / "Preferences.swift"),
                        str(directory / "main.swift"),
                        "-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
