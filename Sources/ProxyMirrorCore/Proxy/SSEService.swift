import Foundation

/// SSE（text/event-stream）增量解析：按 W3C 事件流规范逐字节切行，
/// 支持 data 多行合并、event/id/retry 字段、冒号注释行，跨 chunk 断行续接。
/// 事件数与单事件大小有上限，超限丢弃并标记截断（用于调试查看，不参与转发）。
struct SSEEvent: Identifiable, Equatable {
    let index: Int
    let event: String       // 未声明时为 "message"
    let data: String        // 多行以 \n 连接
    let id: String?
    let retry: Int?
    let at: Date
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

    mutating func append<C: Collection>(_ bytes: C, at date: Date = Date()) where C.Element == UInt8 {
        guard !truncated else { return }
        for byte in bytes {
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
                }
            }
            if truncated { return }
        }
    }

    private mutating func processLine(_ line: String, at date: Date) {
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

    private mutating func dispatch(at date: Date) {
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
