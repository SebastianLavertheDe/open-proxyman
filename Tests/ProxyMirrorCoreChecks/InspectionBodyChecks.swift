import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkInspectionBodies(_ test: CoreAssertions) {
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
    test.equal(column.value(for: tx), "123", "Response JSON column reads gzip-decoded body")
    test.equal(requestColumn.value(for: tx), "123", "Request JSON column reads gzip-decoded body")
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
    test.equal(column.value(for: tx), "123", "Restoring a supported encoding refreshes JSON values")
    tx.responseTruncated = true
    test.equal(column.value(for: tx), "", "Truncated compressed body cannot reuse a complete decoded value")
    tx.responseTruncated = false
    tx.responseBody = Data("{\"id\":456}".utf8)
    tx.responseHeaders = HTTPHeaders([("Content-Type", "application/json")])
    test.equal(column.value(for: tx), "456", "Body replacement refreshes custom values")

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
                "GraphQL filter sees compressed operation names")
}
