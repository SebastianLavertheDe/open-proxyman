import AppKit
import Foundation
import UniformTypeIdentifiers
import ProxyMirrorFoundation

extension ExportService {
    @MainActor
    static func exportOpenAPI(_ transactions: [Transaction]) {
        exportAPI(transactions, postman: false)
    }

    @MainActor
    static func exportPostman(_ transactions: [Transaction]) {
        exportAPI(transactions, postman: true)
    }

    @MainActor
    private static func exportAPI(_ transactions: [Transaction], postman: Bool) {
        guard !transactions.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = postman ? "proxymirror.postman_collection.json" : "openapi.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let records = transactions.map(SessionRecord.init)
        let redact = AppSettings.shared.redactSensitiveHeaders
        SessionFile.fileQueue.async {
            do {
                let object = postman ? buildPostman(records, redactSensitiveHeaders: redact)
                    : buildOpenAPI(records, redactSensitiveHeaders: redact)
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try PrivateAppFile.write(data, to: url)
            } catch {
                let message = Strings.Errors.exportServiceExportFailed(postman ? "Postman" : "OpenAPI", LocalizedErrorPresentation.message(for: error))
                DispatchQueue.main.async { AppState.shared.systemProxyMessage = message }
            }
        }
    }

    static func writeOpenAPI(_ records: [SessionRecord], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: buildOpenAPI(records), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateAppFile.write(data, to: url)
    }

    static func writePostman(_ records: [SessionRecord], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: buildPostman(records), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateAppFile.write(data, to: url)
    }

    static func buildOpenAPI(_ records: [SessionRecord], redactSensitiveHeaders: Bool? = nil) -> [String: Any] {
        let redact = redactSensitiveHeaders ?? AppSettings.shared.redactSensitiveHeaders
        return OpenAPIExporter.document(records.filter { !$0.isTunnel }.map { exchange($0, redact: redact, decode: true) })
    }

    static func buildPostman(_ records: [SessionRecord], redactSensitiveHeaders: Bool? = nil) -> [String: Any] {
        let redact = redactSensitiveHeaders ?? AppSettings.shared.redactSensitiveHeaders
        return PostmanCollectionExporter.document(records.filter { !$0.isTunnel }.map { exchange($0, redact: redact, decode: false) })
    }

    private static func exchange(_ record: SessionRecord, redact: Bool, decode: Bool) -> APIExchange {
        let transaction = record.transaction()
        func headers(_ value: HTTPHeaders) -> [(String, String)] {
            let source = value.pairs.map { ($0.name, $0.value) }
            return ExportRedaction.headers(source, redact: redact).enumerated().map { index, pair in
                // Preserve the scheme so OpenAPI can declare bearer security
                // and Postman can lift a shared placeholder into collection auth.
                if redact, pair.0.caseInsensitiveCompare("Authorization") == .orderedSame,
                   source[index].1.lowercased().hasPrefix("bearer ") { return (pair.0, "Bearer <redacted>") }
                return pair
            }
        }
        func body(_ data: Data, headers: HTTPHeaders) -> Data {
            var output = data
            if decode {
                let encodings = ContentCoding.inspectionEncodings(data, declared: headers.values(of: "Content-Encoding"))
                if case .success(let value)? = ContentCoding.decodeIfCompressed(data, encodings: encodings) { output = value.0 }
            }
            guard redact else { return output }
            if let text = String(data: output, encoding: .utf8) { return Data(MCPDataRedaction.text(text).utf8) }
            // Opaque data cannot be inspected for embedded credentials. Do not
            // publish a binary body while privacy redaction is enabled.
            return Data()
        }
        return APIExchange(method: record.method,
            url: redact ? MCPDataRedaction.text(transaction.fullURL) : transaction.fullURL,
            requestHeaders: headers(record.requestHeaders),
            requestBody: body(record.requestBody, headers: record.requestHeaders), status: record.statusCode,
            responseHeaders: headers(record.responseHeaders),
            responseBody: body(record.responseBody, headers: record.responseHeaders),
            requestComplete: record.requestBodyComplete && !record.requestTruncated,
            responseComplete: record.responseBodyComplete && !record.responseTruncated)
    }
}
