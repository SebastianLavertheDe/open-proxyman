import Foundation

// MARK: - HTTP 模型

public enum HTTPMethod: String, CaseIterable, Sendable {
    case GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT
}

/// HTTP 头部列表（保持顺序，大小写不敏感查找）
public struct HTTPHeaders: Sendable, Codable {
    public private(set) var pairs: [(name: String, value: String)] = []

    public init() {}
    public init(_ pairs: [(String, String)]) {
        self.pairs = pairs.map { ($0.0, $0.1) }
    }

    private struct Field: Codable {
        let name: String
        let value: String
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.singleValueContainer().decode([Field].self)
        self.init(fields.map { ($0.name, $0.value) })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pairs.map { Field(name: $0.name, value: $0.value) })
    }

    public var count: Int { pairs.count }

    public mutating func append(_ name: String, _ value: String) {
        pairs.append((name, value))
    }

    public func value(of name: String) -> String? {
        let lower = name.lowercased()
        return pairs.first { $0.name.lowercased() == lower }?.value
    }

    public func values(of name: String) -> [String] {
        let lower = name.lowercased()
        return pairs.filter { $0.name.lowercased() == lower }.map { $0.value }
    }

    public func contains(_ name: String) -> Bool {
        value(of: name) != nil
    }

    public mutating func remove(name: String) {
        let lower = name.lowercased()
        pairs.removeAll { $0.name.lowercased() == lower }
    }

    public mutating func set(name: String, value: String) {
        remove(name: name)
        append(name, value)
    }

    public var rawBytes: Data {
        var out = Data()
        for p in pairs {
            out.append(p.name.data(using: .utf8)!)
            out.append(Data(": ".utf8))
            out.append(p.value.data(using: .utf8)!)
            out.append(Data("\r\n".utf8))
        }
        return out
    }
}

public struct HTTPRequestHead: Sendable {
    public var method: String
    public var target: String
    public var version: String   // "HTTP/1.1"
    public var headers: HTTPHeaders

    public init(method: String, target: String, version: String, headers: HTTPHeaders) {
        self.method = method; self.target = target; self.version = version; self.headers = headers
    }
}

public struct HTTPResponseHead: Sendable {
    public var version: String
    public var status: Int
    public var reason: String
    public var headers: HTTPHeaders

    public init(version: String, status: Int, reason: String, headers: HTTPHeaders) {
        self.version = version; self.status = status; self.reason = reason; self.headers = headers
    }
}

// MARK: - 解析错误

public enum HTTPParseError: Error, Sendable {
    case incomplete
    case malformed(String)
}

// MARK: - CRLF 扫描

@inline(__always)
func findCRLFCRLF(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    for i in 0...(bytes.count - 4) {
        if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
            return i
        }
    }
    return nil
}

// MARK: - 请求头解析器（增量；记录头部之后的残留字节）

public struct RequestHeadParser: Sendable {
    private var buffer: [UInt8] = []
    private var done = false
    private let maxHeadSize = 128 * 1024
    /// 头部结束后、同一 feed 中的剩余字节（请求 body 的开头）
    public private(set) var trailing: [UInt8] = []

    public init() {}

    public var isComplete: Bool { done }

    public mutating func feed(_ data: Data) throws -> HTTPRequestHead? {
        precondition(!done)
        buffer.append(contentsOf: data)
        guard let idx = findCRLFCRLF(buffer) else {
            if buffer.count > maxHeadSize { throw HTTPParseError.malformed("请求头过大") }
            return nil
        }
        guard idx <= maxHeadSize else { throw HTTPParseError.malformed("请求头过大") }
        done = true
        let head = try Self.parse(String(decoding: buffer[0..<idx], as: UTF8.self))
        trailing = Array(buffer[(idx + 4)...])
        buffer = []
        return head
    }

    public static func parse(_ text: String) throws -> HTTPRequestHead {
        var lines = text.components(separatedBy: "\r\n")
        if lines.isEmpty { throw HTTPParseError.malformed("空请求") }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { throw HTTPParseError.malformed("非法请求行: \(requestLine)") }
        var headers = HTTPHeaders()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append(name, value)
        }
        return HTTPRequestHead(method: parts[0].uppercased(), target: parts[1], version: parts[2], headers: headers)
    }
}

// MARK: - 响应头解析器（增量）

public struct ResponseHeadParser: Sendable {
    private var buffer: [UInt8] = []
    private var done = false
    private let maxHeadSize = 128 * 1024
    public private(set) var trailing: [UInt8] = []

    public init() {}

    public var isComplete: Bool { done }

    public mutating func feed(_ data: Data) throws -> HTTPResponseHead? {
        precondition(!done)
        buffer.append(contentsOf: data)
        guard let idx = findCRLFCRLF(buffer) else {
            if buffer.count > maxHeadSize { throw HTTPParseError.malformed("响应头过大") }
            return nil
        }
        guard idx <= maxHeadSize else { throw HTTPParseError.malformed("响应头过大") }
        done = true
        let head = try Self.parse(String(decoding: buffer[0..<idx], as: UTF8.self))
        trailing = Array(buffer[(idx + 4)...])
        buffer = []
        return head
    }

    public static func parse(_ text: String) throws -> HTTPResponseHead {
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformed("空响应") }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw HTTPParseError.malformed("非法状态行: \(statusLine)")
        }
        var headers = HTTPHeaders()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append(name, value)
        }
        return HTTPResponseHead(version: parts[0], status: status, reason: parts.count > 2 ? parts[2] : "", headers: headers)
    }
}

