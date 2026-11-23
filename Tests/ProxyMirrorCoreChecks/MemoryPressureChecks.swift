import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkMemoryPressure(_ test: CoreAssertions) throws {
    final class Observations: @unchecked Sendable {
        var cleanups = 0
        var notifications: [(String, String)] = []
    }
    let observed = Observations()
    let notifications = NotificationCenter()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let controller = MemoryPressureController(cleaners: [
        .init(name: "fixture-cache", clear: { observed.cleanups += 1 }),
    ], notifications: notifications, now: { now })
    let token = notifications.addObserver(forName: .pmMemoryPressure, object: nil, queue: nil) { event in
        observed.notifications.append((event.userInfo?["level"] as? String ?? "", event.userInfo?["source"] as? String ?? ""))
    }
    defer { notifications.removeObserver(token); controller.stopMonitoring() }
    let simulated = controller.simulateWarning()
    controller.receiveSystemPressure([.warning, .critical])
    controller.receiveSystemPressure(.normal)
    test.equal(observed.cleanups, 2, "Simulation and real event flags run the same cache cleanup path exactly once")
    test.equal(observed.notifications.map(\.0), ["warning", "critical"], "Critical pressure takes priority in a coalesced dispatch event")
    test.equal(observed.notifications.map(\.1), ["simulation", "system"], "Renderer invalidation preserves the real versus simulated source")
    test.equal(controller.cleanupCount, 2, "Memory pressure reports its completed cleanup count")
    test.equal(controller.simulationCount, 1, "Simulated warnings are counted separately")
    test.equal(controller.systemCount, 1, "Real warning/critical callbacks are counted separately")
    test.equal(simulated.date, now, "Memory pressure records the event timestamp")
    test.equal(controller.lastEvent?.source, .system, "Status reports the latest event source")
    controller.startMonitoring()
    controller.startMonitoring()
    test.expect(controller.isMonitoring, "The real DispatchSource monitor starts idempotently")
    controller.stopMonitoring()
    test.expect(!controller.isMonitoring, "The real pressure source is cancelled on stop")

    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = Transaction()
    transaction.host = "pressure.example.test"
    let wire = Data(base64Encoded: "KLUv/SAYwQAAUHJveHlNaXJyb3IgenN0ZCDkuK3mlocK")!
    transaction.requestHeaders = HTTPHeaders([("Content-Encoding", "zstd")])
    transaction.requestBody = wire
    transaction.requestBodyComplete = true
    transaction.responseBody = Data([0, 255, 13, 10])
    transaction.responseBodyComplete = true
    let session = SessionFile(transactions: [transaction], pinnedDomains: [transaction.host], selected: [transaction.id])
    let sessionURL = directory.appendingPathComponent("preserved.proxymirror")
    try session.write(to: sessionURL)
    let savedBefore = try Data(contentsOf: sessionURL)
    InspectionBody.clearCache()
    test.expect(InspectionBody.data(for: transaction, request: true, limit: 1024) != nil &&
                InspectionBody.cacheStatistics.entries > 0, "The fixture populates the real decoded-body cache")
    let generation = InspectionBody.cacheStatistics.generation
    let actual = MemoryPressureController(notifications: NotificationCenter())
    _ = actual.simulateWarning()
    test.expect(InspectionBody.cacheStatistics.entries == 0 && InspectionBody.cacheStatistics.generation != generation,
                "Memory pressure evicts the decoded cache and invalidates in-flight decode generations")
    test.equal(transaction.requestBody, wire, "A simulated warning preserves original captured request bytes")
    test.equal(transaction.responseBody, Data([0, 255, 13, 10]), "A simulated warning preserves captured response bytes")
    test.equal(try Data(contentsOf: sessionURL), savedBefore, "A simulated warning does not rewrite or remove a saved session")
    test.equal(InspectionBody.data(for: transaction, request: true, limit: 1024), Data("ProxyMirror zstd 中文\n".utf8),
               "Decoded presentation can be reconstructed from the retained wire body")

    let guide = HelpGuideCoordinator.shared
    let previous = guide.topic
    defer { guide.show(previous) }
    test.equal(HelpGuideTopic.allCases.count, 6, "Troubleshooting exposes six explicit destinations")
    for topic in HelpGuideTopic.allCases {
        guide.show(topic)
        test.equal(guide.topic, topic, "Troubleshooting opens its exact guide topic: \(topic.rawValue)")
    }
    try checkAutomaticTrafficCleanup(test)
}
