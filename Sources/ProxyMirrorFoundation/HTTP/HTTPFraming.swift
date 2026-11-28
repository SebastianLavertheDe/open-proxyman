import Foundation

/// One framing decision is shared by parsing, forwarding and body tracking.
package enum HTTPBodyFraming: Equatable {
    case none, fixed(Int), chunked, closeDelimited
}

package enum HTTPFraming {
    package static func isToken(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            || "!#$%&'*+-.^_`|~".utf8.contains(value)
    }

    package static func validValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
    }

    package static func parseHeaders(_ lines: ArraySlice<String>) throws -> HTTPHeaders {
        var result = HTTPHeaders()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPParseError.malformed("Invalid HTTP header")
            }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy(isToken), validValue(value) else {
                throw HTTPParseError.malformed("Invalid HTTP header")
            }
            result.append(name, value)
        }
        return result
    }

    /// Reject TE+CL rather than forwarding two competing message boundaries.
    /// Equal duplicate/list lengths are accepted but emitted as one decimal CL.
    package static func normalize(_ headers: inout HTTPHeaders, request: Bool) throws -> HTTPBodyFraming {
        for field in headers.pairs {
            guard !field.name.isEmpty, field.name.utf8.allSatisfy(isToken), validValue(field.value) else {
                throw HTTPParseError.malformed("Invalid HTTP header")
            }
        }
        let lengths = headers.values(of: "Content-Length")
        let transfers = headers.values(of: "Transfer-Encoding")
        guard lengths.isEmpty || transfers.isEmpty else {
            throw HTTPParseError.malformed("Conflicting Transfer-Encoding and Content-Length")
        }
        if !lengths.isEmpty {
            let values = lengths.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            var length: Int?
            for value in values {
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(value),
                      length == nil || length == parsed else {
                    throw HTTPParseError.malformed("Invalid or conflicting Content-Length")
                }
                length = parsed
            }
            guard let length else { throw HTTPParseError.malformed("Invalid Content-Length") }
            headers.set(name: "Content-Length", value: String(length))
            return .fixed(length)
        }
        if !transfers.isEmpty {
            let fields = try transferCodings(transfers.joined(separator: ","))
            let codings = fields.map(\.name)
            guard codings.filter({ $0 == "chunked" }).count <= 1,
                  !codings.contains("chunked") || codings.last == "chunked",
                  !request || codings.last == "chunked" else {
                throw HTTPParseError.malformed("Invalid Transfer-Encoding")
            }
            headers.set(name: "Transfer-Encoding", value: fields.map(\.wire).joined(separator: ", "))
            return codings.last == "chunked" ? .chunked : .closeDelimited
        }
        return request ? .none : .closeDelimited
    }

    /// Transfer extensions can have quoted commas and case-sensitive values.
    /// Preserve those parameters while finding the actual final coding token.
    private static func transferCodings(_ value: String) throws -> [(name: String, wire: String)] {
        let bytes = Array(value.utf8)
        var cursor = 0
        var result: [(name: String, wire: String)] = []
        func whitespace() { while cursor < bytes.count && (bytes[cursor] == 32 || bytes[cursor] == 9) { cursor += 1 } }
        func token() -> String? {
            let start = cursor
            while cursor < bytes.count && isToken(bytes[cursor]) { cursor += 1 }
            return cursor > start ? String(decoding: bytes[start..<cursor], as: UTF8.self) : nil
        }
        while true {
            whitespace()
            guard let coding = token()?.lowercased() else { throw HTTPParseError.malformed("Invalid transfer coding") }
            let suffix = cursor
            whitespace()
            var parameters = false
            while cursor < bytes.count, bytes[cursor] == 59 {
                parameters = true
                cursor += 1
                whitespace()
                guard token() != nil else { throw HTTPParseError.malformed("Invalid transfer parameter") }
                whitespace()
                guard cursor < bytes.count, bytes[cursor] == 61 else { throw HTTPParseError.malformed("Invalid transfer parameter") }
                cursor += 1
                whitespace()
                if cursor < bytes.count, bytes[cursor] == 34 {
                    cursor += 1
                    while cursor < bytes.count, bytes[cursor] != 34 {
                        if bytes[cursor] == 92 { cursor += 1 }
                        guard cursor < bytes.count, bytes[cursor] == 9 || (bytes[cursor] >= 32 && bytes[cursor] != 127) else {
                            throw HTTPParseError.malformed("Invalid transfer quoted string")
                        }
                        cursor += 1
                    }
                    guard cursor < bytes.count else { throw HTTPParseError.malformed("Unterminated transfer quoted string") }
                    cursor += 1
                } else if token() == nil { throw HTTPParseError.malformed("Invalid transfer parameter value") }
                whitespace()
            }
            guard coding != "chunked" || !parameters else { throw HTTPParseError.malformed("Chunked coding has parameters") }
            let tail = String(decoding: bytes[suffix..<cursor], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            result.append((coding, coding + tail))
            guard cursor < bytes.count else { return result }
            guard bytes[cursor] == 44 else { throw HTTPParseError.malformed("Invalid transfer coding separator") }
            cursor += 1
        }
    }

    package static func request(_ head: inout HTTPRequestHead) throws -> HTTPBodyFraming {
        guard !head.method.isEmpty, head.method.utf8.allSatisfy(isToken),
              ["HTTP/1.0", "HTTP/1.1"].contains(head.version), !head.target.isEmpty,
              head.target.utf8.allSatisfy({ $0 > 32 && $0 != 127 }),
              head.headers.values(of: "Host").count <= 1 else {
            throw HTTPParseError.malformed("Invalid HTTP request head")
        }
        if head.version == "HTTP/1.0", head.headers.contains("Transfer-Encoding") {
            throw HTTPParseError.malformed("HTTP/1.0 does not support Transfer-Encoding")
        }
        if head.target.lowercased().hasPrefix("http://") || head.target.lowercased().hasPrefix("https://") {
            guard let components = URLComponents(string: head.target), components.user == nil,
                  components.password == nil, components.fragment == nil,
                  let target = URLParser.parse(target: head.target), let host = target.host, let scheme = target.scheme else {
                throw HTTPParseError.malformed("Invalid absolute request target")
            }
            head.headers.set(name: "Host", value: URLParser.authority(host: host, port: target.port, scheme: scheme))
        }
        return try normalize(&head.headers, request: true)
    }

    package static func response(_ head: inout HTTPResponseHead) throws -> HTTPBodyFraming {
        // HTTP/2 is used by the breakpoint editor's in-memory response model.
        // ResponseHeadParser.feed still requires an HTTP/1 wire version.
        guard ["HTTP/1.0", "HTTP/1.1", "HTTP/2"].contains(head.version), (100...599).contains(head.status), validValue(head.reason) else {
            throw HTTPParseError.malformed("Invalid HTTP response head")
        }
        if head.version == "HTTP/1.0", head.headers.contains("Transfer-Encoding") {
            throw HTTPParseError.malformed("HTTP/1.0 does not support Transfer-Encoding")
        }
        return try normalize(&head.headers, request: false)
    }
}
