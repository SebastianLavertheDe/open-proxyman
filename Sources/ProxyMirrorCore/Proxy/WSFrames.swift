import Foundation

// MARK: - WebSocket 帧级解析（RFC 6455）

/// 一条 WS 记录：控制帧（ping/pong/close）或完整的分片重组消息
struct WSFrame: Identifiable, Codable, Sendable {
    // Include room for the retained array, its spare capacity, and the parser batch.
    static let captureMetadataCost = max(128, 2 * MemoryLayout<WSFrame>.stride)

    var id = UUID()
    let direction: Direction
    let opcode: UInt8
    let fin: Bool
    let masked: Bool
    let payload: Data
    var timestamp = Date()
    // Older saved sessions have no RSV1 value. Their captured wire body still has the flag.
    var rsv1: Bool?
    var decompressedPreview: Data?
    var decompressedPreviewTruncated: Bool?

    enum Direction: String, Codable, Sendable {
        case upstream = "send"      // 客户端 → 服务器
        case downstream = "recv"    // 服务器 → 客户端
    }

    // MARK: 展示

    enum Kind {
        case text, binary, ping, pong, close, continuation, other
    }

    var kind: Kind {
        switch opcode {
        case 0x0: return .continuation
        case 0x1: return .text
        case 0x2: return .binary
        case 0x8: return .close
        case 0x9: return .ping
        case 0xA: return .pong
        default: return .other
        }
    }

    var opcodeName: String {
        switch kind {
        case .text: return "Text"
        case .binary: return "Binary"
        case .ping: return "Ping"
        case .pong: return "Pong"
        case .close: return "Close"
        case .continuation: return "Continuation"
        case .other: return "Opcode 0x\(String(opcode, radix: 16))"
        }
    }

    var directionGlyph: String { direction == .upstream ? "↑ 发送" : "↓ 接收" }

    var sizeText: String {
        let n = payload.count
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / (1024 * 1024))
    }

    /// 文本负载（含 close 帧状态码解释）
    var previewText: String {
        switch kind {
        case .close:
            guard payload.count >= 2 else { return "Connection Close" }
            let code = (UInt16(payload[0]) << 8) | UInt16(payload[1])
            return "Close(\(code)) \(Self.closeReason(code))"
        default:
            guard let body = displayPayload else { return Self.unavailablePreview }
            guard let text = Self.utf8Preview(body, limit: 2048, alreadyTruncated: decompressedPreviewTruncated == true) else {
                return "<二进制 \(body.count) 字节>"
            }
            let prefix = text.prefix(501)
            let oneLine = prefix.prefix(500).replacingOccurrences(of: "\n", with: " ")
            let shortened = prefix.count > 500 || body.count > 2048 || decompressedPreviewTruncated == true
            return shortened ? oneLine + "…" : oneLine
        }
    }

    static let unavailablePreview = "压缩正文无法预览，请查看「原文」"

    var displayPayload: Data? {
        rsv1 == true ? decompressedPreview : payload
    }

    var fullText: String? {
        guard let displayPayload, decompressedPreviewTruncated != true else { return nil }
        return String(data: displayPayload, encoding: .utf8)
    }

    static func utf8Preview(_ data: Data, limit: Int, alreadyTruncated: Bool) -> String? {
        let bytes = data.prefix(limit)
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if alreadyTruncated || data.count > limit {
            // A preview may end partway through a multibyte character.
            for count in 1...3 {
                if let text = String(data: bytes.dropLast(count), encoding: .utf8) { return text }
            }
        }
        return nil
    }

    static func closeReason(_ code: UInt16) -> String {
        switch code {
        case 1000: return "Normal"
        case 1001: return "Going Away"
        case 1002: return "Protocol Error"
        case 1003: return "Unsupported Data"
        case 1005: return "No Status"
        case 1006: return "Abnormal"
        case 1008: return "Policy Violation"
        case 1009: return "Message Too Big"
        case 1011: return "Server Error"
        default: return "Code \(code)"
        }
    }
}

// MARK: 帧解析器（流式；按方向各持一个实例）

