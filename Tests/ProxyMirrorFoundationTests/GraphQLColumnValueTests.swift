import Foundation
import ProxyMirrorFoundation
import XCTest

final class GraphQLColumnValueTests: XCTestCase {
    private func name(_ body: String = "", path: String = "/api", query: String = "", type: String = "application/json") -> String {
        GraphQLColumnValue.operationName(path: path, query: query, contentType: type, body: Data(body.utf8))
    }

    func testJSONDocumentAndExplicitSelectionKeepExistingColumnBehavior() {
        XCTAssertEqual(name(#"{"query":"query Inferred { viewer { id } }","operationName":"Selected","variables":{"large":[1,2,3]}}"#), "Selected")
        XCTAssertEqual(name(##"{"query":"# comment\nquery FindUser($id: ID!) { user(id:$id) { name } }"}"##), "FindUser")
        XCTAssertEqual(name(#"{"query":"subscription OnMessage { message { id } }","operationName":""}"#), "OnMessage")
        XCTAssertEqual(name(#"{"extensions":{"persistedQuery":{"sha256Hash":"fixture"}},"operationName":"Persisted"}"#), "Persisted")
        XCTAssertEqual(name(#"{"operationName":"NotGraphQL"}"#), "")
        XCTAssertEqual(name(#"{"query":"{ viewer { id } }"}"#), "")
        XCTAssertEqual(name("not JSON"), "")
        XCTAssertEqual(name(#"[{"query":"query Batch { id }"}]"#), "", "the previous column did not classify batch arrays")
        XCTAssertEqual(name(#"{"query":"mutation Update { update { id } }"}"#, type: "application/octet-stream"), "Update")
    }

    func testGraphQLMediaTypeAndGETQueryFallback() {
        XCTAssertEqual(name("# comment\nmutation Save($id: ID!) { save(id:$id) { id } }", type: "application/graphql; charset=utf-8"), "Save")
        XCTAssertEqual(name(query: "query=query%20Find%20%7B%20viewer%20%7B%20id%20%7D%20%7D"), "Find")
        XCTAssertEqual(name(query: "query=query%20Inferred%20%7B%20id%20%7D&operationName=Selected"), "Selected")
        XCTAssertEqual(name(path: "/API/GraphQL", query: "operationName=Persisted"), "Persisted")
        XCTAssertEqual(name(path: "/api", query: "operationName=NotGraphQL"), "")
        XCTAssertEqual(name(path: "/graphql", query: "query=&operationName=Selected"), "Selected")
        XCTAssertEqual(name(#"{"query":"query BodyWins { id }"}"#, query: "query=query%20QueryLoses%20%7B%20id%20%7D"), "BodyWins")
        XCTAssertEqual(name("invalid body", query: "query=query%20Fallback%20%7B%20id%20%7D"), "Fallback")
    }

    func testBodiesQueriesAndReturnedDisplayValuesAreBounded() throws {
        let huge = String(repeating: "x", count: GraphQLColumnValue.maximumInputBytes + 1)
        XCTAssertEqual(name(huge), "")
        XCTAssertEqual(name(path: "/graphql", query: "operationName=" + huge), "")
        let operationName = String(repeating: "界", count: 1000)
        let body = try JSONSerialization.data(withJSONObject: ["query": "query Short { id }", "operationName": operationName])
        let result = GraphQLColumnValue.operationName(path: "/graphql", query: "", contentType: "application/json", body: body)
        XCTAssertLessThanOrEqual(result.utf8.count, GraphQLColumnValue.maximumValueBytes)
        XCTAssertFalse(result.contains("\u{fffd}"), "a UTF-8 truncation must not introduce replacement characters")
        XCTAssertTrue(operationName.hasPrefix(result))
    }

    func testCancelledExtractionDoesNotReturnAValue() async {
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            started.signal(); resume.wait()
            return GraphQLColumnValue.operationName(path: "/graphql", query: "operationName=Cancelled", contentType: "", body: Data())
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        worker.cancel(); resume.signal()
        let result = await worker.value
        XCTAssertEqual(result, "")
    }
}
