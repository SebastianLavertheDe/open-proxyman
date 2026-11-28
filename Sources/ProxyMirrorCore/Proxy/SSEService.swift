import Foundation
import ProxyMirrorFoundation
import zlib

/// SSE（text/event-stream）增量解析：按 W3C 事件流规范逐字节切行，
/// 支持 data 多行合并、event/id/retry 字段、冒号注释行，跨 chunk 断行续接。
/// 事件数与单事件大小有上限，超限丢弃并标记截断（用于调试查看，不参与转发）。
struct SSEEvent: Codable, Equatable, Sendable {
    let index: Int
    let event: String       // 未声明时为 "message"
    let data: String        // 多行以 \n 连接
    let id: String?
    let retry: Int?
    /// nil when restored from a body that did not retain per-event arrival times.
    let at: Date?
}

struct SSEStreamState {
    private(set) var events: [SSEEvent] = []
    private(set) var truncated = false
    private var pending = Data()            // 未凑齐整行的字节
    private var dataLines: [String] = []
    private var dataBytes = 0
    private var discardEvent = false
    private var discardLine = false
    private var firstLine = true
    private var retainedBytes = 0
    private var declaredEvent: String?
    private var declaredRetry: Int?
    private var lastID: String?
    private var afterCR = false

    static let maxEvents = 2_000
    static let maxDataPerEvent = 64 * 1024
    static let maxPendingBytes = 64 * 1024
    static let maxRetainedBytes = 1024 * 1024

    static func matches(_ contentType: String) -> Bool {
        contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/event-stream"
    }

    mutating func append<C: Collection>(_ bytes: C, at date: Date? = Date()) where C.Element == UInt8 {
        guard !truncated else { return }
        for (offset, byte) in bytes.enumerated() {
            if offset & 0x3fff == 0, Task.isCancelled { return }
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue }
            }
            if byte == 0x0A || byte == 0x0D {
                if !discardLine {
                    let line = String(decoding: pending, as: UTF8.self)
                    processLine(firstLine && line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line, at: date)
                }
                firstLine = false
                discardLine = false
                pending.removeAll(keepingCapacity: true)
                afterCR = byte == 0x0D
            } else if !discardLine {
                if pending.count < Self.maxPendingBytes {
                    pending.append(byte)
                } else {
                    pending.removeAll(keepingCapacity: true)
                    discardLine = true
                    discardEvent = true
                    truncated = true
                }
            }
            if truncated { return }
        }
    }

    private mutating func processLine(_ line: String, at date: Date?) {
        if line.isEmpty {
            dispatch(at: date)
            return
        }
        if line.hasPrefix(":") { return }        // 注释
        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            value = String(rest)
        } else {
            field = line
            value = ""
        }
        switch field {
        case "data":
            let size = value.utf8.count + 1
            if !discardEvent && size <= Self.maxDataPerEvent - dataBytes {
                dataLines.append(value)
                dataBytes += size
            } else {
                discardEvent = true
                truncated = true
            }
        case "event":
            declaredEvent = value
        case "id":
            if !value.utf8.contains(0) { lastID = value }
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) {
                if let retry = Int(value) { declaredRetry = retry }
            }
        default:
            break
        }
    }

    private mutating func dispatch(at date: Date?) {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            dataBytes = 0
            discardEvent = false
            declaredEvent = nil
        }
        guard !discardEvent, !dataLines.isEmpty else { return }
        let size = dataBytes + (declaredEvent?.utf8.count ?? 0) + (lastID?.utf8.count ?? 0)
        guard events.count < Self.maxEvents, size <= Self.maxRetainedBytes - retainedBytes else {
            truncated = true
            return
        }
        retainedBytes += size
        let event = declaredEvent.flatMap { $0.isEmpty ? nil : $0 } ?? "message"
        events.append(SSEEvent(index: events.count, event: event,
                               data: dataLines.joined(separator: "\n"), id: lastID,
                               retry: declaredRetry, at: date))
    }
}

