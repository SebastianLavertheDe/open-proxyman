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
        guard rawHead.utf8.count <= Self.headLimit else { throw InvalidEdit(OperationIssue.modelBreakpointHeaderSize) }
        guard body != nil || rawBody.isEmpty else { throw InvalidEdit(OperationIssue.modelBreakpointHeadersOnly) }
        guard rawBody.utf8.count <= Self.bodyLimit else { throw InvalidEdit(OperationIssue.modelBreakpointBodySize) }
        let lines = rawHead.components(separatedBy: "\n")
        guard let first = lines.first, validValue(first) else { throw InvalidEdit(OperationIssue.modelBreakpointFirstLineInvalid) }

        let newHead: BreakpointHead
        switch head {
        case .request:
            guard first == head.firstLine else { throw InvalidEdit(OperationIssue.modelBreakpointRequestLineImmutable) }
            newHead = head
        case .response(let original):
            guard let edited = try? ResponseHeadParser.parse(first), edited.version == original.version,
                  (200...599).contains(edited.status),
                  Self.noBodyStatus(edited.status) == Self.noBodyStatus(original.status) else {
                throw InvalidEdit(OperationIssue.modelBreakpointResponseStatusInvalid)
            }
            newHead = .response(edited)
        }

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw InvalidEdit(OperationIssue.modelBreakpointHeaderColon) }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy(Self.headerNameByte), validValue(value) else {
                throw InvalidEdit(OperationIssue.modelBreakpointHeaderInvalid(name))
            }
            headers.append(name, value)
        }
        var protectedFields = ["Host", "Connection", "Proxy-Connection", "Upgrade", "Expect",
                               "Transfer-Encoding", "Trailer", "Content-Encoding"]
        if body == nil { protectedFields.append("Content-Length") }
        for field in protectedFields where headers.values(of: field) != head.headers.values(of: field) {
            throw InvalidEdit(OperationIssue.modelBreakpointProtectedHeader(field))
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

    struct InvalidEdit: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ diagnostic: String) { operationIssue = .technical(diagnostic) }
        var errorDescription: String? { operationIssue.diagnostic }
        var detail: String { operationIssue.diagnostic }
    }
}
