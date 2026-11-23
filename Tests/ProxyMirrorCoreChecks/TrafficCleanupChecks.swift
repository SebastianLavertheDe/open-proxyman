import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkAutomaticTrafficCleanup(_ test: CoreAssertions) throws {
    var enabled = true
    var timestamp: TimeInterval = 0
    var resident: UInt64 = 2 * 1024 * 1024
    var samples = 0
    var removals = 0
    let controller = TrafficCleanupController(configuration: {
        .init(enabled: enabled, memoryLimitMB: 3, intervalMinutes: 5)
    }, now: { timestamp }, residentMemory: { samples += 1; return resident }, completedCount: { 1000 }, removeCompleted: { _ in
        removals += 1
        resident = 0
        return 1
    })
    test.equal(controller.runIfNeeded(), 0, "Below-threshold resident memory does not delete requests")
    resident = 4 * 1024 * 1024
    timestamp = 299
    test.equal(controller.runIfNeeded(), 0, "Automatic cleanup respects its five-minute interval")
    test.equal(samples, 1, "Interval suppression avoids extra resident-memory sampling")
    timestamp = 300
    test.equal(controller.runIfNeeded(), 1, "The threshold invokes actual request removal and resamples memory")
    enabled = false
    resident = 4 * 1024 * 1024
    timestamp = 600
    test.equal(controller.runIfNeeded(forceTime: true), 0, "A forced check cannot bypass the disabled policy")
    test.equal(removals, 1, "Disabling automatic cleanup preserves captured requests")
    var remaining = 10000
    let stickyMemory = TrafficCleanupController(configuration: {
        .init(enabled: true, memoryLimitMB: 3, intervalMinutes: 5)
    }, residentMemory: { 4 * 1024 * 1024 }, completedCount: { remaining }, removeCompleted: { limit in
        let removed = min(limit, remaining)
        remaining -= removed
        return removed
    })
    test.equal(stickyMemory.runIfNeeded(), TrafficCleanupController.maximumRemovalsPerPass,
               "Resident pages that stay high cannot cause an unbounded deletion loop")
    test.equal(remaining, 8976, "One high-memory pass retains the majority of completed requests")

    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TrafficStore(sourceFolderFile: directory.appendingPathComponent("folders.json"),
                             savedFile: directory.appendingPathComponent("saved.json"))
    let split = TrafficStore(sharing: store)
    let pending = Transaction(startedAt: Date(timeIntervalSince1970: 1))
    let first = Transaction(startedAt: Date(timeIntervalSince1970: 2)); first.state = .completed
    let second = Transaction(startedAt: Date(timeIntervalSince1970: 3)); second.state = .failed
    let awaiting = Transaction(startedAt: Date(timeIntervalSince1970: 4)); awaiting.state = .awaiting
    store.add(pending); store.add(second); store.add(first); store.add(awaiting)
    try store.copyRequests([first], toSavedFolder: nil)
    let deadline = Date().addingTimeInterval(2)
    while store.saved.isEmpty && store.savedError == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let archived = Transaction()
    let archiveView = TrafficStore(sharing: store)
    archiveView.loadArchive([archived], name: "cleanup fixture")
    test.equal(store.removeOldestCompleted(count: 1), 1, "Cleanup selects the oldest completed request by capture time")
    test.expect(!store.transactions.contains { $0.id == first.id } && store.transactions.contains { $0.id == second.id },
                "An earlier still-running request is preserved while the oldest completed request is removed")
    test.equal(store.removeOldestCompleted(count: 100), 1, "Failed requests are also eligible for old-request cleanup")
    test.equal(Set(split.transactions.map(\.id)), Set([pending.id, awaiting.id]), "All live views see the same cleaned data")
    test.equal(store.saved.count, 1, "Automatic retention never removes saved request snapshots")
    test.equal(archiveView.archive.map(\.id), [archived.id], "Automatic retention never removes imported-session records")
    test.equal(store.session(onlySelection: false, pinned: []).records.count, 2, "Removed live records cannot be exported again")

    store.clear(); store.maxTransactions = 1
    let old = Transaction(); old.responseBytes = 100
    store.add(old)
    let baseline = store.cumulativeTransferredBytes.response
    let monitor = ResourceUsageMonitor()
    monitor.sample(up: 0, down: baseline, now: 1)
    let incoming = Transaction(); incoming.responseBytes = 1000
    store.add(incoming)
    monitor.sample(up: 0, down: store.cumulativeTransferredBytes.response, now: 2)
    test.equal(monitor.download, 1000, "Evicting old rows cannot subtract bytes from the download rate")
    store.remove([incoming.id])
    monitor.sample(up: 0, down: store.cumulativeTransferredBytes.response, now: 3)
    test.equal(monitor.download, 0, "Deleting retained requests neither resets nor fabricates network traffic")
    store.clear()
    test.equal(store.cumulativeTransferredBytes.response, baseline + 1000, "Clearing retained traffic preserves monotonic rate counters")

    let apple = Transaction(); apple.host = "configuration.apple.com"
    test.expect(!TrafficStore.isSimulatorAppleBackgroundTraffic(apple), "Native Apple traffic remains visible")
    apple.isIOSSimulator = true
    test.expect(TrafficStore.isSimulatorAppleBackgroundTraffic(apple), "Known simulator Apple background traffic is hidden")
    apple.host = "developer.apple.com"
    test.expect(!TrafficStore.isSimulatorAppleBackgroundTraffic(apple), "Simulator requests deliberately targeting Apple websites remain visible")
    let restored = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(SessionRecord(apple))).transaction()
    test.expect(restored.isIOSSimulator, "Simulator attribution survives saved-request and session round trips")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionRecord(apple))) as! [String: Any]
    legacy.removeValue(forKey: "isIOSSimulator")
    let legacyRecord = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
    test.expect(!legacyRecord.transaction().isIOSSimulator, "Older sessions without simulator attribution remain visible")
    apple.setClientApplication(ProcessAppInfo(pid: 1, name: "Fixture", bundleID: "fixture.app", bundleURL: nil, isIOSSimulator: true))
    test.expect(apple.isIOSSimulator && apple.clientName == "Fixture", "Live process attribution carries simulator identity without changing app names")
    test.expect(ProcessAttribution.isSimulatorExecutablePath("/Users/test/Library/Developer/CoreSimulator/Devices/id/data/Containers/Bundle/Application/id/App.app/App"),
                "Simulator detection uses the actual executable path")
    test.expect(!ProcessAttribution.isSimulatorExecutablePath("/Applications/Safari.app/Contents/MacOS/Safari"),
                "A native application path is never classified as an iOS simulator")
}
