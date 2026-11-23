"""Compile production retention, sampling, filtering, and proxy-restoration logic with portable boundaries."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(path, marker, last=False):
    source = (ROOT / path).read_text()
    start = source.rindex(marker) if last else source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


STUBS = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<T> { var wrappedValue: T }
func autoreleasepool<T>(_ body: () -> T) -> T { body() }
@MainActor final class AppSettings {
    static let shared = AppSettings()
    var automaticTrafficCleanup = true
    var cleanupMemoryLimitMB = 3072
    var cleanupIntervalMinutes = 5
}
enum MemoryPressureController { static func residentMemory() -> UInt64? { nil } }
enum DiagnosticLog { static func record(_ text: String) {} }
enum TxState { case pending, awaiting, completed, failed }
final class Transaction {
    let id = UUID()
    var startedAt = Date()
    var seq = 0
    var state = TxState.pending
    var host = ""
    var isIOSSimulator = false
}
@MainActor final class AppState { static let shared = AppState(); let store = TrafficStore() }
'''

MAIN = r'''
@main struct Checks {
    @MainActor static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        var enabled = true, tick: TimeInterval = 0, resident: UInt64 = 2 * 1024 * 1024
        var samples = 0, removed = 0
        let policy = TrafficCleanupController(configuration: {
            .init(enabled: enabled, memoryLimitMB: 3, intervalMinutes: 5)
        }, now: { tick }, residentMemory: { samples += 1; return resident }, completedCount: { 1000 },
           removeCompleted: { limit in removed += 1; resident = 0; return min(limit, 1) })
        check(policy.runIfNeeded() == 0 && samples == 1, "Under threshold preserves requests")
        resident = 4 * 1024 * 1024; tick = 299
        check(policy.runIfNeeded() == 0 && samples == 1, "Checks respect configured interval")
        tick = 300
        check(policy.runIfNeeded() == 1 && removed == 1, "Over threshold removes and resamples")
        enabled = false; resident = 4 * 1024 * 1024; tick = 900
        check(policy.runIfNeeded(forceTime: true) == 0 && removed == 1, "Disable beats forceTime")
        var remaining = 10000
        let sticky = TrafficCleanupController(configuration: {
            .init(enabled: true, memoryLimitMB: 3, intervalMinutes: 5)
        }, residentMemory: { 4 * 1024 * 1024 }, completedCount: { remaining }, removeCompleted: { limit in
            let count = min(limit, remaining); remaining -= count; return count
        })
        check(sticky.runIfNeeded() == 1024 && remaining == 8976, "Sticky RSS cannot drain every request")
        let quarter = TrafficCleanupController(configuration: {
            .init(enabled: true, memoryLimitMB: 3, intervalMinutes: 5)
        }, residentMemory: { 4 * 1024 * 1024 }, completedCount: { 1000 }, removeCompleted: { $0 })
        check(quarter.runIfNeeded() == 250, "A normal pass removes at most one quarter of completed rows")
        let store = TrafficStore()
        let pending = Transaction(), first = Transaction(), second = Transaction(), awaiting = Transaction()
        pending.startedAt = Date(timeIntervalSince1970: 1)
        first.startedAt = Date(timeIntervalSince1970: 2); first.state = .completed
        second.startedAt = Date(timeIntervalSince1970: 3); second.state = .failed
        awaiting.startedAt = Date(timeIntervalSince1970: 4); awaiting.state = .awaiting
        store.live = [pending, second, first, awaiting]
        check(store.removeOldestCompleted(count: 1) == 1 && !store.live.contains { $0.id == first.id }, "Oldest completed record is selected by capture time")
        check(store.removeOldestCompleted(count: 1000) == 1 && store.live.count == 2, "Pending and awaiting requests survive cleanup")
        let apple = Transaction(); apple.host = "configuration.apple.com"
        check(!TrafficStore.isSimulatorAppleBackgroundTraffic(apple), "Native Apple traffic is preserved")
        apple.isIOSSimulator = true
        check(TrafficStore.isSimulatorAppleBackgroundTraffic(apple), "Simulator background endpoint is filtered")
        apple.host = "developer.apple.com"
        check(!TrafficStore.isSimulatorAppleBackgroundTraffic(apple), "Deliberate Apple website traffic is preserved")
        check(ProcessAttribution.isSimulatorExecutablePath("/Users/x/Library/Developer/CoreSimulator/Devices/uuid/data/App.app/App"), "Executable path detects simulator sources")
        check(!ProcessAttribution.isSimulatorExecutablePath("/Applications/Safari.app/Contents/MacOS/Safari"), "Native executable is not a simulator")
        let monitor = ResourceUsageMonitor()
        monitor.sample(up: 10, down: 100, now: 1)
        monitor.sample(up: 60, down: 1100, now: 2)
        check(monitor.upload == 50 && monitor.download == 1000, "Rates derive from monotonic deltas")
        let current: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9090,
                                      "HTTPSEnable": 1, "HTTPSProxy": "third-party", "HTTPSPort": 8080]
        let original: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "old-proxy", "HTTPPort": 8888]
        let restored = SystemProxySettings.restoredConfiguration(current, original: original, ownedPort: 9090)
        check(restored["HTTPProxy"] as? String == "old-proxy", "Default restores previous proxy")
        let disabled = SystemProxySettings.restoredConfiguration(current, original: original, ownedPort: 9090, restorePrevious: false)
        check(disabled["HTTPEnable"] as? Int == 0 && disabled["HTTPProxy"] == nil && disabled["HTTPPort"] == nil, "No restore option cannot leave a dead app proxy")
        check(disabled["HTTPSProxy"] as? String == "third-party", "Third-party proxy remains untouched")
        print("system retention models: PASS")
    }
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    controller = (ROOT / "Sources/ProxyMirrorCore/System/TrafficCleanupController.swift").read_text().replace("import Combine\n", "")
    traffic = "@MainActor final class TrafficStore {\nvar live: [Transaction] = []\nvar completedLiveRequestCount: Int { live.filter { $0.state == .completed || $0.state == .failed }.count }\nfunc remove(_ ids: Set<UUID>) { live.removeAll { ids.contains($0.id) } }\n"
    traffic += declaration("Sources/ProxyMirrorCore/Model/TrafficStore.swift", "func removeOldestCompleted(count: Int)", last=True) + "\n"
    traffic += declaration("Sources/ProxyMirrorCore/Model/TrafficStore.swift", "static func isSimulatorAppleBackgroundTraffic") + "\n}"
    process = "enum ProcessAttribution {" + declaration("Sources/ProxyMirrorCore/Proxy/ProcessAttribution.swift", "static func isSimulatorExecutablePath") + "}"
    sampling = "@MainActor " + declaration("Sources/ProxyMirrorCore/UI/Tools/WorkbenchUtilities.swift", "final class ResourceUsageMonitor")
    restore = "enum SystemProxySettings { static let http = [\"HTTPEnable\", \"HTTPProxy\", \"HTTPPort\"]; static let https = [\"HTTPSEnable\", \"HTTPSProxy\", \"HTTPSPort\"]; static let exceptions = \"ExceptionsList\";\n"
    restore += declaration("Sources/ProxyMirrorSystemProxy/SystemProxySettings.swift", "package static func restoredConfiguration").replace("package static", "static") + "\n}"
    with tempfile.TemporaryDirectory(prefix="pm-system-retention-") as name:
        directory = Path(name)
        harness = directory / "Checks.swift"
        harness.write_text("\n".join((STUBS, controller, traffic, process, sampling, restore, MAIN)))
        binary = directory / "checks"
        subprocess.run([compiler, "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(directory / "modules"), str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
