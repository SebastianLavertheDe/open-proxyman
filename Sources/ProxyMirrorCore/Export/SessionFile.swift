import Foundation
import AppKit
import UniformTypeIdentifiers

struct SessionRecord: Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let seq: Int
    let state: TxState
    let method: String
    let scheme: String
    let host: String
    let port: Int
    let path: String
    let query: String
    let statusCode: Int
    let statusReason: String
    let errorText: String?
    let isTLSIntercepted: Bool
    let isTunnel: Bool
    let isWebSocket: Bool
    let websocketFrames: [WSFrame]?
    let hidden: Bool?
    let requestHeaders: HTTPHeaders
    let responseHeaders: HTTPHeaders
    let requestBody: Data
    let responseBody: Data
    let requestBytes: Int
    let responseBytes: Int
    let requestVersion: String
    let responseVersion: String
    let upstreamProtocol: String?
    let connectionDetails: ProxyConnectionDetails?
    let originalURL: String?
    let resolvedAddress: String?
    let isTransparent: Bool?
    let simulatedLatencyMs: Int?
    let requestTrailers: HTTPHeaders
    let responseTrailers: HTTPHeaders
    let requestBodyComplete: Bool
    let responseBodyComplete: Bool
    let requestTruncated: Bool
    let responseTruncated: Bool
    let contentType: String
    let duration: TimeInterval
    let comment: String
    let isFlagged: Bool
    let highlightName: String?
    let strikethrough: Bool
    let matchedByMapLocal: Bool
    let matchedByMapRemote: Bool
    let matchedByBlock: Bool
    let breakpointRules: [String]?
    let scriptingLogs: [String]?
    let clientName: String?
    let clientPID: Int32?
    let clientBundle: String?
    let isIOSSimulator: Bool?
    let clientAddress: String?
    let tConnected: Date?
    let tHeaderAt: Date?
    let sse: SSEInspectionSnapshot?

    init(_ tx: Transaction) {
        id = tx.id
        startedAt = tx.startedAt
        seq = tx.seq
        state = tx.state
        method = tx.method
        scheme = tx.scheme
        host = tx.host
        port = tx.port
        path = tx.path
        query = tx.query
        statusCode = tx.statusCode
        statusReason = tx.statusReason
        errorText = tx.errorText
        isTLSIntercepted = tx.isTLSIntercepted
        isTunnel = tx.isTunnel
        isWebSocket = tx.isWebSocket
        let payload = tx.capturedPayloadSnapshot()
        websocketFrames = payload.frames.isEmpty ? nil : payload.frames
        hidden = tx.hideFromList ? true : nil
        requestHeaders = tx.requestHeaders
        responseHeaders = tx.responseHeaders
        requestBody = payload.request
        responseBody = payload.response
        requestBytes = payload.requestBytes
        responseBytes = payload.responseBytes
        requestVersion = tx.requestVersion
        responseVersion = tx.responseVersion
        upstreamProtocol = tx.upstreamProtocol
        connectionDetails = tx.connectionDetails
        originalURL = tx.originalURL
        resolvedAddress = tx.resolvedAddress
        isTransparent = tx.isTransparent ? true : nil
        simulatedLatencyMs = tx.simulatedLatencyMs
        requestTrailers = tx.requestTrailers
        responseTrailers = tx.responseTrailers
        requestBodyComplete = tx.requestBodyComplete
        responseBodyComplete = tx.responseBodyComplete
        requestTruncated = payload.requestTruncated
        responseTruncated = payload.responseTruncated
        contentType = tx.contentType
        duration = tx.duration
        comment = tx.comment
        isFlagged = tx.isFlagged
        highlightName = tx.highlightName
        strikethrough = tx.strikethrough
        matchedByMapLocal = tx.matchedByMapLocal
        matchedByMapRemote = tx.matchedByMapRemote
        matchedByBlock = tx.matchedByBlock
        breakpointRules = tx.breakpointRules.isEmpty ? nil : tx.breakpointRules
        scriptingLogs = tx.scriptingLogs.isEmpty ? nil : tx.scriptingLogs
        clientName = tx.clientName
        clientPID = tx.clientPID
        clientBundle = tx.clientBundle
        isIOSSimulator = tx.isIOSSimulator ? true : nil
        clientAddress = tx.clientAddress
        tConnected = tx.tConnected
        tHeaderAt = tx.tHeaderAt
        sse = tx.isSSE ? SSEInspectionSnapshot(transaction: tx) : nil
    }

    func transaction() -> Transaction {
        let tx = Transaction(id: id, startedAt: startedAt)
        tx.seq = seq
        tx.state = state
        tx.method = method
        tx.scheme = scheme
        tx.host = host
        tx.port = port
        tx.path = path
        tx.query = query
        tx.statusCode = statusCode
        tx.statusReason = statusReason
        tx.errorText = errorText
        tx.isTLSIntercepted = isTLSIntercepted
        tx.isTunnel = isTunnel
        tx.isWebSocket = isWebSocket
        tx.websocketFrames = websocketFrames ?? []
        tx.hideFromList = hidden == true
        tx.requestHeaders = requestHeaders
        tx.responseHeaders = responseHeaders
        tx.requestBody = requestBody
        tx.responseBody = responseBody
        tx.requestBytes = requestBytes
        tx.responseBytes = responseBytes
        tx.requestVersion = requestVersion
        tx.responseVersion = responseVersion
        tx.upstreamProtocol = upstreamProtocol
        tx.connectionDetails = connectionDetails
        tx.originalURL = originalURL
        tx.resolvedAddress = resolvedAddress
        tx.isTransparent = isTransparent ?? false
        tx.simulatedLatencyMs = simulatedLatencyMs
        tx.requestTrailers = requestTrailers
        tx.responseTrailers = responseTrailers
        tx.requestBodyComplete = requestBodyComplete
        tx.responseBodyComplete = responseBodyComplete
        tx.requestTruncated = requestTruncated
        tx.responseTruncated = responseTruncated
        tx.contentType = contentType
        tx.duration = duration
        tx.comment = comment
        tx.isFlagged = isFlagged
        tx.highlightName = highlightName
        tx.strikethrough = strikethrough
        tx.matchedByMapLocal = matchedByMapLocal
        tx.matchedByMapRemote = matchedByMapRemote
        tx.matchedByBlock = matchedByBlock
        tx.breakpointRules = breakpointRules ?? []
        tx.scriptingLogs = scriptingLogs ?? []
        tx.clientName = clientName
        tx.clientPID = clientPID
        tx.clientBundle = clientBundle
        tx.isIOSSimulator = isIOSSimulator ?? false
        tx.clientAddress = clientAddress
        tx.tConnected = tConnected
        tx.tHeaderAt = tHeaderAt
        if let sse { tx.applySSESnapshot(sse) }
        else if tx.isSSE { tx.restoreSSEFromBody() }
        return tx
    }
}

