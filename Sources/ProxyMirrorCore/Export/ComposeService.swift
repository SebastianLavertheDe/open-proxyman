import Foundation

/// Compose 和 Repeat 共用请求解析与发送逻辑
enum ComposeService {

    struct ParsedRequest: Sendable {
        var method: String
        var url: String           // 绝对 URL
        var headers: [(String, String)]
        var body: Data?
    }

    /// 解析原始 HTTP 报文文本。请求行支持绝对 URL 或 path（配合 Host 头）。
    static func parse(_ text: String) -> ParsedRequest? {
        let separator = [text.range(of: "\r\n\r\n"), text.range(of: "\n\n")]
            .compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
        guard let headEnd = separator else {
            return parseHeadOnly(text.replacingOccurrences(of: "\r\n", with: "\n"))
        }
        let head = text[..<headEnd.lowerBound].replacingOccurrences(of: "\r\n", with: "\n")
        let body = text[headEnd.upperBound...]
        var parsed = parseHeadOnly(head)
        guard parsed != nil else { return nil }
        if !body.isEmpty {
            parsed?.body = Data(body.utf8)
        }
        return parsed
    }

    private static func parseHeadOnly(_ head: String) -> ParsedRequest? {
        var lines = head.components(separatedBy: "\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0].utf8.allSatisfy(isTokenByte) else { return nil }
        let method = parts[0].uppercased()
        let target = parts[1]

        lines.removeFirst()
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let idx = line.firstIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte), !value.contains("\r") else { return nil }
            headers.append((name, value))
        }