/// Stored alongside the captured body, so Saved and sessions retain actual arrival times.
struct SSEInspectionSnapshot: Codable, Sendable {
    var events: [SSEEvent]
    var truncated: Bool
    var issue: CapturedFailure?
    var deferred: Bool

    init(events: [SSEEvent], truncated: Bool = false, issue: CapturedFailure? = nil, deferred: Bool = false) {
        self.events = events
        self.truncated = truncated
        self.issue = issue
        self.deferred = deferred
    }

    init(transaction: Transaction) {
        events = transaction.sseEvents
        truncated = transaction.sseEventsTruncated
        issue = transaction.sseParseIssue
        deferred = transaction.sseDecodingDeferred
    }

    private enum CodingKeys: String, CodingKey { case events, truncated, issue, deferred }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decode([SSEEvent].self, forKey: .events)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        deferred = try container.decode(Bool.self, forKey: .deferred)
        if let legacy = try? container.decode(String.self, forKey: .issue) {
            issue = Self.legacyIssue(legacy)
        } else {
            issue = try container.decodeIfPresent(CapturedFailure.self, forKey: .issue)
        }
    }

    /// Previous sessions stored rendered Chinese text. Migrate only our exact
    /// known messages; unrelated diagnostics must remain the original content.
    private static func legacyIssue(_ diagnostic: String) -> CapturedFailure {
        let known: [(String, OperationIssue)] = [
            ("SSE 正文超过 32 MiB 解析上限，后续事件未解析。", .sseBodyOutputLimit),
            ("连接已结束，未完整接收 SSE 压缩正文，无法恢复事件。可在原文查看捕获字节。", .sseBodyIncomplete),
            ("连接已结束，未完整接收 SSE 压缩正文，无法恢复事件。", .sseBodyIncomplete),
            ("SSE 压缩正文不完整，已显示可恢复的事件。", .sseCompressedBodyIncomplete),
            ("无法初始化 SSE 压缩解码。", .sseDecoderInitializationFailed),
            ("SSE 压缩正文包含多余数据。", .sseCompressedBodyExtraData),
            ("SSE 压缩正文损坏，已显示可恢复的事件。", .sseCompressedBodyInvalid),
            ("SSE 压缩正文已截断，无法完整解码。", .sseCompressedBodyTruncated),
            ("SSE 解压正文超过 32 MiB。", .sseCompressedBodyOutputLimit),
            ("无法解码 SSE 压缩正文。可在原文查看捕获字节。", .sseDecodeFailed),
            ("没有可解码的 SSE 正文。", .sseNoDecodableBody),
        ]
        var matched = known.first { $0.0 == diagnostic }?.1
        let deferredPrefix = "SSE 的 ", deferredSuffix = " 正文将在接收完成后解析。"
        let unsupportedPrefix = "暂不支持 SSE Content-Encoding: ", unsupportedSuffix = "。可在原文查看捕获字节。"
        if diagnostic.hasPrefix(deferredPrefix), diagnostic.hasSuffix(deferredSuffix) {
            matched = .sseDecodingDeferred(String(diagnostic.dropFirst(deferredPrefix.count).dropLast(deferredSuffix.count)))
        } else if diagnostic.hasPrefix(unsupportedPrefix), diagnostic.hasSuffix(unsupportedSuffix) {
            matched = .sseEncodingUnsupported(String(diagnostic.dropFirst(unsupportedPrefix.count).dropLast(unsupportedSuffix.count)))
        }
        guard let matched else { return CapturedFailure(code: "external_detail", diagnostic: diagnostic) }
        return CapturedFailure(code: matched.code, arguments: matched.arguments, diagnostic: diagnostic)
    }
}

/// Only the owning capture loop mutates this parser. gzip/deflate emit events as
/// bytes arrive; other supported encodings are decoded once the body is complete.
final class SSEBodyStream {
    private var parser = SSEStreamState()
    private let inflater: SSEIncrementalInflater?
    private(set) var issue: CapturedFailure?
    private(set) var deferred: Bool
    private var decodedBytes = 0
    private static let decodedLimit = ContentCoding.maxDecodedBytes

