import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkInspectionBodies(_ test: CoreAssertions) {
    func columnValue(_ column: CustomTrafficColumn, _ transaction: Transaction, expected: String) -> String {
        let deadline = Date().addingTimeInterval(2)
        var value = column.value(for: transaction)
        while value != expected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            value = column.value(for: transaction)
        }
        return value
    }
    let wire = Data(base64Encoded: "H4sIAAAAAAACA6tWykxRsjI0MtZRyk0tLk5MT1WyUspIzcnJV6oFAFLkIOocAAAA")!
    let tx = Transaction()
    tx.requestHeaders = HTTPHeaders([("Content-Type", "application/json"), ("Content-Encoding", "gzip")])
    tx.responseHeaders = tx.requestHeaders
    tx.requestBody = wire
    tx.responseBody = wire
    let column = CustomTrafficColumn(title: "ID", source: .responseJSON, key: "id")
    let requestColumn = CustomTrafficColumn(title: "ID", source: .requestJSON, key: "id")
    let contains = TrafficCondition(field: .responseBody, value: "hello").compile()
    test.equal(column.value(for: tx), "", "Incomplete compressed JSON is not interpreted as application data")
    test.expect(!contains(tx), "Incomplete compressed body does not match text")
    tx.requestBodyComplete = true
    tx.responseBodyComplete = true
    test.equal(columnValue(column, tx, expected: "123"), "123", "Response JSON column reads gzip-decoded body in the background")
    test.equal(columnValue(requestColumn, tx, expected: "123"), "123", "Request JSON column reads gzip-decoded body in the background")
    test.expect(contains(tx), "Completion invalidates a previously unmatched compressed body")
    test.expect(TrafficCondition(field: .requestBody, comparison: .regex, value: #""id":123"#).compile()(tx),
                "Request body regex sees decoded JSON")
    test.equal(tx.requestBody, wire, "Inspection does not change replay bytes")
    let cancelledTx = Transaction()
    cancelledTx.responseHeaders = tx.responseHeaders
    cancelledTx.responseBody = wire
    cancelledTx.responseBodyComplete = true
    let gate = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let cancelled = Task.detached {
        gate.wait()
        _ = InspectionBody.data(for: cancelledTx, request: false, limit: 131_072)
        done.signal()
    }
    cancelled.cancel()
    gate.signal()
    test.expect(done.wait(timeout: .now() + 2) == .success, "Cancelled inspection finishes without blocking")
    test.equal(InspectionBody.data(for: cancelledTx, request: false, limit: 131_072),
               Data("{\"id\":123,\"message\":\"hello\"}".utf8),
               "A cancelled inspection cannot poison later decoded-body cache reads")
    test.equal(InspectionBody.data(for: tx, request: false, limit: 5, prefix: true), Data("{\"id\"".utf8),
               "Decoded prefix obeys caller's output limit")
    test.expect(InspectionBody.data(for: tx, request: false, limit: 5) == nil,
                "Whole-body consumers reject oversized decoded data")
    tx.responseHeaders = HTTPHeaders([("Content-Type", "application/json"), ("Content-Encoding", "unsupported")])
    test.equal(column.value(for: tx), "", "Encoding changes invalidate JSON column cache")
    test.expect(!contains(tx), "Encoding changes invalidate body-filter cache")
    tx.responseHeaders = tx.requestHeaders
    test.equal(columnValue(column, tx, expected: "123"), "123", "Restoring a supported encoding refreshes JSON values")
    tx.responseTruncated = true
    test.equal(column.value(for: tx), "", "Truncated compressed body cannot reuse a complete decoded value")
    tx.responseTruncated = false
    tx.responseBody = Data("{\"id\":456}".utf8)
    tx.responseHeaders = HTTPHeaders([("Content-Type", "application/json")])
    test.equal(columnValue(column, tx, expected: "456"), "456", "Body replacement refreshes custom values")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-json-sort-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TrafficStore(sourceFolderFile: directory.appendingPathComponent("sources.json"),
                             savedFile: directory.appendingPathComponent("saved.json"))
    let first = Transaction(), second = Transaction(), third = Transaction()
    for (transaction, number) in [(first, 9), (second, 1), (third, 5)] {
        transaction.responseBody = Data("{\"id\":\(number)}".utf8)
        transaction.responseBodyComplete = true
        store.add(transaction)
    }
    let sorting = TrafficColumn.custom(column)
    _ = store.displayedRows(sortedBy: sorting, ascending: true)
    // Complete an obsolete sort out of order with a replacement body revision.
    // The main actor cannot publish the first worker until this turn yields.
    first.responseBody = Data(#"{"id":0}"#.utf8)
    store.update(first)
    let pendingRevision = store.displayedRows(sortedBy: sorting, ascending: true).revision
    let deadline = Date().addingTimeInterval(2)
    while store.displayedRows(sortedBy: sorting, ascending: true).revision == pendingRevision && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let display = store.displayedRows(sortedBy: sorting, ascending: true)
    test.expect(display.revision > pendingRevision, "JSON sorting publishes asynchronously after computing immutable keys")
    test.equal(display.rows.map(\.id), [first.id, second.id, third.id], "An obsolete JSON-sort revision cannot replace the current body order")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    test.equal(store.displayedRows(sortedBy: sorting, ascending: true).rows.map(\.id), [first.id, second.id, third.id],
               "A later completion from the cancelled sort cannot restore stale ordering")
    CustomColumnValues.shared.clear()
    test.equal(column.value(for: tx), "", "Memory-pressure cache clearing retires displayed JSON values immediately")
    test.equal(columnValue(column, tx, expected: "456"), "456", "JSON values rebuild from immutable bytes after pressure cleanup")

    let graphql = Transaction()
    graphql.path = "/graphql"
    graphql.requestHeaders = tx.requestHeaders
    graphql.requestBody = Data(base64Encoded: "H4sIAAAAAAACA6tWKixNLapUsoLQCm75+QrVCmWZqeWpRUBGZopCrUKtUi0AxYRS2CcAAAA=")!
    graphql.requestBodyComplete = true
    test.equal(GraphQLService.detect(tx: graphql)?.operationName, "Foo", "GraphQL detection decodes gzip request")
    test.equal(GraphQLService.detectRequest(path: graphql.path, query: "", headers: graphql.requestHeaders,
                                          body: graphql.requestBody)?.operationName, "Foo",
               "Raw GraphQL rule matching decodes gzip request")
    test.expect(TrafficCondition(field: .graphql, comparison: .equals, value: "Foo").compile()(graphql),
                "GraphQL filters still recognize compressed operation names")
    test.equal(CustomColumnValues.shared.graphqlValue(for: graphql), "", "A cold GraphQL list column does not parse its body on the main actor")
    let graphqlDeadline = Date().addingTimeInterval(2)
    while CustomColumnValues.shared.graphqlValue(for: graphql).isEmpty && Date() < graphqlDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    test.equal(CustomColumnValues.shared.graphqlValue(for: graphql), "Foo", "GraphQL list metadata arrives from the background extractor")
    graphql.requestBody = Data(#"{"query":"query Replacement { id }"}"#.utf8)
    graphql.requestHeaders = HTTPHeaders([("Content-Type", "application/json")])
    test.equal(CustomColumnValues.shared.graphqlValue(for: graphql), "", "A replacement GraphQL body cannot reuse a previous operation name")
    let replacementDeadline = Date().addingTimeInterval(2)
    while CustomColumnValues.shared.graphqlValue(for: graphql).isEmpty && Date() < replacementDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    test.equal(CustomColumnValues.shared.graphqlValue(for: graphql), "Replacement", "GraphQL column metadata follows the new body revision")
    test.expect(TrafficCondition(field: .graphql, comparison: .equals, value: "Replacement").compile()(graphql),
                "GraphQL filters retain their existing synchronous semantics")
}
