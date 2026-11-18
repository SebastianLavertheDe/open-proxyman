import Foundation
import AppKit
import UniformTypeIdentifiers

/// 剪贴板助手
enum CopyPaste {
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// HAR 1.2 导出 + cURL 命令生成
enum ExportService {

    static func exportHAR(_ transactions: [Transaction]) {
        guard !transactions.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxymirror.har"
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let records = transactions.map(SessionRecord.init)
        SessionFile.fileQueue.async {
            do {
                try writeHAR(records, to: url)
            } catch {
                reportExportFailure(error, format: "HAR")
            }
        }
    }

    static func writeHAR(_ records: [SessionRecord], to url: URL) throws {
        let har = buildHAR(records.map { $0.transaction() })
        let data = try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func reportExportFailure(_ error: Error, format: String) {
        let message = "\(format) 导出失败：\(error.localizedDescription)"
        NSLog("[ProxyMirror] %@", message)
        DispatchQueue.main.async { AppState.shared.systemProxyMessage = message }
    }

    static func buildHAR(_ transactions: [Transaction]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries: [[String: Any]] = transactions.map { tx in
            var entry: [String: Any] = [:]
            entry["startedDateTime"] = iso.string(from: tx.startedAt)
            entry["time"] = tx.duration * 1000
            entry["_kind"] = tx.isTunnel ? "Tunnel" : "HTTP"

            var req: [String: Any] = [:]
            req["method"] = tx.method
            req["url"] = tx.fullURL
            req["httpVersion"] = tx.requestVersion
            req["headers"] = harHeaders(tx.requestHeaders)
            if tx.requestTrailers.count > 0 { req["_trailers"] = harHeaders(tx.requestTrailers) }
            req["headersSize"] = -1
            req["bodySize"] = max(tx.requestBytes, tx.requestBody.count)
            if !tx.requestBody.isEmpty {
                let mimeType = tx.requestHeaders.value(of: "Content-Type") ?? ""
                let text = mimeType.lowercased().hasPrefix("application/grpc") ? nil : String(data: tx.requestBody, encoding: .utf8)
                var post = ["mimeType": mimeType,
                            "text": text ?? tx.requestBody.base64EncodedString()]
                if text == nil { post["_encoding"] = "base64" }
                req["postData"] = post
            }
            req["_truncated"] = tx.requestTruncated
            let qpairs = tx.query.split(separator: "&").map { p -> [String: String] in
                let kv = p.split(separator: "=", maxSplits: 1)
                return ["name": kv.first.map(String.init) ?? "", "value": kv.count > 1 ? String(kv[1]) : ""]
            }
            req["queryString"] = qpairs
            entry["request"] = req

            var resp: [String: Any] = [:]
            resp["status"] = tx.statusCode
            resp["statusText"] = tx.statusReason
            resp["httpVersion"] = tx.responseVersion
            resp["headers"] = harHeaders(tx.responseHeaders)
            if tx.responseTrailers.count > 0 { resp["_trailers"] = harHeaders(tx.responseTrailers) }
            let responseText = tx.contentType.lowercased().hasPrefix("application/grpc") ? nil : String(data: tx.responseBody, encoding: .utf8)
            var content: [String: Any] = [
                "size": max(tx.responseBytes, tx.responseBody.count),
                "mimeType": tx.contentType,
                "text": responseText ?? tx.responseBody.base64EncodedString(),
            ]
            if responseText == nil { content["encoding"] = "base64" }
            resp["content"] = content
            resp["headersSize"] = -1
            resp["bodySize"] = max(tx.responseBytes, tx.responseBody.count)
            if let error = tx.errorText, !error.isEmpty { resp["_error"] = error }
            resp["_truncated"] = tx.responseTruncated
            if let original = tx.originalURL { entry["_originalURL"] = original }
            if let protocolName = tx.upstreamProtocol { entry["_upstreamProtocol"] = protocolName }
            if !tx.comment.isEmpty { entry["comment"] = tx.comment }
            entry["response"] = resp

            entry["cache"] = [String: Any]()
            let details = tx.connectionDetails?.reused == true ? nil : tx.connectionDetails
            let dns = details?.dnsMilliseconds ?? -1
            let tls = details?.tlsMilliseconds ?? -1
            let connect = details?.tcpMilliseconds.map { $0 + max(0, tls) } ?? -1
            let total = tx.duration * 1000
            let untilHeaders = tx.tHeaderAt.map { min(total, max(0, $0.timeIntervalSince(tx.startedAt) * 1000)) } ?? total
            entry["timings"] = ["dns": dns, "connect": connect, "ssl": tls, "send": 0,
                                "wait": max(0, untilHeaders - max(0, dns) - max(0, connect)),
                                "receive": max(0, total - untilHeaders)]
            return entry
        }

        return [
            "log": [
                "version": "1.2",
                "creator": ["name": "ProxyMirror",
                            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"],
                "entries": entries,
            ]
        ]
    }

    private static func harHeaders(_ headers: HTTPHeaders) -> [[String: String]] {
        headers.pairs.map { ["name": $0.name, "value": $0.value] }
    }

    /// CSV 导出（对齐 Proxyman Export ▸ as CSV）
    static func exportCSV(_ transactions: [Transaction]) {
        guard !transactions.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxymirror.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try writeCSV(transactions, to: url) }
        catch { reportExportFailure(error, format: "CSV") }
    }

    static func writeCSV(_ transactions: [Transaction], to url: URL) throws {
        var rows = ["Method,Status,URL,Content Type,Size,Duration(ms),Start Time"]
        for tx in transactions {
            let cells = [tx.method, String(tx.statusCode), tx.fullURL,
                         tx.contentType, String(tx.totalSize),
                         String(format: "%.0f", tx.duration * 1000), tx.timeText]
            rows.append(cells.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))" }.joined(separator: ","))
        }
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 生成可复用的 cURL 命令
    static func curlCommand(_ tx: Transaction) -> String {
        if tx.isTunnel {
            let authority = URLParser.authority(host: tx.host, port: tx.port, scheme: "https")
            return "curl --proxy 'http://127.0.0.1:\(AppSettings.shared.port)' 'https://\(_escape(authority))'"
        }
        var parts = ["curl '\(_escape(tx.fullURL))'"]
        let body = tx.requestBody
        if tx.method != "GET" || !body.isEmpty {
            let method = tx.method.utf8.allSatisfy { (65...90).contains($0) } ? tx.method : "'\(_escape(tx.method))'"
            parts.append("-X \(method)")
        }
        let skipped = ["host", "content-length", "connection", "accept-encoding", "transfer-encoding", "trailer", "proxy-authorization", "proxy-connection"]
        for p in tx.requestHeaders.pairs where !skipped.contains(p.name.lowercased()) {
            let header = p.value.isEmpty ? p.name + ";" : p.name + ": " + p.value
            parts.append("-H '\(_escape(header))'")
        }
        if !body.isEmpty {
            if let text = String(data: body, encoding: .utf8), !text.utf8.contains(0) {
                parts.append("--data-raw '\(_escape(text))'")
            } else {
                parts[0] = "printf '%s' '\(body.base64EncodedString())' | base64 -d | " + parts[0]
                parts.append("--data-binary @-")
            }
        }
        return parts.joined(separator: " \\\n  ")
    }

    private static func _escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    static func httpieCommand(_ tx: Transaction) -> String {
        let request = ComposeService.request(from: tx)
        let omitted = ["host", "content-length", "connection", "transfer-encoding", "trailer", "proxy-authorization"]
        var args = ["http", "'\(_escape(request.method))'", "'\(_escape(request.url))'"]
        args += request.headers.filter { !omitted.contains($0.0.lowercased()) }
            .map { "'\(_escape($0.0 + ": " + $0.1))'" }
        let command = args.joined(separator: " ")
        if let body = request.body, !body.isEmpty {
            return "printf '%s' '\(body.base64EncodedString())' | base64 -d | " + command
        }
        return command
    }
}

@MainActor
enum RepeatService {
    private struct Request {
        let parsed: ComposeService.ParsedRequest
        let proxyPort: UInt16?
        let onResult: (Transaction) -> Void
    }

    private static let maxConcurrent = 4
    private static var active = 0
    private static var pending: [Request] = []
    private static var ready: [Request] = []

    static func resend(_ tx: Transaction, proxyPort: UInt16? = nil, onResult: @escaping (Transaction) -> Void) {
        guard let request = ComposeService.replayRequest(from: tx) else { return }
        pending.append(Request(parsed: request, proxyPort: proxyPort, onResult: onResult))
        startPending()
    }

    private static func startPending() {
        while active < maxConcurrent {
            if ready.isEmpty {
                ready = Array(pending.reversed())
                pending.removeAll()
            }
            guard let request = ready.popLast() else { return }
            active += 1
            let task = ComposeService.execute(request.parsed, proxyPort: request.proxyPort) { result in
                active -= 1
                request.onResult(result)
                startPending()
            }
            if task == nil { active -= 1 }
        }
    }
}