struct SessionFile: Codable, Sendable {
    enum SessionError: LocalizedError, OperationIssueProviding {
        case unsupportedVersion, duplicateIDs, invalidHAR

        var operationIssue: OperationIssue {
            switch self {
            case .unsupportedVersion: return OperationIssue.modelSessionUnsupportedVersion
            case .duplicateIDs: return OperationIssue.modelSessionDuplicateIds
            case .invalidHAR: return OperationIssue.modelSessionHarInvalid
            }
        }
        var errorDescription: String? { operationIssue.diagnostic }
    }

    static let currentVersion = 2
    static let fileExtension = "proxymirror"
    static let fileQueue = DispatchQueue(label: "proxymirror.session-files", qos: .userInitiated)
    let version: Int
    let records: [SessionRecord]
    let pinnedDomains: [String]
    let selected: [UUID]

    init(transactions: [Transaction], pinnedDomains: [String], selected: Set<UUID>) {
        version = Self.currentVersion
        records = transactions.map(SessionRecord.init)
        self.pinnedDomains = pinnedDomains
        self.selected = records.map(\.id).filter(selected.contains)
    }

    static func decode(_ data: Data) throws -> SessionFile {
        let decoder = JSONDecoder()
        let header = try decoder.decode(ImportHeader.self, from: data)
        if header.format == "proxymirror-domain-logs" {
            let bundle = try decoder.decode(DomainLogs.self, from: data)
            guard bundle.version == 1 else { throw SessionError.unsupportedVersion }
            var records: [SessionRecord] = bundle.sessions.flatMap { $0.session.records }
            records.sort { (left: SessionRecord, right: SessionRecord) -> Bool in
                if left.startedAt == right.startedAt { return left.seq < right.seq }
                return left.startedAt < right.startedAt
            }
            let recordIDs: [UUID] = records.map { $0.id }
            guard Set(recordIDs).count == records.count else { throw SessionError.duplicateIDs }
            var pins = Set<String>(), selection = Set<UUID>()
            let pinnedDomains = bundle.sessions.flatMap { $0.session.pinnedDomains }.filter { pins.insert($0).inserted }
            for group in bundle.sessions { selection.formUnion(group.session.selected) }
            let selectedIDs: [UUID] = recordIDs.filter { selection.contains($0) }
            return Self(records: records, pinnedDomains: pinnedDomains, selected: selectedIDs)
        }
        return try decoder.decode(Self.self, from: data)
    }

    private struct ImportHeader: Decodable { let format: String? }
    private struct DomainLogs: Decodable {
        struct Group: Decodable { let domain: String; let session: SessionFile }
        let version: Int
        let sessions: [Group]
    }

    private init(records: [SessionRecord], pinnedDomains: [String], selected: [UUID]) {
        version = Self.currentVersion; self.records = records; self.pinnedDomains = pinnedDomains; self.selected = selected
    }

