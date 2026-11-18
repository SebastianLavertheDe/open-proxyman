import Foundation
import NIOCore
import NIOEmbedded
@testable import ProxyMirrorCore

func checkCustomCertificateBackup(_ test: CoreAssertions) throws {
    let old = CustomCertificateRule(hostPattern: "api.example.test", certificatePath: "/tmp/pm-old.pem", privateKeyPath: "/tmp/pm-old.key")
    let keep = CustomCertificateRule(hostPattern: "keep.example.test", certificatePath: "/tmp/pm-keep.pem", privateKeyPath: "/tmp/pm-keep.key")
    var updated = old
    updated.certificatePath = "/tmp/pm-updated.pem"
    let added = CustomCertificateRule(hostPattern: "*.other.test", certificatePath: "/tmp/pm-added.pem", privateKeyPath: "/tmp/pm-added.key")
    let exported = RuleBackup(customCertificates: [updated, added]).subset(nil)
    let (imported, unknown) = try RuleBackup.read(exported.exportData())
    test.expect(unknown.isEmpty, "Own certificate backup has no unmapped fields")
    test.equal(imported.customCertificates, [updated, added], "Certificate paths and rule IDs round-trip through backup files")
    let empty = imported.resolve(with: RuleBackup(), merge: true)
    test.equal(empty.customCertificates, [updated, added], "Import restores certificate rules into an empty configuration")
    let current = RuleBackup(customCertificates: [old, keep])
    test.equal(imported.resolve(with: current, merge: true).customCertificates, [updated, keep, added],
               "Certificate merge updates by ID and retains existing rules")
    test.equal(imported.resolve(with: current, merge: false).customCertificates, [updated, added],
               "Certificate replacement restores the incoming list")
    test.equal(RuleBackup(customCertificates: []).resolve(with: current, merge: false).customCertificates, [],
               "An explicitly empty certificate section clears its rules")
    test.equal(RuleBackup(dns: []).resolve(with: current, merge: false).customCertificates, [old, keep],
               "Importing an unrelated section preserves certificate rules")
    let section = imported.subset(.customCertificates)
    test.equal(section.customCertificates, imported.customCertificates, "Certificate-only export retains its section")
    let change = imported.changes(from: current, mode: .replace).first { $0.section == .customCertificates }
    test.equal(change?.added, 1, "Certificate preview reports added rules")
    test.equal(change?.updated, 1, "Certificate preview reports updated rules")
    test.equal(change?.removed, 1, "Certificate preview reports removed rules")
    let duplicate = try RuleBackup(customCertificates: [old, old]).exportData()
    test.rejects(try RuleBackup.read(duplicate), with: RuleBackup.BackupError.self,
                 "Certificate import rejects duplicate IDs")
    var invalid = old
    invalid.privateKeyPath = ""
    let invalidData = try RuleBackup(customCertificates: [invalid]).exportData()
    test.rejects(try RuleBackup.read(invalidData), with: RuleBackup.BackupError.self,
                 "Certificate import rejects an empty private-key path")
}

@MainActor
func checkTunnelRuleEnforcement(_ test: CoreAssertions) throws {
    let block = ProxyRule(pattern: "https://blocked.example.test/*")
    let allow = ProxyRule(pattern: "https://allowed.example.test/*")
    test.expect(RulesSnapshot(blockList: [block]).tunnelRejection(host: "blocked.example.test", port: 443) != nil,
                "Host URL patterns block HTTPS tunnels without requiring their unknown paths")
    test.expect(RulesSnapshot(blockList: [block]).tunnelRejection(host: "other.example.test", port: 443) == nil,
                "A host Block rule preserves unrelated tunnels")
    test.expect(RulesSnapshot(allowList: [allow]).tunnelRejection(host: "allowed.example.test", port: 443) == nil,
                "Allow-list host patterns admit matching HTTPS tunnels")
    test.expect(RulesSnapshot(allowList: [allow]).tunnelRejection(host: "blocked.example.test", port: 443) != nil,
                "Allow-list rules reject nonmatching HTTPS tunnels")
    test.expect(RulesSnapshot(blockList: [block]).tunnelRejection(host: "192.0.2.1", port: 443,
                     serverName: "blocked.example.test") != nil,
                "Transparent TLS fallback also evaluates the sniffed server name")
    test.expect(RulesSnapshot(blockList: [ProxyRule(pattern: "https://[::1]:8443/*")])
        .tunnelRejection(host: "::1", port: 8443) != nil, "Tunnel matching retains IPv6 and nondefault ports")

    // Exercise the real CONNECT handler; a denied tunnel must never acknowledge 200 or dial an origin.
    let engine = ProxyEngine.shared
    guard !engine.isRunning else {
        test.expect(false, "Tunnel checks require an idle test proxy")
        return
    }
    let previousMITM = engine.mitmEnabled
    let previousSink = engine.sink
    let previousRecording = engine.recordingEnabled
    final class Sink: TrafficSink {
        var records: [Transaction] = []
        func transactionCreated(_ tx: Transaction) { records.append(tx) }
        func transactionUpdated(_ tx: Transaction) {}
    }
    let sink = Sink()
    defer {
        engine.mitmEnabled = previousMITM
        engine.recordingEnabled = previousRecording
        engine.sink = previousSink
    }
    engine.mitmEnabled = false
    engine.recordingEnabled = true
    engine.sink = sink
    for blocks in [true, false] {
        let conn = ConnState(engine: engine)
        let snapshot = RulesSnapshot(blockList: blocks ? [block] : [], allowList: blocks ? [] : [allow])
        let channel = EmbeddedChannel(handler: ProxyConnectionHandler(conn: conn, tunnelRules: { snapshot }))
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 54321)).wait()
        _ = try channel.writeInbound(ByteBuffer(string:
            "CONNECT blocked.example.test:443 HTTP/1.1\r\nHost: blocked.example.test:443\r\n\r\n"))
        var response = ""
        while let bytes = try channel.readOutbound(as: ByteBuffer.self) {
            response += String(decoding: bytes.readableBytesView, as: UTF8.self)
        }
        test.expect(response.hasPrefix("HTTP/1.1 403 Forbidden"), "Real CONNECT handler rejects a passthrough tunnel with HTTP 403")
        test.expect(!response.contains("200 Connection Established"), "Denied CONNECT is never acknowledged as established")
        test.expect(sink.records.last?.matchedByBlock == true && sink.records.last?.statusCode == 403,
                    "Rejected tunnels appear in traffic with rule matching and a 403 status")
        _ = try? channel.finish()
    }
}
