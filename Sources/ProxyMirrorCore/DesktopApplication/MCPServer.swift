import CryptoKit
import Darwin
import Foundation

/// A stateless Streamable HTTP MCP transport. A single JSON reply is used for
/// requests; notifications get 202 and GET returns 405 (no server SSE stream).
/// The Unix socket remains the authority for both HTTP and stdio tool calls.
final class MCPServer {
    private let source: DispatchSourceRead
    private let token: String
    private let port: UInt16
    private let slots = DispatchSemaphore(value: 8)
    private let workers = DispatchQueue(label: "com.proxymirror.mcp.clients", qos: .utility, attributes: .concurrent)
    private static let headerLimit = 16 * 1024
    private static let bodyLimit = 3 * 1024 * 1024

    static var descriptorURL: URL {
        CertificateAuthority.applicationSupport.appendingPathComponent(".control/mcp.json")
    }

    static var configuration: [String: Any]? {
        var info = stat()
        guard lstat(descriptorURL.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size < 16 * 1024, let data = try? Data(contentsOf: descriptorURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func start() throws -> MCPServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalControlError.failed("无法创建 MCP socket。") }
        var keep = false
        defer { if !keep { Darwin.close(fd) } }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw LocalControlError.failed("无法配置 MCP listener。")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw LocalControlError.failed("无法绑定 MCP 回环接口。") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw LocalControlError.failed("无法读取 MCP 监听地址。") }
        let key = SymmetricKey(size: .bits256)
        let token = key.withUnsafeBytes { Data($0).base64EncodedString() }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "com.proxymirror.mcp.accept"))
        let server = MCPServer(source: source, token: token, port: UInt16(bigEndian: address.sin_port))
        source.setEventHandler { [weak server] in server?.accept(fd) }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        do { try server.writeConfiguration() }
        catch {
            // A suspended dispatch source must be resumed before cancellation.
            source.resume(); source.cancel(); keep = true
            throw error
        }
        keep = true
        source.resume()
        return server
    }

    private init(source: DispatchSourceRead, token: String, port: UInt16) {
        self.source = source; self.token = token; self.port = port
    }

    func stop() {
        // Remove this instance's descriptor synchronously. An asynchronous old
        // cancel handler must never delete a newly restarted server's token.
        if let headers = Self.configuration?["headers"] as? [String: String],
           headers["Authorization"] == "Bearer \(token)" { _ = unlink(Self.descriptorURL.path) }
        source.cancel()
    }
    deinit { stop() }

    static func clientConfiguration(client: MCPPreferencesController.Client,
                                    transport: MCPPreferencesController.Transport) -> String? {
        let server: [String: Any]
        if transport == .http {
            guard let config = configuration, let url = config["url"] as? String,
                  let headers = config["headers"] as? [String: String] else { return nil }
            server = ["type": "http", "url": url, "headers": headers]
        } else {
            server = ["command": Bundle.main.executableURL?.path ?? "proxymirror-cli", "args": ["mcp", "stdio"]]
        }
        if client == .codex {
            func literal(_ string: String) -> String {
                String(decoding: (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8), as: UTF8.self)
            }
            if transport == .http {
                let headers = server["headers"] as? [String: String] ?? [:]
                return "[mcp_servers.proxymirror]\nurl = \(literal(server["url"] as? String ?? ""))\nhttp_headers = { Authorization = \(literal(headers["Authorization"] ?? "")) }\n"
            }
            return "[mcp_servers.proxymirror]\ncommand = \(literal(server["command"] as? String ?? "proxymirror-cli"))\nargs = [\"mcp\", \"stdio\"]\n"
        }
        return (try? AutomationControl.json(["mcpServers": ["proxymirror": server]])).map { String(decoding: $0, as: UTF8.self) }
    }

    private func writeConfiguration() throws {
        let url = "http://127.0.0.1:\(port)/mcp"
        let config: [String: Any] = [
            "url": url, "headers": ["Authorization": "Bearer \(token)"],
            "protocolVersion": MCPProtocol.version,
            "mcpServers": ["proxymirror": ["type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"]]]
        ]
        let data = try AutomationControl.json(config)
        let temporary = Self.descriptorURL.deletingLastPathComponent().appendingPathComponent(".mcp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LocalControlError.failed("无法写入 MCP 连接配置。") }
        defer { Darwin.close(fd); _ = unlink(temporary.path) }
        try Self.send(data, fd: fd, file: true)
        guard rename(temporary.path, Self.descriptorURL.path) == 0 else { throw LocalControlError.failed("无法安装 MCP 连接配置。") }
    }

    private func accept(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard slots.wait(timeout: .now()) == .success else { Darwin.close(client); continue }
            workers.async { [self] in
                defer { Darwin.close(client); slots.signal() }
                do {
                    try Self.configure(client)
                    let response = try handle(Self.read(client))
                    try Self.send(response, fd: client)
                } catch {
                    try? Self.send(Self.http(status: 400, body: Data("Bad Request".utf8), contentType: "text/plain"), fd: client)
                }
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func handle(_ request: HTTPRequest) throws -> Data {
        let authorities = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"], authorities.contains(host.lowercased()) else { return Self.http(status: 403) }
        if let origin = request.headers["origin"], !authorities.map({ "http://" + $0 }).contains(origin.lowercased()) {
            return Self.http(status: 403)
        }
        guard request.headers["authorization"] == "Bearer \(token)" else { return Self.http(status: 401) }
        guard request.path == "/mcp" else { return Self.http(status: 404) }
        guard request.method == "POST" else { return Self.http(status: 405, extra: "Allow: POST\r\n") }
        let contentType = request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard contentType == "application/json" else { return Self.http(status: 415) }
        if let version = request.headers["mcp-protocol-version"], version != MCPProtocol.version {
            return Self.http(status: 400)
        }
        let result = MCPProtocol.reply(to: request.body)
        if let body = result { return Self.http(status: 200, body: body) }
        return Self.http(status: 202)
    }

    private static func configure(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var noSignal: Int32 = 1
        guard fcntl(fd, F_SETFL, 0) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw LocalControlError.failed("无法配置 MCP 连接。")
        }
    }

    private static func read(_ fd: Int32) throws -> HTTPRequest {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var boundary: Range<Data.Index>?
        while boundary == nil {
            guard bytes.count <= headerLimit, ProcessInfo.processInfo.systemUptime < deadline else { throw LocalControlError.usage("HTTP headers 超限。") }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LocalControlError.usage("HTTP 请求不完整。") }
            bytes.append(contentsOf: buffer.prefix(count))
            boundary = bytes.range(of: Data([13, 10, 13, 10]))
        }
        guard let boundary, boundary.lowerBound <= headerLimit,
              let head = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw LocalControlError.usage("HTTP headers 无效。") }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" else { throw LocalControlError.usage("需要 HTTP/1.1。") }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { throw LocalControlError.usage("HTTP header 格式无效。") }
            let key = String(line[..<separator]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[key] == nil else {
                throw LocalControlError.usage("HTTP header 重复或无效。")
            }
            headers[key] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw LocalControlError.usage("MCP 不接收 chunked 请求。") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(rawLength), length <= bodyLimit else { throw LocalControlError.usage("MCP body 超限。") }
        var body = Data(bytes[boundary.upperBound...])
        guard body.count <= length else { throw LocalControlError.usage("不接受 HTTP pipelining。") }
        while body.count < length {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw LocalControlError.usage("MCP 请求超时。") }
            let capacity = min(buffer.count, length - body.count)
            let count = recv(fd, &buffer, capacity, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LocalControlError.usage("MCP body 不完整。") }
            body.append(contentsOf: buffer.prefix(count))
        }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }

    private static func http(status: Int, body: Data = Data(), contentType: String = "application/json", extra: String = "") -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 415: "Unsupported Media Type"][status] ?? "Error"
        var result = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: \(contentType)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\(extra)\r\n".utf8)
        result.append(body)
        return result
    }

    private static func send(_ data: Data, fd: Int32, file: Bool = false) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = file ? Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                                 : Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LocalControlError.failed("写入 MCP 响应失败。") }
                offset += count
            }
        }
    }
}
