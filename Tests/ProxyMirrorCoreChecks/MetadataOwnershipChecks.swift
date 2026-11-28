import Combine
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
@testable import ProxyMirrorCore

/// Actual production handlers run off the UI thread. Subscribe only when their
/// Transaction is published, then check every subsequent Combine emission.
@MainActor
func checkMetadataOwnership(_ test: CoreAssertions) throws {
    final class Sink: TrafficSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storedRecords: [Transaction] = []
        private var subscriptions: [AnyCancellable] = []
        private var storedViolations: [String] = []
        private var storedEmissions = 0
        var records: [Transaction] { lock.withLock { storedRecords } }
        var violations: [String] { lock.withLock { storedViolations } }
        var emissions: Int { lock.withLock { storedEmissions } }
        func transactionCreated(_ tx: Transaction) {
            let subscription = tx.objectWillChange.sink { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    if !Thread.isMainThread { self.storedViolations.append("metadata") }
                    self.storedEmissions += 1
                }
            }
            lock.withLock {
                if !Thread.isMainThread { storedViolations.append("create") }
                storedRecords.append(tx)
                subscriptions.append(subscription)
            }
        }
        func transactionUpdated(_ tx: Transaction) {
            lock.withLock { if !Thread.isMainThread { storedViolations.append("update") } }
        }
    }
    let engine = ProxyEngine()
    defer { try? engine.group.syncShutdownGracefully() }
    let sink = Sink()
    engine.sink = sink
    engine.recordingEnabled = true
    engine.mitmEnabled = true
    let finished = LockedBox(false)
    let failure = LockedBox<String?>(nil)
    DispatchQueue.global().async {
        defer { finished.set(true) }
        do {
            let conn = ConnState(engine: engine)
            conn.transparentFlow = TransparentProxyFlow(host: "192.0.2.1", port: 443, address: "192.0.2.1", application: nil)
            let rules = RulesSnapshot(blockList: [ProxyRule(pattern: "https://blocked.metadata.test/*")])
            let handler = ProxyConnectionHandler(conn: conn, tunnelRules: { rules })
            let channel = EmbeddedChannel(handler: handler)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 54331)).wait()
            handler.beginTransparentFlow() // publishes CONNECT before SNI is known
            conn.sniffedServerName = "blocked.metadata.test"
            handler.clientHelloResolved(mitmHost: nil) // published:true rejection
            _ = try? channel.finish()

            let h2 = EmbeddedChannel()
            let pool = HTTP2UpstreamPool(downstream: h2, listenerPort: 0)
            try h2.pipeline.addHandler(HTTP2ProxyStream(engine: engine, pool: pool,
                authorityHost: "metadata.test", authorityPort: 443, client: nil, clientApplication: nil,
                requestRules: { RulesSnapshot(blockList: [ProxyRule(pattern: "*")]) })).wait()
            try h2.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 54332)).wait()
            _ = try h2.writeInbound(HTTPServerRequestPart.head(NIOHTTP1.HTTPRequestHead(version: .init(major: 2, minor: 0),
                method: .GET, uri: "/local", headers: NIOHTTP1.HTTPHeaders([("host", "metadata.test")]))))
            _ = try h2.writeInbound(HTTPServerRequestPart.end(nil))
            _ = try? h2.finish()
        } catch { failure.set(String(describing: error)) }
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && (!finished.value || sink.records.count < 2 || sink.records.contains(where: { $0.state == .awaiting || !$0.requestBodyComplete })) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    test.equal(failure.value, nil, "Off-main metadata fixtures execute successfully")
    test.equal(sink.records.count, 2, "SNI rejection and HTTP/2 local response each publish exactly once")
    test.expect(sink.records.allSatisfy { $0.statusCode == 403 }, "Both real handlers commit the terminal local status")
    test.expect(sink.emissions > 0, "Combine observed metadata changes after publication")
    test.equal(sink.violations, [], "Published metadata and sink notifications stay on the main thread")
}
