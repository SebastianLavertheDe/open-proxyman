import Foundation
@testable import ProxyMirrorCore

func checkComposeAndPersistence(_ test: CoreAssertions) throws {
    try checkComposeExportFeatures(test)
    try checkSummaryAndFolderDrafts(test)
    let bodyText = "a\r\nb\n\n汉字"
    let path = "/a%2Fb?id=1&id=2"
    let raw = "POST \(path) HTTP/1.1\r\nHost: example.test\r\nX-Sample: a\r\nX-Sample: b\r\n\r\n\(bodyText)"
    let parsed = ComposeService.parse(raw)
    test.equal(parsed?.method, "POST", "Compose request method")
    test.equal(parsed?.url, "https://example.test\(path)", "Compose combines Host with encoded URL")
    test.equal(parsed?.body, Data(bodyText.utf8), "Compose preserves body bytes and line endings")
    test.equal(parsed?.headers.filter { $0.0 == "X-Sample" }.map { $0.1 }, ["a", "b"],
               "Compose preserves repeated header order")
    test.expect(ComposeService.parse("GET / HTTP/1.1") == nil, "Origin-form Compose request needs Host")

    let curl = ComposeService.parseCurl(#"curl 'https://example.test/a?q=1&q=2' --data-raw '@hello world'"#)
    test.equal(curl?.method, "POST", "cURL body defaults to POST")
    test.equal(curl?.body, Data("@hello world".utf8), "cURL raw data remains literal")
    test.expect(ComposeService.parseCurl("curl 'https://example.test") == nil, "Incomplete cURL quoting fails")

    let tx = Transaction()
    tx.method = "POST"
    tx.scheme = "https"
    tx.host = "example.test"
    tx.port = 443
    tx.path = "/a%2Fb"
    tx.query = "id=1&id=2"
    tx.requestBody = Data([0, 255, 128, 13])
    tx.requestHeaders = HTTPHeaders([("Content-Type", "application/octet-stream"), ("X-Sample", "a"), ("X-Sample", "b")])
    tx.responseHeaders = HTTPHeaders([("Set-Cookie", "sample=a"), ("Set-Cookie", "sample=b")])
    tx.responseTrailers = HTTPHeaders([("X-End", "done")])
    tx.contentType = "application/octet-stream"
    tx.statusCode = 404
    tx.statusReason = "Not Found"
    tx.state = .completed
    tx.captureLimit = 4
    tx.appendResponseBody(Data([0, 255, 128]))
    tx.appendResponseBody(Data([1, 2, 3]))
    tx.appendResponseBody(Data([4, 5]))
    tx.requestBodyComplete = true
    tx.responseBodyComplete = true
    tx.comment = "round trip"
    test.equal(tx.responseBody, Data([0, 255, 128, 1]), "Capture preserves only the first bytes within budget")
    test.equal(tx.responseBytes, 8, "Wire byte count includes all data after truncation")
    test.expect(tx.responseTruncated, "Capture reports truncation")
    test.equal(ComposeService.request(from: tx).body, tx.requestBody, "Replay preserves binary request bytes")

    let session = SessionFile(transactions: [tx], pinnedDomains: ["example.test"], selected: [tx.id])
    let restored = try SessionFile.decode(JSONEncoder().encode(session))
    let record = restored.records.first?.transaction()
    test.equal(restored.selected, [tx.id], "Session preserves selection")
    test.equal(restored.pinnedDomains, ["example.test"], "Session preserves pinned hosts")
    test.equal(record?.responseBody, tx.responseBody, "Session preserves captured response bytes")
    test.equal(record?.responseBytes, tx.responseBytes, "Session preserves original byte count")
    test.equal(record?.responseTruncated, true, "Session preserves truncation")
    test.equal(record?.responseTrailers.value(of: "x-end"), "done", "Session preserves trailers")
    test.equal(record?.comment, "round trip", "Session preserves annotations")
    let unsupported = try JSONSerialization.data(withJSONObject: [
        "version": SessionFile.currentVersion + 1, "records": [], "pinnedDomains": [], "selected": []
    ])
    test.rejects(try SessionFile.decode(unsupported), with: SessionFile.SessionError.self, "Unknown session version fails")
    let duplicated = SessionFile(transactions: [tx, tx], pinnedDomains: [], selected: [])
    test.rejects(try SessionFile.decode(JSONEncoder().encode(duplicated)), with: SessionFile.SessionError.self,
                 "Duplicate session IDs fail")

    let harData = try JSONSerialization.data(withJSONObject: ExportService.buildHAR([tx]))
    let imported = try SessionFile.importHAR(harData).first
    test.equal(imported?.requestBody, tx.requestBody, "HAR preserves binary request body")
    test.equal(imported?.responseBody, tx.responseBody, "HAR preserves binary response body")
    test.equal(imported?.responseHeaders.values(of: "Set-Cookie"), ["sample=a", "sample=b"], "HAR preserves duplicate headers")
    test.equal(imported?.responseTrailers.value(of: "x-end"), "done", "HAR preserves response trailers")
    test.equal(imported?.fullURL, tx.fullURL, "HAR preserves encoded path and repeated query")
    test.equal(imported?.statusText, "404 Not Found", "HAR preserves status and reason")

    let old = ProxyRule(pattern: "https://example.test/old")
    var updated = old
    updated.enabled = false
    let new = ProxyRule(pattern: "https://example.test/new")
    let keep = ProxyRule(pattern: "https://example.test/keep")
    let installed = RuleBackup(mapLocal: [old, keep], allowList: [keep])
    let data = try JSONEncoder().encode(RuleBackup(mapLocal: [updated, new]))
    let (backup, unknown) = try RuleBackup.read(data)
    test.expect(unknown.isEmpty, "Versionless rules.json remains readable")
    test.equal(backup.resolve(with: installed, merge: true).mapLocal, [updated, keep, new],
               "Rule merge replaces by ID and appends new entries")
    test.equal(backup.resolve(with: installed, merge: false).mapLocal, [updated, new],
               "Rule replacement updates supplied section")
    test.equal(backup.resolve(with: installed, merge: false).allowList, [keep],
               "Rule replacement preserves absent sections")
    let duplicateRules = try JSONEncoder().encode(RuleBackup(mapLocal: [updated, updated]))
    test.rejects(try RuleBackup.read(duplicateRules), with: RuleBackup.BackupError.self, "Duplicate rule IDs fail validation")
}
