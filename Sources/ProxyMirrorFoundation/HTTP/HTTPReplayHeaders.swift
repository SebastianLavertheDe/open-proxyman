import Foundation

package enum HTTPReplayHeaders {
    package static let sensitiveNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "cookie2", "set-cookie", "set-cookie2",
        "x-api-key", "api-key", "x-auth-token", "x-access-token"
    ]
    package static func command(_ headers: [(String, String)], preserveOriginal: Bool,
                                omitAcceptEncodingByDefault: Bool = false) -> [(String, String)] {
        let connectionFields = headers.filter { $0.0.caseInsensitiveCompare("Connection") == .orderedSame }
            .flatMap { $0.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        var omitted: Set<String> = ["host", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                                    "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade"]
        omitted.formUnion(connectionFields)
        if !preserveOriginal {
            omitted.insert("content-length")
            if omitAcceptEncodingByDefault { omitted.insert("accept-encoding") }
        }
        return headers.filter { !$0.0.hasPrefix(":") && !omitted.contains($0.0.lowercased()) }
    }
}

/// The app and network regression fixture use this same shell-code generator.
package enum CurlCommandGenerator {
    package static func command(_ request: HTTPRequest, isTunnel: Bool = false, proxyURL: String? = nil,
                                preserveOriginalHeaders: Bool = false, redactSensitiveHeaders: Bool = false) -> String {
        if isTunnel {
            let proxy = proxyURL.map { " --proxy '\(escape($0))'" } ?? ""
            return "curl\(proxy) '\(escape(request.url))'"
        }
        var parts = ["curl '\(escape(request.url))'"]
        if let proxyURL { parts.append("--proxy '\(escape(proxyURL))'") }
        let body = request.body ?? Data()
        if request.method == "HEAD" { parts.append("--head") }
        else if request.method != "GET" || !body.isEmpty {
            let method = request.method.utf8.allSatisfy { (65...90).contains($0) } ? request.method : "'\(escape(request.method))'"
            parts.append("-X \(method)")
        }
        let fields = request.headers.map { field in
            (field.0, redactSensitiveHeaders && HTTPReplayHeaders.sensitiveNames.contains(field.0.lowercased()) ? "<redacted>" : field.1)
        }
        let headers = HTTPReplayHeaders.command(fields, preserveOriginal: preserveOriginalHeaders, omitAcceptEncodingByDefault: true)
            .filter { request.method != "HEAD" || $0.0.caseInsensitiveCompare("Content-Length") != .orderedSame }
        for (name, value) in headers {
            parts.append("-H '\(escape(value.isEmpty ? name + ";" : name + ": " + value))'")
        }
        if !body.isEmpty && request.method != "HEAD" {
            if let text = String(data: body, encoding: .utf8), !text.utf8.contains(0) { parts.append("--data-raw '\(escape(text))'") }
            else {
                parts[0] = "printf '%s' '\(body.base64EncodedString())' | base64 -d | " + parts[0]
                parts.append("--data-binary @-")
            }
        }
        let note = request.method == "HEAD" && !body.isEmpty
            ? "# The captured request body is omitted, matching Compose's HEAD behavior.\n" : ""
        return note + parts.joined(separator: " \\\n  ")
    }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "'\\''") }
}
