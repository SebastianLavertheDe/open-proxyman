import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkCharlesImport(_ test: CoreAssertions) throws {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Charles", isDirectory: true)
    let xml = try CharlesImport.readSession(fixtures.appendingPathComponent("session.xml"))
    test.equal(xml.records.count, 1, "Charles XML imports the HTTP exchange")
    test.equal(xml.skipped, 1, "Charles XML reports unsupported protocol")
    let exchange = try require(xml.records.first)
    test.equal(exchange.fullURL, "https://example.test:8443/v1/example?page=2&id=3", "Charles XML preserves URL and actual port")
    test.equal(exchange.requestHeaders.values(of: "X-Foo"), ["one", "two"], "Charles XML preserves duplicate headers")
    test.equal(exchange.requestBody, Data([0, 255, 128]), "Charles XML decodes binary request")
    test.equal(String(decoding: exchange.responseBody, as: UTF8.self), " test <a>& test  ", "Charles XML preserves CDATA")
    test.equal(exchange.statusCode, 201, "Charles XML preserves status code")
    test.equal(exchange.statusReason, "Created", "Charles XML preserves status text")
    test.expect(abs(exchange.duration - 0.1) < 0.0001, "Charles XML imports millisecond timing")
    test.expect(abs((exchange.tHeaderAt?.timeIntervalSince(exchange.startedAt) ?? -1) - 0.03) < 0.0001, "Charles XML imports response timing")

    let store = TrafficStore()
    store.loadArchive(xml.records, name: "Charles")
    test.equal(store.visible.first?.id, exchange.id, "Charles imported records are available in the archive")

    let json = try CharlesImport.readSession(fixtures.appendingPathComponent("session.chlsj"))
    test.equal(json.records.count, 2, "Charles JSON imports completed and failed HTTP records")
    test.equal(json.records.first?.responseBody, Data([0, 255, 128]), "Charles JSON decodes binary response")
    test.expect(abs((json.records.first?.duration ?? -1) - 0.08) < 0.0001, "Charles JSON imports timing")
    test.equal(json.records.last?.errorText, "Fixture request failed", "Charles JSON imports failure text")
    test.equal(json.records.last?.state, .failed, "Charles JSON imports failed state")

    let malicious = """
        <!DOCTYPE charles-session [<!ENTITY injected "ignored">]>
        <charles-session><transaction>&injected;</transaction></charles-session>
        """
    test.rejects(try CharlesImport.readSession(Data(malicious.utf8)), with: CharlesImport.ImportError.self,
                 "Charles XML rejects inline entity declarations")

    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = directory.appendingPathComponent("fixture.txt")
    try Data("mapped body".utf8).write(to: local)
    let missing = directory.appendingPathComponent("missing.txt")
    let ruleSource = try String(contentsOf: fixtures.appendingPathComponent("settings.xml"), encoding: .utf8)
        .replacingOccurrences(of: "/__FIXTURE_FILE__", with: local.path)
        .replacingOccurrences(of: "/__MISSING_FILE__", with: missing.path)
    let migration = try CharlesImport.readRules(Data(ruleSource.utf8))
    test.equal(migration.counts.rewrite, 3, "Charles imports three header rewrites")
    test.equal(migration.counts.mapLocal, 2, "Charles imports two local mappings")
    test.equal(migration.counts.blockList, 1, "Charles imports a block rule")
    test.equal(migration.skipped.count, 2, "Charles reports unrepresentable conditional rewrite and DNS tool")
    test.equal(migration.notes.count, 1, "Charles reports disabled local mapping to missing file")
    let backup = try RuleBackup.read(migration.backup.exportData()).0
    test.equal(backup.rewrite, migration.backup.rewrite, "Charles rewrite persists through the rules backup")
    test.equal(backup.blockList, migration.backup.blockList, "Charles block URL match survives the rules backup")
    test.equal(backup.mapLocal?.last?.enabled, false, "Charles missing local file imports disabled")
    let ruleSnapshot = RulesSnapshot(mapLocal: backup.mapLocal ?? [], blockList: backup.blockList ?? [])
    test.equal(ruleSnapshot.mapLocalResponse(for: "http://example.test/mapped?hello=1")?.data, Data("mapped body".utf8),
               "Engine matches Charles Map Local without inspecting the query")
    test.expect(ruleSnapshot.mapLocalResponse(for: "http://example.test/mapped-elsewhere") == nil,
                "Charles Map Local exact path doesn't broaden")
    test.expect(ruleSnapshot.mapLocalResponse(for: "http://example.test/MAPPED") == nil,
                "Charles Map Local preserves case-sensitive matching")
    test.expect(ruleSnapshot.isBlocked(url: "https://cdn.blocked.test/path"), "Engine matches Charles Block List")
    test.expect(!ruleSnapshot.isBlocked(url: "https://cdn.blocked.test.evil/path"), "Charles wildcard doesn't cross authority")
    test.expect(!ruleSnapshot.isBlocked(url: "http://cdn.blocked.test/path"), "Charles block respects the port")
    test.expect(ruleSnapshot.isBlocked(url: "http://cdn.blocked.test:443/path"), "Charles allows explicitly matching non-default port")

    let config = InterceptionConfig.shared
    let previous = config.rewrite.value
    defer { config.rewrite.set(previous) }
    config.rewrite.set(backup.rewrite ?? [])
    let target = ScriptingTarget(method: "GET", scheme: "http", host: "example.test", path: "/v1/inspect", query: "id=2",
                                 url: "http://example.test:8080/v1/inspect?id=2")
    guard let plan = ScriptingService.plan(for: target, phase: .response) else {
        return test.expect(false, "Engine matches imported Charles Rewrite")
    }
    let wrong = ScriptingTarget(method: target.method, scheme: target.scheme, host: target.host, path: target.path,
                                query: "name=2", url: "http://example.test:8080/v1/inspect?name=2")
    test.expect(ScriptingService.plan(for: wrong, phase: .response) == nil, "Charles Rewrite respects the query matcher")
    let head = BreakpointHead.response(HTTPResponseHead(version: "HTTP/1.1", status: 200, reason: "OK",
        headers: HTTPHeaders([("X-Remove", "drop"), ("X-Existing", "before"), ("X-Existing", "duplicate")])))
    let reply = NSBox<ScriptingResult>()
    ScriptingService.run(plan, head: head, body: nil) { reply.store($0) }
    let response = try reply.wait()
    test.equal(response.head.headers.value(of: "X-Migrated"), "migrated", "Engine adds imported response header")
    test.equal(response.head.headers.value(of: "X-Remove"), nil, "Engine removes imported response header")
    test.equal(response.head.headers.values(of: "X-Existing"), ["replaced", "replaced"],
               "Engine replaces matching imported response headers")
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw CharlesImport.ImportError("Charles fixture is missing an exchange") }
    return value
}