    private enum CodingKeys: String, CodingKey { case version, records, pinnedDomains, selected }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw SessionError.unsupportedVersion }
        records = try fields.decode([SessionRecord].self, forKey: .records)
        guard Set(records.map(\.id)).count == records.count else { throw SessionError.duplicateIDs }
        pinnedDomains = try fields.decode([String].self, forKey: .pinnedDomains)
        selected = try fields.decode([UUID].self, forKey: .selected)
    }

    @MainActor
    func save() throws {
        if let url = Self.selectSaveFile() { try write(to: url, redactSensitiveHeaders: AppSettings.shared.redactSensitiveHeaders) }
    }

    func exportData(redactSensitiveHeaders: Bool = false) throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard redactSensitiveHeaders,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        return try JSONSerialization.data(withJSONObject: ExportRedaction.har(object))
    }

    func write(to url: URL, redactSensitiveHeaders: Bool = false) throws {
        try PrivateAppFile.write(exportData(redactSensitiveHeaders: redactSensitiveHeaders), to: url)
    }

    @MainActor
    static func selectSaveFile() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Session.\(Self.fileExtension)"
        if let type = UTType(filenameExtension: Self.fileExtension) { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func selectFile(extensions: [String] = [fileExtension, "har", "xml", "chlsx", "chlsj", "chls", "chlz"]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func importHAR(_ data: Data) throws -> [Transaction] {
        let har = try JSONDecoder().decode(HARFile.self, from: data)
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try har.log.entries.enumerated().map { index, entry in
            guard let target = URLParser.parse(target: entry.request.url), let host = target.host,
                  let scheme = target.scheme else { throw SessionError.invalidHAR }
            let date = entry.startedDateTime.flatMap { fractional.date(from: $0) ?? iso.date(from: $0) }
            let tx = Transaction(startedAt: date ?? Date())
            tx.seq = index + 1
            tx.method = entry.request.method
            tx.scheme = scheme
            tx.host = host
            tx.port = target.port
            (tx.path, tx.query) = splitQueryPath(target.path)
            tx.originalURL = entry._originalURL
            tx.requestHeaders = entry.request.headers ?? HTTPHeaders()
            tx.responseHeaders = entry.response.headers ?? HTTPHeaders()
            tx.requestTrailers = entry.request._trailers ?? HTTPHeaders()
            tx.responseTrailers = entry.response._trailers ?? HTTPHeaders()
            tx.requestVersion = entry.request.httpVersion ?? ""
            tx.responseVersion = entry.response.httpVersion ?? ""
            tx.upstreamProtocol = entry._upstreamProtocol
            tx.requestBody = try entry.request.postData?.bytes() ?? Data()
            tx.responseBody = try entry.response.content?.bytes() ?? Data()
            tx.requestBytes = max(entry.request.bodySize ?? 0, tx.requestBody.count)
            tx.responseBytes = max(entry.response.bodySize ?? 0, tx.responseBody.count)
            tx.requestBodyComplete = true
            let error = entry.response._error.flatMap { $0.isEmpty ? nil : $0 }
            tx.responseBodyComplete = error == nil
            tx.requestTruncated = entry.request._truncated == true || tx.requestBody.count < tx.requestBytes
            tx.responseTruncated = entry.response._truncated == true || tx.responseBody.count < tx.responseBytes
            tx.statusCode = entry.response.status
            tx.statusReason = entry.response.statusText ?? ""
            tx.errorText = error
            tx.state = tx.errorText == nil && tx.statusCode > 0 ? .completed : .failed
            tx.isTunnel = tx.method == "CONNECT"
            tx.isWebSocket = tx.statusCode == 101
            tx.contentType = entry.response.content?.mimeType ?? tx.responseHeaders.value(of: "Content-Type") ?? ""
            tx.duration = max(0, entry.time ?? 0) / 1000
            tx.comment = entry.comment ?? ""
            if tx.isSSE { tx.restoreSSEFromBody() }
            return tx
        }
    }
}

private struct HARFile: Decodable {
    struct Log: Decodable { let entries: [Entry] }
    struct Entry: Decodable {
        let startedDateTime: String?
        let time: Double?
        let request: Request
        let response: Response
        let comment: String?
        let _originalURL: String?
        let _upstreamProtocol: String?
    }
    struct Request: Decodable {
        let url: String
        let method: String
        let headers: HTTPHeaders?
        let httpVersion: String?
        let bodySize: Int?
        let postData: Content?
        let _truncated: Bool?
        let _trailers: HTTPHeaders?
    }
    struct Response: Decodable {
        let status: Int
        let statusText: String?
        let headers: HTTPHeaders?
        let httpVersion: String?
        let bodySize: Int?
        let content: Content?
        let _error: String?
        let _truncated: Bool?
        let _trailers: HTTPHeaders?
    }
    struct Content: Decodable {
        let mimeType: String?
        let text: String?
        let encoding: String?
        let _encoding: String?

        func bytes() throws -> Data {
            guard let text else { return Data() }
            if (encoding ?? _encoding) == "base64" {
                guard let data = Data(base64Encoded: text) else { throw SessionFile.SessionError.invalidHAR }
                return data
            }
            return Data(text.utf8)
        }
    }
    let log: Log
}
