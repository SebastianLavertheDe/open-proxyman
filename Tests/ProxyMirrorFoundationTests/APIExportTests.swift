import Foundation
import XCTest
@testable import ProxyMirrorFoundation

final class APIExportTests: XCTestCase {
    func testSchemaTracksRequiredNullableAndMixedArrays() throws {
        let a = try JSONSerialization.jsonObject(with: Data(#"{"id":1,"state":"open","value":null,"list":[1,"x"]}"#.utf8))
        let b = try JSONSerialization.jsonObject(with: Data(#"{"id":2,"state":"closed","value":"yes"}"#.utf8))
        let c = try JSONSerialization.jsonObject(with: Data(#"{"id":3,"state":"open","value":"yes"}"#.utf8))
        let schema = JSONSchemaInferencer.infer([a, b, c])
        XCTAssertEqual(schema["required"] as? [String], ["id", "state", "value"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["state"]?["enum"] as? [String], ["closed", "open"])
        XCTAssertEqual(properties["value"]?["nullable"] as? Bool, true)
        let items = properties["list"]?["items"] as? [String: Any]
        XCTAssertEqual((items?["anyOf"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(JSONSchemaInferencer.infer([true, false])["type"] as? String, "boolean")
    }

    func testOpenAPIPathQueryServersAndSecurity() throws {
        let samples = (1...5).map { id in APIExchange(method: "GET",
            url: "https://api.example.com:8443/api/users/\(id)?page=\(id)" + (id == 1 ? "&tag=a&tag=b" : ""),
            requestHeaders: [("Authorization", "Bearer never-export-this-token")], status: 200,
            responseHeaders: [("Content-Type", "application/json; charset=utf-8")],
            responseBody: Data("{\"id\":\(id),\"status\":\"active\"}".utf8)) }
        let document = OpenAPIExporter.document(samples)
        XCTAssertEqual(document["openapi"] as? String, "3.0.3")
        XCTAssertEqual((document["servers"] as? [[String: String]])?.first?["url"], "https://api.example.com:8443/api/users")
        let paths = try XCTUnwrap(document["paths"] as? [String: [String: [String: Any]]])
        let operation = try XCTUnwrap(paths["/{userId}"]?["get"])
        let parameters = try XCTUnwrap(operation["parameters"] as? [[String: Any]])
        XCTAssertEqual(parameters.first { $0["name"] as? String == "page" }?["required"] as? Bool, true)
        XCTAssertEqual(parameters.first { $0["name"] as? String == "tag" }?["required"] as? Bool, false)
        XCTAssertEqual((parameters.first { $0["name"] as? String == "tag" }?["schema"] as? [String: Any])?["type"] as? String, "array")
        let data = try JSONSerialization.data(withJSONObject: document)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("never-export-this-token"))
        XCTAssertNotNil((document["components"] as? [String: Any])?["securitySchemes"])
    }

    func testOpenAPIDistinguishesMethodsAndOmitsIncompleteBodies() throws {
        let values = [APIExchange(method: "GET", url: "https://example.com/a/0123456789abcdef", status: 200,
                                 responseBody: Data("partial".utf8), responseComplete: false),
                      APIExchange(method: "POST", url: "https://other.example.com/a/abcdef0123456789",
                                  requestBody: Data("incomplete".utf8), status: 0, requestComplete: false)]
        let paths = OpenAPIExporter.document(values)["paths"] as? [String: [String: [String: Any]]]
        XCTAssertNotNil(paths?["/{aId}"]?["get"])
        XCTAssertNotNil(paths?["/{aId}"]?["post"])
        XCTAssertNil(paths?["/{aId}"]?["post"]?["requestBody"])
        let responses = paths?["/{aId}"]?["get"]?["responses"] as? [String: [String: Any]]
        XCTAssertNil(responses?["200"]?["content"])
    }

    func testOpenAPICombinesNumericAndUUIDIdentifiersWithoutAmbiguousTemplates() throws {
        let document = OpenAPIExporter.document([
            APIExchange(method: "GET", url: "https://example.com/users/1", status: 200),
            APIExchange(method: "GET", url: "https://example.com/users/5b123a6f-8f24-4f74-8b19-28834c9d16e1", status: 200)])
        let paths = try XCTUnwrap(document["paths"] as? [String: Any])
        XCTAssertEqual(Set(paths.keys), ["/{userId}"])
    }

    func testPostmanFoldersVariablesAndCommonAuth() throws {
        let samples = ["https://api.example.com/users/1", "https://api.example.com/users/2", "https://api.example.com/projects", "https://other.example.com/users/1"].map {
            APIExchange(method: "POST", url: $0, requestHeaders: [("Authorization", "Bearer token"), ("X-Test", "yes")], requestBody: Data([0, 255]))
        }
        let document = PostmanCollectionExporter.document(samples)
        XCTAssertEqual((document["item"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((document["variable"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((document["auth"] as? [String: Any])?["type"] as? String, "bearer")
        let hosts = try XCTUnwrap(document["item"] as? [[String: Any]])
        let folders = try XCTUnwrap(hosts.first?["item"] as? [[String: Any]])
        XCTAssertEqual(folders.count, 2)
        let requests = folders.flatMap { $0["item"] as? [[String: Any]] ?? [] }
        let request = try XCTUnwrap(requests.first?["request"] as? [String: Any])
        XCTAssertTrue((request["url"] as? String)?.hasPrefix("{{baseUrl_") == true)
        XCTAssertEqual((request["header"] as? [[String: String]])?.count, 1)
        XCTAssertEqual((request["body"] as? [String: Any])?["mode"] as? String, "file")
        XCTAssertTrue((request["description"] as? String)?.contains("AP8=") == true)
    }

    func testPostmanDoesNotInheritDifferentCredentialsOrIncludeURLUserInfo() throws {
        let document = PostmanCollectionExporter.document([
            APIExchange(method: "GET", url: "https://user:secret@example.com/users/1", requestHeaders: [("Authorization", "Bearer a")]),
            APIExchange(method: "GET", url: "https://example.com/users/2", requestHeaders: [("Authorization", "Bearer b")])])
        XCTAssertNil(document["auth"])
        let data = try JSONSerialization.data(withJSONObject: document)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("user:secret"))
    }
}
