import Foundation

enum BreakpointHead: Sendable {
    case request(HTTPRequestHead)
    case response(HTTPResponseHead)

    var headers: HTTPHeaders {
        switch self {
        case .request(let head): return head.headers
        case .response(let head): return head.headers
        }
    }

    var firstLine: String {
        switch self {
        case .request(let head): return "\(head.method) \(head.target) \(head.version)"
        case .response(let head): return "\(head.version) \(head.status) \(head.reason)"
        }
    }

    func replacingHeaders(_ headers: HTTPHeaders) -> Self {
        switch self {
        case .request(var head):
            head.headers = headers
            return .request(head)
        case .response(var head):
            head.headers = headers
            return .response(head)
        }
    }
}

struct BreakpointMessage: Sendable {
    static let bodyLimit = 256 * 1024
    private static let headLimit = 128 * 1024

    let head: BreakpointHead
    /// nil indicates a streaming or binary body whose bytes remain in the connection.
    let body: Data?

    var text: String {
        let headers = String(decoding: head.headers.rawBytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let prefix = head.firstLine + (headers.isEmpty ? "" : "\n" + String(headers.dropLast()))
        guard let body else { return prefix }
        return prefix + "\n\n" + String(decoding: body, as: UTF8.self)
    }

    func applying(_ draft: String) throws -> Self {
        let separator = [draft.range(of: "\r\n\r\n"), draft.range(of: "\n\n")]
            .compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
        let end = separator?.lowerBound ?? draft.endIndex
        let rawHead = String(draft[..<end]).replacingOccurrences(of: "\r\n", with: "\n")
        let rawBody = separator.map { String(draft[$0.upperBound...]) } ?? ""
        guard rawHead.utf8.count <= Self.headLimit else { throw InvalidEdit("报文头超过 128 KiB") }
        guard body != nil || rawBody.isEmpty else { throw InvalidEdit("此报文仅支持编辑头部") }
        guard rawBody.utf8.count <= Self.bodyLimit else { throw InvalidEdit("正文超过 256 KiB") }
        let lines = rawHead.components(separatedBy: "\n")
        guard let first = lines.first, validValue(first) else { throw InvalidEdit("报文首行无效") }

        let newHead: BreakpointHead
        switch head {
        case .request:
            guard first == head.firstLine else { throw InvalidEdit("请求行保持原样，可编辑头部与正文") }
            newHead = head
        case .response(let original):
            guard let edited = try? ResponseHeadParser.parse(first), edited.version == original.version,
                  (200...599).contains(edited.status),
                  Self.noBodyStatus(edited.status) == Self.noBodyStatus(original.status) else {
                throw InvalidEdit("响应状态需在 200–599 内，并保留原报文的正文类型")
            }
            newHead = .response(edited)
        }

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw InvalidEdit("每个报文头需要名称和冒号") }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy(Self.headerNameByte), validValue(value) else {
                throw InvalidEdit("无效报文头：\(name)")
            }
            headers.append(name, value)
        }
        var protectedFields = ["Host", "Connection", "Proxy-Connection", "Upgrade", "Expect",
                               "Transfer-Encoding", "Trailer", "Content-Encoding"]
        if body == nil { protectedFields.append("Content-Length") }
        for field in protectedFields where headers.values(of: field) != head.headers.values(of: field) {
            throw InvalidEdit("\(field) 决定连接或正文编码，需要保留原值")
        }
        let replacement = body.map { _ in Data(rawBody.utf8) }
        if let replacement {
            headers.remove(name: "Content-Length")
            if !replacement.isEmpty || head.headers.contains("Content-Length") {
                headers.set(name: "Content-Length", value: String(replacement.count))
            }
        }
        return Self(head: newHead.replacingHeaders(headers), body: replacement)
    }

    static func noBodyStatus(_ status: Int) -> Bool {
        status == 204 || status == 205 || status == 304
    }

    static func editableText(_ bytes: Data) -> Data? {
        guard String(data: bytes, encoding: .utf8) != nil,
              bytes.allSatisfy({ $0 >= 32 || $0 == 9 || $0 == 10 || $0 == 13 }) else { return nil }
        return bytes
    }

    private func validValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
    }

    private static func headerNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122: return true
        default: return "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    struct InvalidEdit: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }
}
