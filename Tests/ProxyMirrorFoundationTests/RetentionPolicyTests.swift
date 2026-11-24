import Foundation
import XCTest
import ProxyMirrorFoundation

final class RetentionPolicyTests: XCTestCase {
    func testCleanupCadenceThresholdAndDisable() {
        var policy = TrafficCleanupPolicy()
        var resident: UInt64 = 2 * 1024 * 1024
        var samples = 0
        var removals = 0
        func run(_ now: TimeInterval, enabled: Bool = true, force: Bool = false) -> TrafficCleanupPolicy.Result {
            policy.run(configuration: .init(enabled: enabled, memoryLimitMB: 3, intervalMinutes: 5),
                       now: now, forceTime: force, residentMemory: { samples += 1; return resident },
                       completedCount: { 1000 }, removeCompleted: { limit in
                XCTAssertLessThanOrEqual(limit, 64)
                removals += 1
                resident = 0
                return 1
            })
        }
        XCTAssertEqual(run(0).removed, 0)
        resident = 4 * 1024 * 1024
        XCTAssertFalse(run(299).checked)
        XCTAssertEqual(samples, 1)
        XCTAssertEqual(run(300).removed, 1)
        XCTAssertEqual(removals, 1)
        resident = 4 * 1024 * 1024
        XCTAssertFalse(run(301, enabled: false, force: true).checked)
        XCTAssertEqual(removals, 1)
        XCTAssertTrue(run(302).checked, "Re-enabling permits a fresh check")
    }

    func testStickyRSSCannotDrainAllRecords() {
        var policy = TrafficCleanupPolicy()
        var remaining = 10000
        let result = policy.run(configuration: .init(enabled: true, memoryLimitMB: 3, intervalMinutes: 5),
                                now: 0, residentMemory: { 4 * 1024 * 1024 },
                                completedCount: { remaining }, removeCompleted: { limit in
            let count = min(limit, remaining)
            remaining -= count
            return count
        })
        XCTAssertEqual(result.removed, 1024)
        XCTAssertEqual(remaining, 8976)
        var quarter = TrafficCleanupPolicy()
        let limited = quarter.run(configuration: .init(enabled: true, memoryLimitMB: 3, intervalMinutes: 5),
                                  now: 0, residentMemory: { 4 * 1024 * 1024 }, completedCount: { 1000 },
                                  removeCompleted: { $0 })
        XCTAssertEqual(limited.removed, 250)
    }

    func testMissingMemoryAndExhaustedCandidates() {
        var policy = TrafficCleanupPolicy()
        let missing = policy.run(configuration: .init(enabled: true, memoryLimitMB: 1, intervalMinutes: 1),
                                 now: 0, residentMemory: { nil }, completedCount: { 1 },
                                 removeCompleted: { _ in XCTFail("No memory reading must not delete"); return 0 })
        XCTAssertTrue(missing.checked)
        XCTAssertNil(missing.residentBytes)
        let exhausted = policy.run(configuration: .init(enabled: true, memoryLimitMB: 1, intervalMinutes: 1),
                                   now: 60, residentMemory: { 2 * 1024 * 1024 }, completedCount: { 0 },
                                   removeCompleted: { _ in 0 })
        XCTAssertEqual(exhausted.removed, 0)
    }

    func testOldestCompletedSelectionPreservesInProgress() {
        let pending = UUID(), first = UUID(), second = UUID(), tied = UUID()
        let values = [
            TrafficRetention.Candidate(id: pending, startedAt: Date(timeIntervalSince1970: 1), sequence: 1, completed: false),
            .init(id: second, startedAt: Date(timeIntervalSince1970: 3), sequence: 3, completed: true),
            .init(id: tied, startedAt: Date(timeIntervalSince1970: 2), sequence: 4, completed: true),
            .init(id: first, startedAt: Date(timeIntervalSince1970: 2), sequence: 2, completed: true),
        ]
        XCTAssertEqual(TrafficRetention.oldestCompleted(values, count: 1), [first])
        XCTAssertEqual(TrafficRetention.oldestCompleted(values, count: 2), [first, tied])
        XCTAssertEqual(TrafficRetention.oldestCompleted(values, count: 100), [first, tied, second])
        XCTAssertTrue(TrafficRetention.oldestCompleted(values, count: 0).isEmpty)
    }

    func testSimulatorPolicyUsesStructuredAttribution() {
        XCTAssertFalse(SimulatorTrafficPolicy.isBackgroundTraffic(host: "configuration.apple.com", isSimulator: false))
        XCTAssertTrue(SimulatorTrafficPolicy.isBackgroundTraffic(host: "configuration.apple.com", isSimulator: true))
        XCTAssertTrue(SimulatorTrafficPolicy.isBackgroundTraffic(host: "a.push.apple.com.", isSimulator: true))
        XCTAssertFalse(SimulatorTrafficPolicy.isBackgroundTraffic(host: "developer.apple.com", isSimulator: true))
        XCTAssertTrue(SimulatorTrafficPolicy.isExecutablePath("/Users/x/Library/Developer/CoreSimulator/Devices/id/App.app/App"))
        XCTAssertFalse(SimulatorTrafficPolicy.isExecutablePath("/Applications/Safari.app/Contents/MacOS/Safari"))
    }

    func testRatesUseMonotonicDeltasAndClampResets() {
        var rates = TransferRateMeter()
        rates.sample(up: 10, down: 100, now: 1)
        rates.sample(up: 60, down: 1100, now: 2)
        XCTAssertEqual(rates.upload, 50)
        XCTAssertEqual(rates.download, 1000)
        rates.sample(up: 60, down: 1100, now: 3)
        XCTAssertEqual(rates.download, 0)
        rates.sample(up: 0, down: 0, now: 4)
        XCTAssertEqual(rates.upload, 0)
        XCTAssertEqual(rates.download, 0)
        rates.sample(up: Int64.max, down: Int64.max, now: 4.001)
        XCTAssertEqual(rates.upload, Int64.max)
    }

    func testRestorationTouchesOnlyOwnedProxyFields() {
        let current: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9090,
                                      "HTTPSEnable": 1, "HTTPSProxy": "other-proxy", "HTTPSPort": 8080,
                                      "ExceptionsList": ["*.fixture.test"]]
        let original: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "old-proxy", "HTTPPort": 8888,
                                       "ExceptionsList": ["old.test"]]
        let restored = SystemProxyRestorePolicy.restore(current, original: original, ownedPort: 9090,
                                                        ownedBypassLists: [["*.fixture.test"]])
        XCTAssertEqual(restored["HTTPProxy"] as? String, "old-proxy")
        XCTAssertEqual(restored["HTTPSProxy"] as? String, "other-proxy")
        XCTAssertEqual(restored["ExceptionsList"] as? [String], ["old.test"])
        let disabled = SystemProxyRestorePolicy.restore(current, original: original, ownedPort: 9090, restorePrevious: false)
        XCTAssertEqual(disabled["HTTPEnable"] as? Int, 0)
        XCTAssertNil(disabled["HTTPProxy"])
        XCTAssertNil(disabled["HTTPPort"])
        XCTAssertEqual(disabled["HTTPSProxy"] as? String, "other-proxy")
        XCTAssertEqual(disabled["ExceptionsList"] as? [String], ["*.fixture.test"])
    }
}