    init(headers: HTTPHeaders) {
        let encodings = Self.encodings(headers)
        if encodings.isEmpty {
            inflater = nil
            deferred = false
        } else if encodings.count == 1, encodings[0] == "gzip" || encodings[0] == "deflate" {
            inflater = SSEIncrementalInflater(gzip: encodings[0] == "gzip")
            deferred = false
        } else {
            inflater = nil
            deferred = encodings.allSatisfy { ContentCoding.supported.contains($0) }
            issue = (deferred ? OperationIssue.sseDecodingDeferred(encodings.joined(separator: ", "))
                : .sseEncodingUnsupported(encodings.joined(separator: ", "))).capturedFailure
        }
    }

    static func encodings(_ headers: HTTPHeaders) -> [String] {
        headers.values(of: "content-encoding").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
    }

    var snapshot: SSEInspectionSnapshot {
        SSEInspectionSnapshot(events: parser.events, truncated: parser.truncated,
                              issue: issue, deferred: deferred)
    }

    func append<C: Collection>(_ bytes: C, at date: Date? = Date()) where C.Element == UInt8 {
        guard issue == nil, !parser.truncated else { return }
        do {
            if let inflater {
                try inflater.append(Data(bytes)) { decoded in
                    try self.accept(decoded, at: date)
                }
            } else {
                try accept(Data(bytes), at: date)
            }
        } catch {
            issue = NetworkFailure.capture(error)
        }
    }

    private func accept(_ bytes: Data, at date: Date?) throws {
        try Task.checkCancellation()
        guard bytes.count <= Self.decodedLimit - decodedBytes else {
            throw NetworkFailure(.sseBodyOutputLimit)
        }
        decodedBytes += bytes.count
        parser.append(bytes, at: date)
    }

    func finish(complete: Bool = true) {
        if deferred, !complete {
            deferred = false
            issue = OperationIssue.sseBodyIncomplete.capturedFailure
        } else if issue == nil, !parser.truncated, let inflater, !inflater.finished {
            issue = OperationIssue.sseCompressedBodyIncomplete.capturedFailure
        }
    }
}

private final class SSEIncrementalInflater {
    private var stream = z_stream()
    private let gzip: Bool
    private var initialized = false
    private var prefix = Data()
    private var mayRetryRaw = false
    private var retryInput = Data()
    private(set) var finished = false

    init(gzip: Bool) { self.gzip = gzip }
    deinit { if initialized { inflateEnd(&stream) } }

    private func initialize(window: Int32) throws {
        guard inflateInit2_(&stream, window, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NetworkFailure(.sseDecoderInitializationFailed)
        }
        initialized = true
    }

    func append(_ data: Data, emit: (Data) throws -> Void) throws {
        var input = data
        if !initialized {
            prefix.append(data)
            guard prefix.count >= 2 else { return }
            input = prefix
            prefix = Data()
            let wrapped = input[input.startIndex] & 0x0f == 8 &&
                (Int(input[input.startIndex]) * 256 + Int(input[input.startIndex + 1])) % 31 == 0
            try initialize(window: gzip ? MAX_WBITS + 16 : (wrapped ? MAX_WBITS : -MAX_WBITS))
            mayRetryRaw = !gzip && wrapped
        }
        if finished {
            guard gzip, inflateReset2(&stream, MAX_WBITS + 16) == Z_OK else {
                throw NetworkFailure(.sseCompressedBodyExtraData)
            }
            finished = false
        }
        if mayRetryRaw {
            if retryInput.isEmpty { retryInput = input }
            else if input.count <= 1024 * 1024 - retryInput.count { retryInput.append(input) }
            else { mayRetryRaw = false; retryInput = Data() }
        }
        do {
            try decode(input) { bytes in
                // Retrying after publishing bytes could duplicate or corrupt events.
                self.mayRetryRaw = false
                self.retryInput = Data()
                try emit(bytes)
            }
            if finished { mayRetryRaw = false; retryInput = Data() }
        } catch {
            guard mayRetryRaw else { throw error }
            let original = retryInput
            mayRetryRaw = false
            retryInput = Data()
            inflateEnd(&stream)
            initialized = false
            stream = z_stream()
            try initialize(window: -MAX_WBITS)
            try decode(original, emit: emit)
        }
    }

