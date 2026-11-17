import Foundation
@testable import ProxyMirrorCore

func runBackgroundPerformanceChecks() {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("proxymirror-background-\(UUID())")
    do {
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    } catch {
        check(false, "background: \(error.localizedDescription)")
        return
    }
    defer { try? manager.removeItem(at: directory) }

    do {
        let record = Transaction()
        record.responseBody = Data([0, 127, 128, 255])
        let url = directory.appendingPathComponent("session.proxymirror")
        let snapshot = SessionFile(transactions: [record], pinnedDomains: ["example.com"], selected: [record.id])
        try snapshot.write(to: url)
        let imported = try SessionFile.decode(Data(contentsOf: url))
        check(imported.records.first?.responseBody == record.responseBody && imported.selected == [record.id]
              && imported.pinnedDomains == ["example.com"], "session files: binary snapshot round trip")
        do {
            _ = try SessionFile.decode(Data(#"{"version":2}"#.utf8))
            check(false, "session files: reject unsupported version before decoding records")
        } catch SessionFile.SessionError.unsupportedVersion {
            check(true, "session files: reject unsupported version before decoding records")
        }
        do {
            let duplicate = SessionFile(transactions: [record, record], pinnedDomains: [], selected: [])
            _ = try SessionFile.decode(JSONEncoder().encode(duplicate))
            check(false, "session files: reject duplicate records")
        } catch SessionFile.SessionError.duplicateIDs {
            check(true, "session files: reject duplicate records")
        }

        let ca = CertificateAuthority(storageDirectory: directory.appendingPathComponent("CA"))
        let firstFingerprint = ca.caFingerprintSHA256
        let first = ca.leafContext(forHost: "localhost")
        let warm = ca.leafContext(forHost: "localhost")
        let http2 = ca.leafContext(forHost: "localhost", enableHTTP2: true)
        check(first != nil && first === warm && http2 != nil && first !== http2,
              "certificate cache: reuse matching host and ALPN context")
        try ca.resetCA()
        let replacement = ca.leafContext(forHost: "localhost")
        check(firstFingerprint != nil && ca.caFingerprintSHA256 != firstFingerprint
              && replacement != nil && replacement !== first, "certificate cache: CA reset invalidates leaf context")
    } catch {
        check(false, "background: \(error.localizedDescription)")
    }

    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let calls = LockedBox(0)
    let owner = ProcessAppInfo(pid: -1, name: "test owner", bundleID: nil, bundleURL: nil)
    let attribution = ProcessAttribution {
        calls.set(calls.value + 1)
        started.signal()
        _ = finish.wait(timeout: .now() + .seconds(2))
        return [12345: owner]
    }
    var owners: [ProcessAppInfo?] = []
    attribution.attribute(peerPort: 12345) { owners.append($0) }
    let inFlight = started.wait(timeout: .now() + .seconds(2)) == .success
    attribution.attribute(peerPort: 12345) { owners.append($0) }
    finish.signal()
    let deadline = Date().addingTimeInterval(2)
    while owners.count < 2 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(inFlight && calls.value == 1 && owners == [owner, owner],
          "process attribution: duplicate in-flight port shares one snapshot")

    let config = InterceptionConfig.shared
    let old = config.rewrite.value
    defer { config.rewrite.set(old) }
    config.rewrite.set([RewriteRuleSet(rules: [RewriteRule(actions: [
        .responseHeader(op: .set, name: "X-Native", value: "first"),
        .responseHeader(op: .add, name: "x-native", value: "second"),
        .responseHeader(op: .remove, name: "Connection", value: ""),
        .setStatus(202),
    ])])])
    let target = ScriptingTarget(method: "GET", scheme: "http", host: "example.com", path: "/", query: "", url: "http://example.com/")
    guard let plan = ScriptingService.plan(for: target, phase: .response) else {
        check(false, "native rewrite: compile response plan")
        return
    }
    let result = LockedBox<ScriptingResult?>(nil)
    let delivered = DispatchSemaphore(value: 0)
    let head = HTTPResponseHead(version: "HTTP/1.1", status: 200, reason: "OK",
                               headers: HTTPHeaders([("Connection", "close"), ("x-native", "old")]))
    ScriptingService.run(plan, head: .response(head), body: nil) {
        result.set($0)
        delivered.signal()
    }
    guard delivered.wait(timeout: .now() + .seconds(2)) == .success,
          let edited = result.value, case .response(let response) = edited.head else {
        check(false, "native rewrite: deliver edited response")
        return
    }
    check(response.status == 202 && response.headers.values(of: "X-Native") == ["first", "second"]
          && response.headers.value(of: "Connection") == "close" && edited.logs.count == 4,
          "native rewrite: preserve action order and framing validation")
}