struct WSFrameParser {
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var assembling: (opcode: UInt8, rsv1: Bool, payload: [UInt8])?

    var pendingBytes: Int { buffer.count - readIndex + (assembling?.payload.count ?? 0) }

    /// 喂入一段字节；返回解析出的完整记录（消息已重组分片）
    /// A denied frame ends this capture prefix without allocating its payload or record.
    mutating func feed(_ data: Data, direction: WSFrame.Direction, limit: Int = .max,
                       admit: () -> Bool = { true }) -> [WSFrame] {
        buffer.append(contentsOf: data)
        var out: [WSFrame] = []

        while out.count < limit, let frame = parseOne() {
            let startsFragment = !frame.fin && (frame.opcode == 0x1 || frame.opcode == 0x2)
            let continuesFragment = frame.opcode == 0x0 && assembling != nil
            let emitsRecord = !startsFragment && (!continuesFragment || frame.fin)
            guard !emitsRecord || admit() else {
                self = WSFrameParser()
                return out
            }
            let payload = readPayload(frame)
            if startsFragment {
                assembling = (frame.opcode, frame.rsv1, payload)
            } else if continuesFragment {
                assembling!.payload.append(contentsOf: payload)
                if frame.fin, let done = assembling {
                    assembling = nil
                    out.append(WSFrame(direction: direction, opcode: done.opcode, fin: true,
                                       masked: frame.masked, payload: Data(done.payload), rsv1: done.rsv1))
                }
            } else {
                let control = (0x8...0xA).contains(frame.opcode)
                out.append(WSFrame(direction: direction, opcode: frame.opcode, fin: control || frame.fin,
                                   masked: frame.masked, payload: Data(payload), rsv1: !control && frame.rsv1))
            }
        }
        let unread = buffer.count - readIndex
        if unread > 8 * 1024 * 1024 {
            buffer.removeAll()
            readIndex = 0
            assembling = nil
        } else if unread == 0 {
            buffer.removeAll(keepingCapacity: buffer.capacity <= 64 * 1024)
            readIndex = 0
        } else if readIndex >= 64 * 1024 && readIndex >= unread {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        return out
    }

    private struct ParsedFrame {
        let opcode: UInt8
        let fin: Bool
        let masked: Bool
        let rsv1: Bool
        let maskStart: Int
        let payloadRange: Range<Int>
    }

    /// 从缓冲取一个完整帧的范围；不足返回 nil
    private mutating func parseOne() -> ParsedFrame? {
        let available = buffer.count - readIndex
        guard available >= 2 else { return nil }
        let b0 = buffer[readIndex]
        let b1 = buffer[readIndex + 1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = UInt64(b1 & 0x7F)
        var offset = 2

        if len == 126 {
            guard available >= 4 else { return nil }
            len = (UInt64(buffer[readIndex + 2]) << 8) | UInt64(buffer[readIndex + 3])
            offset = 4
        } else if len == 127 {
            guard available >= 10 else { return nil }
            len = 0
            for i in 2..<10 { len = (len << 8) | UInt64(buffer[readIndex + i]) }
            offset = 10
        }

        let maskLen = masked ? 4 : 0
        guard len <= UInt64(64 * 1024 * 1024) else { return nil }
        let total = offset + maskLen + Int(len)
        guard available >= total else { return nil }

        let maskStart = readIndex + offset
        let payloadRange = (maskStart + maskLen)..<(readIndex + total)
        readIndex += total
        return ParsedFrame(opcode: opcode, fin: fin, masked: masked, rsv1: b0 & 0x40 != 0,
                           maskStart: maskStart, payloadRange: payloadRange)
    }

    private func readPayload(_ frame: ParsedFrame) -> [UInt8] {
        var payload = Array(buffer[frame.payloadRange])
        if frame.masked {
            for i in payload.indices { payload[i] ^= buffer[frame.maskStart + (i & 3)] }
        }
        return payload
    }
}

// MARK: - GraphQL 识别

struct GraphQLInfo {
    var operationType: String = ""     // query / mutation / subscription
    var operationName: String = ""
    var queryText: String = ""
    var variablesText: String = ""
    var responseIsGraphQL = false
}

enum GraphQLService {

    /// 判定请求是否 GraphQL（JSON body 含 query 键 / application/graphql / ?query=）
    static func detect(tx: Transaction, inspectResponse: Bool = true) -> GraphQLInfo? {
        guard !tx.requestTruncated,
              var result = detectRequest(path: tx.path, query: tx.query, headers: tx.requestHeaders,
                                         body: InspectionBody.data(for: tx, request: true, limit: 262_144) ?? Data(),
                                         bodyIsDecoded: true) else { return nil }
        if inspectResponse, let body = InspectionBody.data(for: tx, request: false, limit: 262_144), !body.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           obj.keys.contains("data") || obj.keys.contains("errors") {
            result.responseIsGraphQL = true
        }
        return result
    }

    static func detectRequest(path: String, query: String, headers: HTTPHeaders, body: Data,
                              bodyIsDecoded: Bool = false) -> GraphQLInfo? {
        var body = body
        if !bodyIsDecoded {
            let encodings = headers.values(of: "Content-Encoding").flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && $0 != "identity" }
            if !encodings.isEmpty, !body.isEmpty {
                guard case .success(let decoded) = ContentCoding.decodeIfCompressed(
                    body, encodings: encodings, maxOutputBytes: 262_144) else { return nil }
                body = decoded.0
            }
        }
        guard body.count <= 262_144 else { return nil }
        var info: GraphQLInfo?
        var declaredName: String?

        // POST JSON {"query": "...", "variables": {...}} 或 application/graphql
        let reqCT = (headers.value(of: "Content-Type") ?? "").lowercased().split(separator: ";").first
        if !body.isEmpty {
            if reqCT?.trimmingCharacters(in: .whitespaces) == "application/graphql" {
                info = info ?? GraphQLInfo()
                info?.queryText = String(decoding: body, as: UTF8.self)
            } else if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      obj["query"] is String || obj["extensions"] is [String: Any] {
                info = GraphQLInfo()
                info?.queryText = obj["query"] as? String ?? ""
                declaredName = obj["operationName"] as? String
                if let vars = obj["variables"] {
                    if let d = try? JSONSerialization.data(withJSONObject: vars, options: [.prettyPrinted, .sortedKeys]) {
                        info?.variablesText = String(decoding: d, as: UTF8.self)
                    }
                }
            }
        }
        // GET ?query=...
        if info == nil, query.contains("query=") || query.contains("operationName="),
           let items = URLComponents(string: "http://x/?\(query)")?.queryItems {
            let query = items.first { $0.name == "query" }?.value
            declaredName = items.first { $0.name == "operationName" }?.value
            if let query, !query.isEmpty {
                info = GraphQLInfo()
                info?.queryText = query
                info?.variablesText = items.first { $0.name == "variables" }?.value ?? ""
            } else if path.localizedCaseInsensitiveContains("graphql"), declaredName?.isEmpty == false {
                info = GraphQLInfo()
            }
        }

        guard var result = info else { return nil }
        let parsed = parseOperation(result.queryText)
        result.operationType = parsed.type
        result.operationName = declaredName?.isEmpty == false ? declaredName! : parsed.name

        return result
    }

    static func parseOperation(_ query: String) -> (type: String, name: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉前导注释行
        let noComments = trimmed.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        guard let re = try? NSRegularExpression(pattern: #"^\s*(query|mutation|subscription)\s+([_A-Za-z][_0-9A-Za-z]*)?"#, options: [.caseInsensitive]),
              let m = re.firstMatch(in: noComments, range: NSRange(noComments.startIndex..., in: noComments)),
              m.numberOfRanges >= 2 else {
            return (noComments.hasPrefix("mutation") ? "mutation" : "query", "")
        }
        let ns = noComments as NSString
        let type = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : "query"
        let name = m.numberOfRanges > 2 && m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
        return (type.lowercased(), name)
    }
}

extension Transaction {
    var graphqlOperationName: String? {
        guard let name = GraphQLService.detect(tx: self, inspectResponse: false)?.operationName,
              !name.isEmpty else { return nil }
        return name
    }
}

// MARK: - JSON 树（通用树视图数据）

final class JSONTreeNode: Identifiable, Sendable {
    let key: String
    let valuePreview: String     // 叶子的值展示；分支为空
    let isBranch: Bool
    let kindName: String
    let children: [JSONTreeNode]
    let childCount: Int
    let id = UUID()

    init(key: String, valuePreview: String, isBranch: Bool, kindName: String,
         children: [JSONTreeNode] = [], childCount: Int = 0) {
        self.key = key
        self.valuePreview = valuePreview
        self.isBranch = isBranch
        self.kindName = kindName
        self.children = children
        self.childCount = childCount
    }

    fileprivate static func build(key: String, _ any: Any, remaining: inout Int, depth: Int) -> JSONTreeNode {
        remaining -= 1
        let canExpand = depth < 24 && remaining > 0 && !Task.isCancelled
        switch any {
        case let dict as [String: Any]:
            var children: [JSONTreeNode] = []
            if canExpand {
                for key in dict.keys.sorted() {
                    guard remaining > 0, !Task.isCancelled else { break }
                    children.append(build(key: key, dict[key]!, remaining: &remaining, depth: depth + 1))
                }
            }
            return JSONTreeNode(key: key, valuePreview: "{\(dict.count)}", isBranch: true, kindName: "Object",
                                children: children, childCount: dict.count)
        case let arr as [Any]:
            var children: [JSONTreeNode] = []
            if canExpand {
                for (index, value) in arr.enumerated() {
                    guard remaining > 0, !Task.isCancelled else { break }
                    children.append(build(key: "[\(index)]", value, remaining: &remaining, depth: depth + 1))
                }
            }
            return JSONTreeNode(key: key, valuePreview: "[\(arr.count)]", isBranch: true, kindName: "Array",
                                children: children, childCount: arr.count)
        case let s as String:
            let short = s.count > 300 ? String(s.prefix(300)) + "…" : s
            return JSONTreeNode(key: key, valuePreview: "\"\(short)\"", isBranch: false, kindName: "String")
        case let num as NSNumber:
            let isBool = CFGetTypeID(num) == CFBooleanGetTypeID()
            return JSONTreeNode(key: key, valuePreview: isBool ? (num.boolValue ? "true" : "false") : num.stringValue,
                                isBranch: false, kindName: isBool ? "Boolean" : "Number")
        case let b as Bool:
            return JSONTreeNode(key: key, valuePreview: b ? "true" : "false", isBranch: false, kindName: "Boolean")
        case is NSNull:
            return JSONTreeNode(key: key, valuePreview: "null", isBranch: false, kindName: "Null")
        default:
            return JSONTreeNode(key: key, valuePreview: "\(any)", isBranch: false, kindName: "Other")
        }
    }
}

enum JSONTreeService {
    static let maxInput = 256 * 1024
    static let maxNodes = 1024

    static func build(from data: Data) -> JSONTreeNode? {
        guard data.count <= maxInput, !Task.isCancelled,
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var remaining = maxNodes
        let key = obj is [String: Any] ? "{}" : obj is [Any] ? "[]" : "root"
        return JSONTreeNode.build(key: key, obj, remaining: &remaining, depth: 0)
    }
}

// MARK: - Protobuf 无 schema 线格式树解码

struct ProtobufField: Identifiable {
    let id = UUID()
    let fieldNumber: Int
    let wireType: Int
    let path: String            // "3.1.2"
    let varint: UInt64?
    let fixed64: UInt64?
    let fixed32: UInt32?
    let bytes: Data?
    var children: [ProtobufField] = []

    var wireName: String {
        switch wireType {
        case 0: return "varint"
        case 1: return "fixed64"
        case 2: return "bytes"
        case 5: return "fixed32"
        default: return "wire\(wireType)"
        }
    }

    var valueText: String {
        if let v = varint { return "\(v)" }
        if let v = fixed64 {
            let d = Double(bitPattern: v)
            return "\(v) (double \(String(format: "%.6g", d)))"
        }
        if let v = fixed32 {
            let f = Float(bitPattern: v)
            return "\(v) (float \(String(format: "%.6g", f)))"
        }
        if let b = bytes {
            if let s = String(data: b, encoding: .utf8), isPrintable(s) {
                let one = s.replacingOccurrences(of: "\n", with: "\\n")
                return "\"\(one.count > 200 ? String(one.prefix(200)) + "…" : one)\""
            }
            return "<\(b.count) bytes> \(b.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))"
        }
        return ""
    }

    private func isPrintable(_ s: String) -> Bool {
        s.allSatisfy { ($0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " " || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" || $0 == ":") }
    }
}

enum ProtobufService {

    /// 无 schema 解码线格式；nil = 不像合法 protobuf
    static func decode(_ data: Data, path: String = "") -> [ProtobufField]? {
        let bytes = [UInt8](data)
        return decodeFields(bytes, path: path)
    }

    /// grpc 帧：1 字节压缩标志 + 4 字节大端长度
    static func stripGRPCPrefix(_ data: Data) -> Data {
        guard data.count > 5 else { return data }
        let compressed = data[0]
        let length = (UInt32(data[1]) << 24) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 8) | UInt32(data[4])
        if compressed == 0, Int(length) <= data.count - 5 {
            return data.subdata(in: 5..<(5 + Int(length)))
        }
        return data
    }

    static func isProtobufContentType(_ ct: String) -> Bool {
        let c = ct.lowercased()
        return c.contains("protobuf") || c.contains("grpc") || c.contains("vnd.google")
    }

    /// 启发式：可解析且字段数 ≥ 1
    static func looksLikeProtobuf(_ data: Data) -> Bool {
        guard data.count >= 2, data.count <= 32 * 1024 * 1024 else { return false }
        guard let fields = decode(data), !fields.isEmpty else { return false }
        return true
    }

    private static func decodeFields(_ bytes: [UInt8], path: String) -> [ProtobufField]? {
        var out: [ProtobufField] = []
        var i = 0
        while i < bytes.count {
            guard let tag = readVarint(bytes, &i) else { return nil }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            guard fieldNumber > 0, fieldNumber < 1_000_000 else { return nil }

            switch wireType {
            case 0:
                guard let v = readVarint(bytes, &i) else { return nil }
                out.append(ProtobufField(fieldNumber: fieldNumber, wireType: 0, path: path,
                                         varint: v, fixed64: nil, fixed32: nil, bytes: nil))
            case 1:
                guard i + 8 <= bytes.count else { return nil }
                var v: UInt64 = 0
                for j in 0..<8 { v |= UInt64(bytes[i + j]) << (8 * j) }   // 小端
                i += 8
                out.append(ProtobufField(fieldNumber: fieldNumber, wireType: 1, path: path,
                                         varint: nil, fixed64: v, fixed32: nil, bytes: nil))
            case 2:
                guard let len = readVarint(bytes, &i), Int(len) <= bytes.count - i else { return nil }
                let payload = Array(bytes[i..<i + Int(len)])
                i += Int(len)
                let fieldPath = path.isEmpty ? "\(fieldNumber)" : "\(path).\(fieldNumber)"
                var f = ProtobufField(fieldNumber: fieldNumber, wireType: 2, path: fieldPath,
                                      varint: nil, fixed64: nil, fixed32: nil, bytes: Data(payload))
                // 嵌套消息：尝试递归（失败则当 bytes）
                if let nested = decodeFields(payload, path: fieldPath), !nested.isEmpty, payload.count > 1 {
                    f.children = nested
                }
                out.append(f)
            case 5:
                guard i + 4 <= bytes.count else { return nil }
                var v: UInt32 = 0
                for j in 0..<4 { v |= UInt32(bytes[i + j]) << (8 * j) }
                i += 4
                out.append(ProtobufField(fieldNumber: fieldNumber, wireType: 5, path: path,
                                         varint: nil, fixed64: nil, fixed32: v, bytes: nil))
            default:
                return nil    // 3/4 (group 已废弃) 或非法
            }
        }
        return out
    }

    private static func readVarint(_ bytes: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < bytes.count, shift <= 63 else { return nil }
            let b = bytes[i]
            i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }
}