        // 解析绝对 URL
        let url: String
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            url = target
        } else if let host = headers.first(where: { $0.0.lowercased() == "host" })?.1 {
            let scheme = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") ? "http" : "https"
            url = "\(scheme)://\(host)\(target.hasPrefix("/") ? target : "/" + target)"
        } else {
            return nil
        }
        return ParsedRequest(method: method, url: url, headers: headers, body: nil)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
            "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    static func parseCurl(_ text: String) -> ParsedRequest? {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in text {
            if escaped {
                if !character.isNewline { word.append(character); started = true }
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else {
                word.append(character)
                started = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(word) }
        guard words.first == "curl" else { return nil }
        var args = words.dropFirst().makeIterator()
        var method: String?
        var url: String?
        var headers: [String] = []
        var bodies: [String] = []
        while let arg = args.next() {
            switch arg {
            case "-X", "--request": guard let value = args.next() else { return nil }; method = value
            case "--url": guard let value = args.next() else { return nil }; url = value
            case "-H", "--header": guard let value = args.next() else { return nil }; headers.append(value)
            case "-d", "--data", "--data-binary", "--data-raw":
                guard let value = args.next(), arg == "--data-raw" || !value.hasPrefix("@") else { return nil }
                bodies.append(value)
            case "--compressed", "-s", "--silent": break
            default:
                guard url == nil, arg.hasPrefix("http://") || arg.hasPrefix("https://") else { return nil }
                url = arg
            }
        }
        guard let url else { return nil }
        let requestLine = "\(method ?? (bodies.isEmpty ? "GET" : "POST")) \(url) HTTP/1.1"
        let head = ([requestLine] + headers).joined(separator: "\n")
        return parse(head + "\n\n" + bodies.joined(separator: "&"))
    }

    private static let requestQueue = DispatchQueue(label: "proxymirror.compose", qos: .userInitiated,
                                                     attributes: .concurrent)

    final class RequestTask: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        fileprivate func start(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw RequestError(message: "请求已取消") }
            try process.run()
            self.process = process
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    @discardableResult
    static func execute(_ parsed: ParsedRequest, proxyPort: UInt16? = nil,
                        onResult: @escaping (Transaction) -> Void) -> RequestTask? {
        guard let destination = URLParser.parse(target: parsed.url),
              let host = destination.host, let scheme = destination.scheme,
              ["http", "https"].contains(scheme),
              !parsed.method.isEmpty, parsed.method.utf8.allSatisfy(isTokenByte) else { return nil }

        let task = RequestTask()
        let captureLimit = AppSettings.shared.maxBodyMB * 1024 * 1024
        requestQueue.async {
            let tx = Transaction(captureBudget: .live)
            tx.method = parsed.method
            tx.scheme = scheme
            tx.host = host
            tx.port = destination.port
            (tx.path, tx.query) = splitQueryPath(destination.path)
            tx.requestHeaders = HTTPHeaders(parsed.headers)
            tx.captureLimit = captureLimit
            tx.appendRequestBody(parsed.body ?? Data())
            tx.requestBodyComplete = true
            tx.state = .awaiting
            send(parsed, tx: tx, proxyPort: proxyPort, task: task)
            DispatchQueue.main.async { onResult(tx) }
        }
        return task
    }

    private static func send(_ parsed: ParsedRequest, tx: Transaction, proxyPort: UInt16?, task: RequestTask) {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("proxymirror-send-\(UUID().uuidString)")
        let requestBodyFile = directory.appendingPathComponent("request")
        let headersFile = directory.appendingPathComponent("headers")
        let configFile = directory.appendingPathComponent("curl.conf")
        let errorFile = directory.appendingPathComponent("error")
        let process = Process()
        var captured = Data()
        var count = 0
        defer { try? files.removeItem(at: directory) }

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            var config = [
                "silent", "show-error", "http1.1", "suppress-connect-headers",
                "connect-timeout = 20", "max-time = 60", "proto = \"=http,https\"",
                "url = \(quoted(parsed.url))", "request = \(quoted(parsed.method))",
                "output = \"-\"", "dump-header = \(quoted(headersFile.path))",
                "stderr = \(quoted(errorFile.path))",
            ]
            if parsed.method == "HEAD" { config.append("head") }
            if let proxyPort {
                config += ["proxy = \"http://127.0.0.1:\(proxyPort)\"", "noproxy = \"\""]
                if tx.scheme == "https", ConnState(engine: .shared).shouldMITM(host: tx.host) {
                    try CertificateAuthority.shared.ensureCA()
                    config.append("cacert = \(quoted(CertificateAuthority.shared.caCertPath.path))")
                }
            } else {
                config.append("noproxy = \"*\"")
            }

            let framing: Set<String> = ["host", "content-length", "transfer-encoding", "trailer",
                                        "connection", "proxy-connection", "proxy-authorization"]
            for (key, value) in parsed.headers where !framing.contains(key.lowercased()) {
                guard !key.isEmpty, key.utf8.allSatisfy(isTokenByte),
                      !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                    throw RequestError(message: "请求头格式无效")
                }
                let header = value.isEmpty ? "\(key);" : "\(key): \(value)"
                config.append("header = \(quoted(header))")
            }
            if let body = parsed.body, parsed.method != "HEAD" {
                try body.write(to: requestBodyFile)
                config.append("data-binary = \(quoted("@" + requestBodyFile.path))")
            }
            try Data((config.joined(separator: "\n") + "\n").utf8).write(to: configFile)

            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-q", "--config", configFile.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try task.start(process)
            let reader = output.fileHandleForReading
            try? output.fileHandleForWriting.close()
            defer { try? reader.close() }
            var truncated = false
            while let bytes = try reader.read(upToCount: 64 * 1024), !bytes.isEmpty {
                if tx.method == "HEAD" { continue }
                count += bytes.count
                guard !truncated else { continue }
                let wanted = min(bytes.count, tx.captureLimit - captured.count)
                let accepted = wanted == 0 ? 0 : tx.captureReservation?.reserve(wanted) ?? wanted
                if accepted > 0 { captured.append(contentsOf: bytes.prefix(accepted)) }
                truncated = accepted < bytes.count
            }
            process.waitUntilExit()
            let headerData = (try? Data(contentsOf: headersFile, options: .mappedIfSafe)) ?? Data()
            let head = finalHead(from: headerData)
            if let head {
                tx.statusCode = head.status
                tx.statusReason = head.reason
                tx.responseVersion = head.version
                tx.responseHeaders = head.headers
                tx.contentType = head.headers.value(of: "Content-Type") ?? ""
            }
            let error: String?
            if process.terminationReason == .uncaughtSignal {
                error = "请求已取消"
            } else if process.terminationStatus != 0 {
                error = (try? String(contentsOf: errorFile, encoding: .utf8))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? "发送失败 (curl \(process.terminationStatus))"
            } else {
                error = head == nil ? "未收到 HTTP 响应" : nil
            }
            tx.receiveCapture(response: captured, responseBytes: count, charge: captured.count)
            tx.responseBodyComplete = error == nil
            tx.state = error == nil ? .completed : .failed
            tx.errorText = error
            tx.duration = Date().timeIntervalSince(tx.startedAt)
        } catch {
            task.cancel()
            if process.isRunning { process.waitUntilExit() }
            tx.receiveCapture(response: captured, responseBytes: count, charge: captured.count)
            tx.state = .failed
            tx.errorText = error.localizedDescription
        }
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }

    private static func finalHead(from data: Data) -> HTTPResponseHead? {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n\r\n")
            .compactMap { try? ResponseHeadParser.parse($0) }
            .last { $0.status >= 200 || $0.status == 101 }
    }

    private struct RequestError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 从已有 Transaction 生成可编辑的原始报文（Edit URL / Edit and Repeat 用）
    static func rawText(from tx: Transaction) -> String {
        rawText(from: request(from: tx))
    }

    static func request(from tx: Transaction) -> ParsedRequest {
        request(from: tx, body: tx.requestBody)
    }

    static func replayRequest(from tx: Transaction) -> ParsedRequest? {
        guard let body = tx.replayRequestBody() else { return nil }
        return request(from: tx, body: body)
    }

    private static func request(from tx: Transaction, body: Data) -> ParsedRequest {
        ParsedRequest(method: tx.method, url: tx.originalURL ?? tx.fullURL,
                      headers: tx.requestHeaders.pairs.map { ($0.name, $0.value) },
                      body: body.isEmpty ? nil : body)
    }

    static func rawText(from request: ParsedRequest) -> String {
        let lines = request.headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        return "\(request.method) \(request.url) HTTP/1.1\n" +
            lines + (lines.isEmpty ? "\n" : "\n\n") +
            (request.body.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
}
