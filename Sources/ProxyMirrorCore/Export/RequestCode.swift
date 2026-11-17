import Foundation

enum RequestCode {
    private static let transportHeaders: Set<String> = [
        "connection", "content-length", "host", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade"
    ]
    private static let browserHeaders: Set<String> = [
        "accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
        "cookie", "cookie2", "date", "dnt", "expect", "origin", "referer", "set-cookie", "set-cookie2", "via"
    ]

    static func pythonRequests(_ tx: Transaction) -> String {
        let request = ComposeService.request(from: tx)
        let headers = replayHeaders(request.headers)
        let pairs = headers.map { field in
            let value = quoted(field.value) + (field.value.utf8.allSatisfy { $0 < 128 } ? "" : ".encode(\"utf-8\")")
            return "    (\(quoted(field.name)), \(value)),"
        }
        var lines = ["import requests", "from urllib3._collections import HTTPHeaderDict"]
        if request.body != nil { lines.insert("from base64 import b64decode", at: 0) }
        lines += ["", "request = requests.Request(", "    method=\(quoted(request.method)),",
                  "    url=\(quoted(request.url)),"]
        if let body = request.body {
            lines.append("    data=b64decode(\(quoted(body.base64EncodedString()))),")
        }
        lines += [").prepare()", "headers = HTTPHeaderDict(["] + pairs + [
            "])",
            "for name, value in request.headers.items():",
            "    if name not in headers:",
            "        headers.add(name, value)",
            "request.headers = headers",
            "",
            "with requests.Session() as session:",
            "    response = session.send(request, timeout=30, allow_redirects=False)",
            "print(response.status_code)"
        ]
        return lines.joined(separator: "\n")
    }

    static func supportsFetch(_ tx: Transaction) -> Bool {
        let method = tx.method.uppercased()
        guard tx.canReplay, !["CONNECT", "TRACE", "TRACK"].contains(method) else { return false }
        return !["GET", "HEAD"].contains(method) || tx.requestBody.isEmpty
    }

    static func javascriptFetch(_ tx: Transaction) -> String {
        let request = ComposeService.request(from: tx)
        let capturedHeaders = replayHeaders(request.headers)
        let headers = capturedHeaders.filter { field in
            let name = field.name.lowercased()
            return !browserHeaders.contains(name) && !name.hasPrefix("sec-") && !name.hasPrefix("proxy-")
                && !(["x-http-method", "x-http-method-override", "x-method-override"].contains(name)
                    && field.value.split(separator: ",").contains {
                        ["CONNECT", "TRACE", "TRACK"].contains($0.trimmingCharacters(in: .whitespaces).uppercased())
                    })
        }
        let needsEncoding = headers.contains { !$0.value.utf8.allSatisfy { $0 < 128 } }
        var lines: [String] = []
        if capturedHeaders.count != headers.count {
            lines.append("// 浏览器会根据当前上下文生成受控请求头（如 Cookie、Origin）。")
        }
        if Set(headers.map { $0.name.lowercased() }).count != headers.count {
            lines.append("// Fetch 会合并重复请求头的值。")
        }
        if needsEncoding {
            lines.append("const utf8Header = (value) => Array.from(new TextEncoder().encode(value),")
            lines.append("  (byte) => String.fromCharCode(byte)).join(\"\");")
        }
        lines += ["fetch(\(quoted(request.url)), {", "  method: \(quoted(request.method)),", "  headers: ["]
        for field in headers {
            let literal = quoted(field.value)
            let value = field.value.utf8.allSatisfy { $0 < 128 } ? literal : "utf8Header(\(literal))"
            lines.append("    [\(quoted(field.name)), \(value)],")
        }
        lines += ["  ],"]
        if let body = request.body {
            let base64 = quoted(body.base64EncodedString())
            lines.append("  body: Uint8Array.from(atob(\(base64)), (byte) => byte.charCodeAt(0)),")
        }
        lines += ["  redirect: \"manual\",", "}).then((response) => console.log(response.status));"]
        return lines.joined(separator: "\n")
    }

    private static func replayHeaders(_ headers: [(String, String)]) -> [(name: String, value: String)] {
        let connectionFields = headers.filter { $0.0.caseInsensitiveCompare("Connection") == .orderedSame }
            .flatMap { $0.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        let omitted = transportHeaders.union(connectionFields)
        let punctuation = Set("!#$%&'*+-.^`|~_".utf8)
        return headers.filter { name, value in
            !name.isEmpty && !omitted.contains(name.lowercased()) && name.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || punctuation.contains($0)
            } && value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
        }
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding a Swift string always produces a quoted JSON string, accepted by both languages.
        return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
