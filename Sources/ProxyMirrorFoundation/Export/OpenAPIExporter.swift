import Foundation

package enum OpenAPIExporter {
    private struct Sample {
        let exchange: APIExchange
        let origin: String
        let segments: [String]
        let parameters: [String: String]
        let query: [URLQueryItem]
    }

    /// Responses without a status and incomplete bodies never become invented API examples.
    package static func document(_ exchanges: [APIExchange], title: String = "ProxyMirror API") -> [String: Any] {
        let samples = exchanges.compactMap(sample)
        let prefix = commonPrefix(samples.map(\.segments))
        let groups = Dictionary(grouping: samples) { item in
            "/" + item.segments.dropFirst(prefix.count).joined(separator: "/")
        }
        var paths: [String: Any] = [:]
        var schemes: [String: Any] = [:]
        for path in groups.keys.sorted() {
            let methods = Dictionary(grouping: groups[path]!) { $0.exchange.method.lowercased() }
            var item: [String: Any] = [:]
            for method in methods.keys.sorted() {
                let values = methods[method]!
                var operation: [String: Any] = ["summary": method.uppercased() + " " + path,
                    "servers": Array(Set(values.map { $0.origin + prefixPath(prefix) })).sorted().map { ["url": $0] }]
                var parameters: [[String: Any]] = []
                for name in Set(values.flatMap { $0.parameters.keys }).sorted() {
                    let observations = values.compactMap { $0.parameters[name] }.map(scalar)
                    parameters.append(["name": name, "in": "path", "required": true,
                                       "schema": JSONSchemaInferencer.infer(observations)])
                }
                for name in Set(values.flatMap { $0.query.map(\.name) }).sorted() {
                    let observations = values.flatMap { $0.query.filter { $0.name == name }.map { scalar($0.value ?? "") } }
                    var parameter: [String: Any] = ["name": name, "in": "query",
                        "required": values.allSatisfy { $0.query.contains { $0.name == name } },
                        "schema": JSONSchemaInferencer.infer(observations)]
                    if let example = observations.first { parameter["example"] = example }
                    if values.contains(where: { $0.query.filter { $0.name == name }.count > 1 }) {
                        parameter["schema"] = ["type": "array", "items": JSONSchemaInferencer.infer(observations)]
                        parameter["style"] = "form"; parameter["explode"] = true
                    }
                    parameters.append(parameter)
                }
                if !parameters.isEmpty { operation["parameters"] = parameters }
                let requests = values.map(\.exchange).filter { !$0.requestBody.isEmpty && $0.requestComplete }
                if !requests.isEmpty {
                    operation["requestBody"] = ["required": requests.count == values.count,
                        "content": content(requests, response: false)]
                }
                let responses = Dictionary(grouping: values.map(\.exchange).filter { (100...599).contains($0.status) }) { String($0.status) }
                var responseItems: [String: Any] = [:]
                for status in responses.keys.sorted() {
                    let complete = responses[status]!.filter(\.responseComplete)
                    var response: [String: Any] = ["description": "Captured HTTP " + status]
                    let body = content(complete, response: true)
                    if !body.isEmpty { response["content"] = body }
                    responseItems[status] = response
                }
                if responseItems.isEmpty { responseItems["default"] = ["description": "No complete response was captured."] }
                operation["responses"] = responseItems
                var security: [[String: [String]]] = []
                for value in values {
                    var requirement: [String: [String]] = [:]
                    if value.exchange.header("Authorization")?.lowercased().hasPrefix("bearer ") == true {
                        schemes["bearerAuth"] = ["type": "http", "scheme": "bearer"]
                        requirement["bearerAuth"] = []
                    }
                    if value.exchange.header("X-API-Key") != nil {
                        schemes["apiKeyAuth"] = ["type": "apiKey", "in": "header", "name": "X-API-Key"]
                        requirement["apiKeyAuth"] = []
                    }
                    if !security.contains(where: { $0 == requirement }) { security.append(requirement) }
                }
                if security.contains(where: { !$0.isEmpty }) { operation["security"] = security }
                item[method] = operation
            }
            paths[path] = item
        }
        var result: [String: Any] = ["openapi": "3.0.3", "info": ["title": title, "version": "1.0.0"],
            "servers": Array(Set(samples.map { $0.origin + prefixPath(prefix) })).sorted().map { ["url": $0] }, "paths": paths]
        if !schemes.isEmpty { result["components"] = ["securitySchemes": schemes] }
        return result
    }

    private static func content(_ exchanges: [APIExchange], response: Bool) -> [String: Any] {
        let nonempty = exchanges.filter { !(response ? $0.responseBody : $0.requestBody).isEmpty }
        let groups = Dictionary(grouping: nonempty) { exchange in
            exchange.header("Content-Type", response: response)?.split(separator: ";").first.map(String.init)?.lowercased()
                ?? "application/octet-stream"
        }
        return groups.mapValues { values in
            let bytes = values.map { response ? $0.responseBody : $0.requestBody }
            let json = bytes.compactMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            if json.count == bytes.count, let first = json.first {
                return ["schema": JSONSchemaInferencer.infer(json), "example": first]
            }
            let texts = bytes.compactMap { String(data: $0, encoding: .utf8) }
            if texts.count == bytes.count, let first = texts.first {
                return ["schema": ["type": "string"], "example": first]
            }
            return ["schema": ["type": "string", "format": "binary"]]
        }
    }

    private static func sample(_ exchange: APIExchange) -> Sample? {
        guard let url = URLComponents(string: exchange.url), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              ["get", "put", "post", "delete", "options", "head", "patch", "trace"].contains(exchange.method.lowercased()) else { return nil }
        let hostLiteral = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let port = url.port.map { ":\($0)" } ?? ""
        let origin = scheme + "://" + hostLiteral + port
        let parts = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        var names: Set<String> = [], parameters: [String: String] = [:]
        let segments = parts.enumerated().map { index, segment -> String in
            let decoded = segment.removingPercentEncoding ?? segment
            let number = !decoded.isEmpty && decoded.utf8.allSatisfy { (48...57).contains($0) }
            let uuid = UUID(uuidString: decoded) != nil
            let hex = decoded.count >= 16 && decoded.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
            guard number || uuid || hex else { return segment }
            let previous = index > 0 ? parts[index - 1] : ""
            var base = previous.filter { $0.isLetter || $0.isNumber }
            if base.hasSuffix("ies") { base = String(base.dropLast(3)) + "y" }
            else if base.hasSuffix("s"), !base.hasSuffix("ss") { base.removeLast() }
            if base.isEmpty || names.contains(base) { base = "item\(index + 1)" }
            // Numeric and UUID observations can address the same endpoint.
            // Keep their template name identical so OpenAPI never contains
            // ambiguous /users/{userId} and /users/{userUuid} routes.
            var name = base + "Id"
            while names.contains(name) { name += "2" }
            names.insert(name); parameters[name] = decoded
            return "{" + name + "}"
        }
        return Sample(exchange: exchange, origin: origin, segments: segments, parameters: parameters, query: url.queryItems ?? [])
    }

    private static func scalar(_ string: String) -> Any {
        if string == "true" { return true }
        if string == "false" { return false }
        if let value = Int64(string), String(value) == string { return value }
        if let value = Double(string), value.isFinite, string.contains(".") { return value }
        return string
    }

    private static func commonPrefix(_ paths: [[String]]) -> [String] {
        guard let first = paths.first else { return [] }
        var prefix: [String] = []
        // Leave at least one path segment so an API with one observed route
        // retains its resource name rather than exporting only '/'.
        for index in 0..<max(0, first.count - 1) {
            let value = first[index]
            guard !value.contains("{"), paths.allSatisfy({ $0.count > index + 1 && $0[index] == value }) else { break }
            prefix.append(value)
        }
        return prefix
    }

    private static func prefixPath(_ prefix: [String]) -> String { prefix.isEmpty ? "" : "/" + prefix.joined(separator: "/") }
}
