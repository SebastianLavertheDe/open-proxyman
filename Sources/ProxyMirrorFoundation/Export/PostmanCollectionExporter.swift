import Foundation

package enum PostmanCollectionExporter {
    package static func document(_ exchanges: [APIExchange], name: String = "ProxyMirror Requests") -> [String: Any] {
        let samples = exchanges.compactMap { exchange -> (APIExchange, URLComponents, String)? in
            guard let url = URLComponents(string: exchange.url), let scheme = url.scheme,
                  ["http", "https"].contains(scheme.lowercased()), let host = url.host else { return nil }
            let literal = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return (exchange, url, scheme + "://" + literal + (url.port.map { ":\($0)" } ?? ""))
        }
        let origins = Array(Set(samples.map { $0.2 })).sorted()
        // Indexed names remain unique when punctuation in two hosts normalizes
        // to the same identifier (api-a versus api_a, or different ports).
        let variables = Dictionary(uniqueKeysWithValues: origins.enumerated().map { index, origin in
            (origin, "baseUrl_" + origin.filter { $0.isLetter || $0.isNumber } + "_\(index + 1)")
        })
        let sharedAuth = commonAuth(samples.map { $0.0 })
        let hosts: [[String: Any]] = origins.map { origin in
            let values = samples.filter { $0.2 == origin }
            let folders = Dictionary(grouping: values) { $0.1.path.split(separator: "/").first.map(String.init) ?? "/" }
            return ["name": origin, "item": folders.keys.sorted().map { folder -> [String: Any] in
                ["name": folder, "item": folders[folder]!.map { value -> [String: Any] in
                    let raw = "{{" + variables[origin]! + "}}" + value.1.percentEncodedPath
                        + (value.1.percentEncodedQuery.map { "?" + $0 } ?? "")
                    return item(value.0, url: raw, inheritAuth: sharedAuth != nil)
                }]
            }]
        }
        var result: [String: Any] = ["info": ["name": name,
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            "description": "Captured with ProxyMirror. Binary request bodies include Base64 instructions in their request descriptions."],
            "item": hosts,
            "variable": origins.map { ["key": variables[$0]!, "value": $0, "type": "string"] }]
        if let sharedAuth { result["auth"] = sharedAuth }
        return result
    }

    /// Single-request code generation and collection exports use the same item encoding.
    package static func item(_ exchange: APIExchange, url: String? = nil, inheritAuth: Bool = false) -> [String: Any] {
        var safeURL = URLComponents(string: exchange.url)
        safeURL?.user = nil; safeURL?.password = nil; safeURL?.fragment = nil
        var request: [String: Any] = ["method": exchange.method, "url": url ?? safeURL?.string ?? exchange.url,
            "header": exchange.requestHeaders.filter { !(inheritAuth && $0.0.caseInsensitiveCompare("Authorization") == .orderedSame) }
                .map { ["key": $0.0, "value": $0.1] }]
        if !exchange.requestBody.isEmpty {
            if let text = String(data: exchange.requestBody, encoding: .utf8), !exchange.requestBody.contains(0) {
                request["body"] = ["mode": "raw", "raw": text]
            } else {
                request["body"] = ["mode": "file", "file": ["src": "request-body.bin"]]
                request["description"] = "Decode this Base64 to request-body.bin, then select that local file before sending: " + exchange.requestBody.base64EncodedString()
            }
        }
        if !inheritAuth { request["auth"] = ["type": "noauth"] }
        if !exchange.requestComplete {
            request["description"] = "The captured request body is incomplete. Review and complete it before sending.\n"
                + (request["description"] as? String ?? "")
        }
        let path = URLComponents(string: exchange.url)?.percentEncodedPath ?? exchange.url
        return ["name": exchange.method + " " + (path.isEmpty ? "/" : path), "request": request]
    }

    private static func commonAuth(_ exchanges: [APIExchange]) -> [String: Any]? {
        guard let first = exchanges.first?.header("Authorization"),
              exchanges.allSatisfy({ $0.header("Authorization") == first }) else { return nil }
        if first.lowercased().hasPrefix("bearer ") {
            return ["type": "bearer", "bearer": [["key": "token", "value": String(first.dropFirst(7)), "type": "string"]]]
        }
        // apiKey preserves other Authorization schemes byte for byte while
        // still letting every request inherit one collection-level value.
        return ["type": "apikey", "apikey": [
            ["key": "key", "value": "Authorization", "type": "string"],
            ["key": "value", "value": first, "type": "string"],
            ["key": "in", "value": "header", "type": "string"]]]
    }
}
