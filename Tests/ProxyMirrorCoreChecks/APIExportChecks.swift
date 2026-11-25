import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkAPIExports(_ test: CoreAssertions) throws {
    let tx = Transaction()
    tx.method = "POST"; tx.scheme = "https"; tx.host = "api.example.test"; tx.port = 443
    tx.path = "/api/users/42"; tx.query = "token=query-secret"
    tx.requestHeaders = HTTPHeaders([("Authorization", "Bearer header-secret"), ("Content-Type", "application/json")])
    tx.responseHeaders = HTTPHeaders([("Content-Type", "application/json")])
    tx.requestBody = Data(#"{"password":"body-secret","name":"visible"}"#.utf8)
    tx.responseBody = Data(#"{"id":42,"token":"response-secret"}"#.utf8)
    tx.requestBodyComplete = true; tx.responseBodyComplete = true; tx.statusCode = 201
    let record = SessionRecord(tx)
    for document in [ExportService.buildOpenAPI([record], redactSensitiveHeaders: true),
                     ExportService.buildPostman([record], redactSensitiveHeaders: true)] {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
        for secret in ["header-secret", "query-secret", "body-secret", "response-secret"] {
            test.expect(!text.contains(secret), "API export privacy removes \(secret)")
        }
        test.expect(text.contains("visible"), "API export privacy retains ordinary sample fields")
    }
    test.equal(tx.requestBody, record.requestBody, "Export privacy never changes captured request bytes")
    let openAPI = ExportService.buildOpenAPI([record], redactSensitiveHeaders: true)
    let components = openAPI["components"] as? [String: Any]
    test.expect((components?["securitySchemes"] as? [String: Any])?["bearerAuth"] != nil,
                "Header redaction preserves the observed OpenAPI authentication scheme")
    let postman = ExportService.buildPostman([record], redactSensitiveHeaders: true)
    test.equal((postman["auth"] as? [String: Any])?["type"] as? String, "bearer", "Collection lifts shared redacted bearer authentication")
    let cli = try AutomationControl.parseCLI(["export", "openapi", "--output", "/tmp/openapi.json"])
    test.equal(cli?.0["operation"] as? String, "export_flows", "OpenAPI CLI reaches the flow export operation")
    test.equal(cli?.0["format"] as? String, "openapi", "OpenAPI CLI alias retains the format")
    let tool = MCPProtocol.tools.first { $0["name"] as? String == "export_flows" }
    let properties = (tool?["inputSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]]
    let formats = properties?["format"]?["enum"] as? [String]
    test.expect(formats?.contains("openapi") == true && formats?.contains("postman") == true,
                "MCP advertises the implemented API collection formats")
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, write) in [("openapi.json", ExportService.writeOpenAPI), ("postman.json", ExportService.writePostman)] {
        let target = directory.appendingPathComponent(name)
        try write([record], target)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        test.equal(mode?.intValue, 0o600, "API exports preserve private file permissions")
    }
}
