import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkDiffSnapshots(_ test: CoreAssertions) throws {
    let transaction = Transaction()
    transaction.responseHeaders = HTTPHeaders([("X-Original", "first")])
    transaction.responseBody = Data(#"{"value":"first"}"#.utf8)
    transaction.responseBodyComplete = true
    let captured = TrafficDiffDocument.snapshot(transaction, component: .response)
    transaction.responseHeaders = HTTPHeaders([("X-Original", "second")])
    transaction.responseBody = Data(#"{"value":"second"}"#.utf8)
    let lines = try TrafficDiffDocument.lines(captured, sortJSON: false, sortHeaders: false)
    test.expect(lines.contains("X-Original: first") && lines.contains(#"{"value":"first"}"#),
                "Diff worker consumes its immutable metadata and body snapshot")
    test.expect(!lines.contains("X-Original: second") && !lines.contains(#"{"value":"second"}"#),
                "Later transaction changes cannot change a pending Diff document")
    test.expect(captured.identity != TrafficDiffDocument.identity(transaction, component: .response),
                "Changed metadata/body identity prevents stale Diff publication")
    let before = TrafficDiffDocument.identity(transaction, component: .responseBody)
    transaction.responseHeaders.set(name: "Content-Encoding", value: "gzip")
    test.expect(before != TrafficDiffDocument.identity(transaction, component: .responseBody),
                "Diff body identity includes an encoding change at the same body revision")
    transaction.responseHeaders.remove(name: "Content-Encoding")
    let complete = TrafficDiffDocument.identity(transaction, component: .responseBody)
    transaction.responseBodyComplete = false
    test.expect(complete != TrafficDiffDocument.identity(transaction, component: .responseBody),
                "Diff identity includes stream completeness")

    transaction.responseBody = Data(repeating: 255, count: 262_144)
    transaction.responseBodyComplete = true
    let binary = TrafficDiffDocument.snapshot(transaction, component: .responseBody)
    let formatted = try TrafficDiffDocument.lines(binary, sortJSON: true, sortHeaders: false)
    test.equal(formatted.count, TrafficDiffDocument.lineLimit + 1, "Binary Diff stops generation at its line budget")
    test.expect(formatted.last == Strings.Models.diffLineLimit(TrafficDiffDocument.lineLimit),
                "Truncated Diff documents preserve a localized explanation")
}