// MARK: - Body framing（chunked）

/// 追踪 chunked 编码流的进度（透传场景只判断边界，不重组）
public struct ChunkedTracker: Sendable {
    private enum Phase: Sendable { case size, data(Int), delimiter(Int), trailer }
    public private(set) var finished = false
    private(set) var trailers = HTTPHeaders()
    private var line: [UInt8] = []
    private var phase = Phase.size
    private var trailerBytes = 0

    public init() {}

    public mutating func feed(_ data: Data) -> Bool {
        _ = try? consume(data, onPayload: { _ in })
        return finished
    }

    mutating func consume(_ data: Data) throws -> (wireBytes: Int, payload: Data) {
        var payload = Data()
        let wireBytes = try consume(data) { payload.append(contentsOf: $0) }
        return (wireBytes, payload)
    }

    /// Visits only the decoded body ranges, without copying the wire buffer or its payload.
    mutating func consume<C: RandomAccessCollection>(_ data: C, onPayload: (C.SubSequence) -> Void) throws -> Int
    where C.Element == UInt8 {
        var cursor = data.startIndex
        while cursor < data.endIndex, !finished {
            switch phase {
            case .size, .trailer:
                let byte = data[cursor]
                data.formIndex(after: &cursor)
                line.append(byte)
                guard line.count <= 8192 else { throw HTTPParseError.malformed("Chunk line too long") }
                guard byte == 10 else { continue }
                guard line.count >= 2, line[line.count - 2] == 13 else {
                    throw HTTPParseError.malformed("Invalid chunk line ending")
                }
                let value = String(decoding: line.dropLast(2), as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if case .size = phase {
                    let hex = value.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
                    guard !hex.isEmpty, hex.utf8.allSatisfy({
                        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    }), let size = Int(hex, radix: 16) else {
                        throw HTTPParseError.malformed("Invalid chunk size")
                    }
                    phase = size == 0 ? .trailer : .data(size)
                } else if value.isEmpty {
                    finished = true
                } else {
                    trailerBytes += value.utf8.count
                    guard trailerBytes <= 65536, let colon = value.firstIndex(of: ":") else {
                        throw HTTPParseError.malformed("Invalid chunk trailer")
                    }
                    trailers.append(String(value[..<colon]), value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
            case .data(let remaining):
                let count = min(remaining, data.distance(from: cursor, to: data.endIndex))
                let end = data.index(cursor, offsetBy: count)
                onPayload(data[cursor..<end])
                cursor = end
                phase = count == remaining ? .delimiter(0) : .data(remaining - count)
            case .delimiter(let count):
                guard data[cursor] == (count == 0 ? 13 : 10) else {
                    throw HTTPParseError.malformed("Invalid chunk delimiter")
                }
                data.formIndex(after: &cursor)
                phase = count == 0 ? .delimiter(1) : .size
            }
        }
        return data.distance(from: data.startIndex, to: cursor)
    }
}

@inline(__always)
func findCRLF(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 2 else { return nil }
    for i in 0...(bytes.count - 2) {
        if bytes[i] == 13, bytes[i + 1] == 10 { return i }
    }
    return nil
}

// MARK: - 工具

/// 把 absolute-form 请求行转换成 origin-form，并清理代理专用头
public func sanitizedRequestHead(head: HTTPRequestHead, originFormTarget: String, keepAlive: Bool) -> Data {
    var headers = head.headers
    headers.remove(name: "Proxy-Connection")
    headers.remove(name: "Proxy-Authorization")
    headers.remove(name: "Proxy-Authenticate")
    headers.remove(name: "Keep-Alive")
    let connLower = headers.value(of: "Connection")?.lowercased() ?? ""
    if connLower.contains("upgrade") {
        // WebSocket 升级：保留 Connection 头原样
    } else if keepAlive {
        headers.set(name: "Connection", value: "keep-alive")
    } else {
        headers.set(name: "Connection", value: "close")
    }
    var out = Data("\(head.method) \(originFormTarget) \(head.version)\r\n".utf8)
    out.append(headers.rawBytes)
    out.append(Data("\r\n".utf8))
    return out
}

public struct URLParser {
    /// 支持 absolute-form (http://host:port/path) 与 origin-form (/path)
    public static func parse(target: String) -> (scheme: String?, host: String?, port: Int, path: String)? {
        if target.lowercased().hasPrefix("http://") || target.lowercased().hasPrefix("https://") {
            guard let url = URLComponents(string: target), let host = url.host,
                  let scheme = url.scheme?.lowercased() else { return nil }
            let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
            return (scheme, bareHost(host), url.port ?? (scheme == "https" ? 443 : 80),
                    path + (url.percentEncodedQuery.map { "?" + $0 } ?? ""))
        }
        let path = target.isEmpty ? "/" : target
        return (nil, nil, 80, path)
    }

    public static func isIPAddress(_ host: String) -> Bool {
        var addr = in_addr()
        var addr6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
            || host.withCString { inet_pton(AF_INET6, $0, &addr6) == 1 }
    }

    static func bareHost(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    static func authority(host: String, port: Int, scheme: String) -> String {
        let host = bareHost(host)
        let address = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        return port == defaultPort ? address : "\(address):\(port)"
    }
}

public func splitQueryPath(_ path: String) -> (String, String) {
    if let idx = path.firstIndex(of: "?") {
        return (String(path[path.startIndex..<idx]), String(path[path.index(after: idx)...]))
    }
    return (path, "")
}