    private func decode(_ input: Data, emit: (Data) throws -> Void) throws {
        try input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            defer { stream.next_in = nil; stream.next_out = nil }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let before = stream.avail_in
                let status = buffer.withUnsafeMutableBufferPointer { output in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                if count > 0 { try emit(Data(buffer.prefix(count))) }
                if status == Z_STREAM_END {
                    finished = true
                    if stream.avail_in == 0 { return }
                    guard gzip, inflateReset2(&stream, MAX_WBITS + 16) == Z_OK else {
                        throw NetworkFailure(.sseCompressedBodyExtraData)
                    }
                    finished = false
                } else if status == Z_BUF_ERROR, stream.avail_in == 0, count == 0 {
                    return
                } else {
                    guard status == Z_OK, count > 0 || stream.avail_in < before else {
                        throw NetworkFailure(.sseCompressedBodyInvalid)
                    }
                    if stream.avail_in == 0, stream.avail_out > 0 { return }
                }
            }
        }
    }
}

enum SSEBodyRecovery {
    static func recover(_ data: Data, headers: HTTPHeaders, complete: Bool, truncated: Bool,
                        failed: Bool = false) -> SSEInspectionSnapshot {
        let stream = SSEBodyStream(headers: headers)
        if stream.deferred {
            guard complete, !truncated else {
                return SSEInspectionSnapshot(events: [], truncated: truncated,
                    issue: truncated ? OperationIssue.sseCompressedBodyTruncated.capturedFailure :
                        failed ? OperationIssue.sseBodyIncomplete.capturedFailure : stream.issue,
                    deferred: !truncated && !failed)
            }
            switch ContentCoding.decodeIfCompressed(data, encodings: SSEBodyStream.encodings(headers)) {
            case .success(let decoded):
                var parser = SSEStreamState()
                parser.append(decoded.0, at: nil)
                return SSEInspectionSnapshot(events: parser.events, truncated: parser.truncated)
            case .failure(.outputLimit):
                return SSEInspectionSnapshot(events: [], issue: OperationIssue.sseCompressedBodyOutputLimit.capturedFailure)
            case .failure:
                return SSEInspectionSnapshot(events: [], issue: OperationIssue.sseDecodeFailed.capturedFailure)
            case nil:
                return SSEInspectionSnapshot(events: [], issue: OperationIssue.sseNoDecodableBody.capturedFailure)
            }
        }
        stream.append(data, at: nil)
        if complete { stream.finish() }
        var snapshot = stream.snapshot
        snapshot.truncated = snapshot.truncated || truncated
        return snapshot
    }
}

extension Transaction {
    func applySSESnapshot(_ snapshot: SSEInspectionSnapshot, preservingArrivalTimes: Bool = false) {
        let previous = preservingArrivalTimes ? Dictionary(sseEvents.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        sseEvents = snapshot.events.map { event in
            guard let original = previous[event.index], original.event == event.event,
                  original.data == event.data, original.id == event.id, original.retry == event.retry else { return event }
            return SSEEvent(index: event.index, event: event.event, data: event.data,
                            id: event.id, retry: event.retry, at: original.at)
        }
        sseEventsTruncated = snapshot.truncated
        sseParseIssue = snapshot.issue
        sseDecodingDeferred = snapshot.deferred
    }

    func restoreSSEFromBody() {
        guard isSSE else { return }
        applySSESnapshot(SSEBodyRecovery.recover(responseBody, headers: responseHeaders,
            complete: responseBodyComplete, truncated: responseTruncated, failed: state == .failed))
    }
}
