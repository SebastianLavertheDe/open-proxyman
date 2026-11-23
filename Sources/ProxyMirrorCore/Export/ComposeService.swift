import Foundation

/// Compose 和 Repeat 共用请求解析与发送逻辑
enum ComposeService {

    struct ParsedRequest: Sendable, Codable {
        var method: String
        var url: String           // 绝对 URL
        var headers: [(String, String)]
        var body: Data?
        /// 0 disables the overall deadline; connection setup remains bounded.
        var timeoutSeconds: Int = 60
        var followRedirects: Bool = false

        private enum CodingKeys: String, CodingKey {
            case method, url, headers, body, timeoutSeconds, followRedirects
        }
        private struct Header: Codable { let name: String; let value: String }

        init(method: String, url: String, headers: [(String, String)], body: Data?,
             timeoutSeconds: Int = 60, followRedirects: Bool = false) {
            self.method = method; self.url = url; self.headers = headers; self.body = body
            self.timeoutSeconds = timeoutSeconds; self.followRedirects = followRedirects
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            method = try fields.decode(String.self, forKey: .method)
            url = try fields.decode(String.self, forKey: .url)
            headers = try fields.decode([Header].self, forKey: .headers).map { ($0.name, $0.value) }
            body = try fields.decodeIfPresent(Data.self, forKey: .body)
            timeoutSeconds = try fields.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
            followRedirects = try fields.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(method, forKey: .method); try fields.encode(url, forKey: .url)
            try fields.encode(headers.map { Header(name: $0.0, value: $0.1) }, forKey: .headers)
            try fields.encodeIfPresent(body, forKey: .body)
            try fields.encode(timeoutSeconds, forKey: .timeoutSeconds)
            try fields.encode(followRedirects, forKey: .followRedirects)
        }
    }

    enum Template: String, CaseIterable, Identifiable {
        case get = "GET with Query", json = "POST JSON", form = "POST Form"
        case multipart = "POST Multipart", query = "QUERY with Body", websocket = "WebSocket"
        var id: String { rawValue }

        func request(url: String = "") -> ParsedRequest {
            let target = url.isEmpty ? "https://example.com/" : url
            switch self {
            case .get:
                return ParsedRequest(method: "GET", url: target + (target.contains("?") ? "&" : "?") + "key=value", headers: [], body: nil)
            case .json:
                return ParsedRequest(method: "POST", url: target, headers: [("Content-Type", "application/json")], body: Data("{\n  \"key\": \"value\"\n}".utf8))
            case .form:
                return ParsedRequest(method: "POST", url: target, headers: [("Content-Type", "application/x-www-form-urlencoded")], body: Data("key=value&name=ProxyMirror".utf8))
            case .multipart:
                let boundary = "ProxyMirror-" + UUID().uuidString
                let body = "--\(boundary)\r\nContent-Disposition: form-data; name=\"key\"\r\n\r\nvalue\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"example.txt\"\r\nContent-Type: text/plain\r\n\r\nHello from ProxyMirror\r\n--\(boundary)--\r\n"
                return ParsedRequest(method: "POST", url: target, headers: [("Content-Type", "multipart/form-data; boundary=\(boundary)")], body: Data(body.utf8))
            case .query:
                return ParsedRequest(method: "QUERY", url: target, headers: [("Content-Type", "application/json")], body: Data("{}".utf8))
            case .websocket:
                let socketURL = target.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
                return ParsedRequest(method: "GET", url: socketURL, headers: [], body: Data("Hello from ProxyMirror".utf8))
            }
        }
    }

    private static let historyKey = "compose.history.v1"
    static func loadHistory(defaults: UserDefaults = .standard) -> [ParsedRequest] {
        guard let data = defaults.data(forKey: historyKey), data.count <= 4 * 1024 * 1024,
              let requests = try? JSONDecoder().decode([ParsedRequest].self, from: data) else { return [] }
        return Array(requests.prefix(20))
    }

    static func saveHistory(_ requests: [ParsedRequest], defaults: UserDefaults = .standard) {
        // Keep complete small requests; never persist a truncated body as a replayable request.
        var history: [ParsedRequest] = []
        for request in requests.prefix(20) where (request.body?.count ?? 0) <= 512 * 1024 {
            let proposed = history + [request]
            guard let data = try? JSONEncoder().encode(proposed), data.count <= 4 * 1024 * 1024 else { break }
            history = proposed
        }
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: historyKey) }
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
        if ["http://", "https://", "ws://", "wss://"].contains(where: target.hasPrefix) {
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
        var timeout = 60
        var redirects = false
        while let arg = args.next() {
            switch arg {
            case "-X", "--request": guard let value = args.next() else { return nil }; method = value
            case "--url": guard let value = args.next() else { return nil }; url = value
            case "-H", "--header": guard let value = args.next() else { return nil }; headers.append(value)
            case "-d", "--data", "--data-binary", "--data-raw":
                guard let value = args.next(), arg == "--data-raw" || !value.hasPrefix("@") else { return nil }
                bodies.append(value)
            case "-L", "--location": redirects = true
            case "--max-time", "-m":
                guard let value = args.next(), let seconds = Int(value), (0...86400).contains(seconds) else { return nil }
                timeout = seconds
            case "--compressed", "-s", "--silent", "--show-error": break
            default:
                guard url == nil, arg.hasPrefix("http://") || arg.hasPrefix("https://") else { return nil }
                url = arg
            }
        }
        guard let url else { return nil }
        let requestLine = "\(method ?? (bodies.isEmpty ? "GET" : "POST")) \(url) HTTP/1.1"
        let head = ([requestLine] + headers).joined(separator: "\n")
        var result = parse(head + "\n\n" + bodies.joined(separator: "&"))
        result?.timeoutSeconds = timeout
        result?.followRedirects = redirects
        return result
    }

    private static let requestQueue = DispatchQueue(label: "proxymirror.compose", qos: .userInitiated,
                                                     attributes: .concurrent)

    final class RequestTask: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var networkTask: URLSessionTask?
        private var networkSession: URLSession?

        fileprivate func start(_ task: URLSessionTask, session: URLSession) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw RequestError(message: "Request cancelled") }
            self.networkTask = task; self.networkSession = session
            task.resume()
        }

        fileprivate func releaseNetwork() {
            lock.lock(); defer { lock.unlock() }
            networkSession?.finishTasksAndInvalidate()
            networkTask = nil; networkSession = nil
        }

        fileprivate func start(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw RequestError(message: "Request cancelled") }
            try process.run()
            self.process = process
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if let process, process.isRunning { process.terminate() }
            networkTask?.cancel()
            networkSession?.invalidateAndCancel()
        }
    }

    @discardableResult
    static func execute(_ parsed: ParsedRequest, proxyPort: UInt16? = nil,
                        onResult: @escaping (Transaction) -> Void) -> RequestTask? {
        if let scheme = URL(string: parsed.url)?.scheme?.lowercased(), ["ws", "wss"].contains(scheme) {
            return executeWebSocket(parsed, proxyPort: proxyPort, onResult: onResult)
        }
        guard (0...86400).contains(parsed.timeoutSeconds),
              let destination = URLParser.parse(target: parsed.url),
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
                "connect-timeout = 20", "max-time = \(parsed.timeoutSeconds)", "proto = \"=http,https\"",
                "url = \(quoted(parsed.url))", "request = \(quoted(parsed.method))",
                "output = \"-\"", "dump-header = \(quoted(headersFile.path))",
                "stderr = \(quoted(errorFile.path))",
            ]
            if parsed.method == "HEAD" { config.append("head") }
            if parsed.followRedirects { config += ["location", "max-redirs = 10", "proto-redir = \"=http,https\""] }
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
                    throw RequestError(message: "Invalid request headers")
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
                error = "Request cancelled"
            } else if process.terminationStatus != 0 {
                error = (try? String(contentsOf: errorFile, encoding: .utf8))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? "Send failed (curl \(process.terminationStatus))"
            } else {
                error = head == nil ? "No HTTP response received" : nil
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

extension ComposeService {
    /// Sends an optional initial message, receives one message, then closes the socket.
    /// WSS uses the system trust store, including an installed ProxyMirror CA.
    static func executeWebSocket(_ parsed: ParsedRequest, proxyPort: UInt16?,
                                 onResult: @escaping (Transaction) -> Void) -> RequestTask? {
        guard let url = URL(string: parsed.url), let host = url.host,
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              (0...86400).contains(parsed.timeoutSeconds), parsed.method.uppercased() == "GET" else { return nil }
        var request = URLRequest(url: url)
        for (name, value) in parsed.headers {
            guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte),
                  !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else { return nil }
            let reserved: Set<String> = ["host", "connection", "upgrade", "content-length", "transfer-encoding",
                                          "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions"]
            if !reserved.contains(name.lowercased()) { request.addValue(value, forHTTPHeaderField: name) }
        }
        let captureLimit = AppSettings.shared.maxBodyMB * 1024 * 1024
        guard (parsed.body?.count ?? 0) <= captureLimit else { return nil }
        let tx = Transaction(captureBudget: .live)
        tx.method = "GET"; tx.scheme = url.scheme == "wss" ? "https" : "http"
        tx.host = host; tx.port = url.port ?? (url.scheme == "wss" ? 443 : 80)
        tx.path = url.path.isEmpty ? "/" : url.path; tx.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        tx.originalURL = parsed.url; tx.requestHeaders = HTTPHeaders(parsed.headers)
        tx.captureLimit = captureLimit
        tx.isWebSocket = true; tx.state = .awaiting
        tx.requestBodyComplete = true
        let owner = RequestTask()
        let delegate = ComposeWebSocketDelegate(transaction: tx, request: parsed, owner: owner, onResult: onResult)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = parsed.timeoutSeconds == 0 ? 7 * 86400 : Double(parsed.timeoutSeconds)
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.connectionProxyDictionary = proxyPort.map {
            ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int($0),
             "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int($0)] as [AnyHashable: Any]
        } ?? ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = max(1, tx.captureLimit)
        delegate.socket = socket
        do { try owner.start(socket, session: session) }
        catch { session.invalidateAndCancel(); return nil }
        delegate.scheduleDeadline()
        return owner
    }
}

private final class ComposeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let transaction: Transaction
    let request: ComposeService.ParsedRequest
    let owner: ComposeService.RequestTask
    let onResult: (Transaction) -> Void
    var socket: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "proxymirror.compose.websocket")
    private var finished = false

    init(transaction: Transaction, request: ComposeService.ParsedRequest, owner: ComposeService.RequestTask,
         onResult: @escaping (Transaction) -> Void) {
        self.transaction = transaction; self.request = request; self.owner = owner; self.onResult = onResult
    }

    func scheduleDeadline() {
        guard request.timeoutSeconds > 0 else { return }
        queue.asyncAfter(deadline: .now() + Double(request.timeoutSeconds)) { [weak self] in
            self?.finish(error: "WebSocket request timed out")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol negotiatedProtocol: String?) {
        queue.async { [self] in
            guard !finished else { return }
            transaction.statusCode = 101; transaction.statusReason = "Switching Protocols"
            if let response = webSocketTask.response as? HTTPURLResponse {
                transaction.responseHeaders = HTTPHeaders(response.allHeaderFields.compactMap {
                    guard let name = $0.key as? String else { return nil }; return (name, String(describing: $0.value))
                })
            }
            if let body = request.body, !body.isEmpty {
                let text = String(data: body, encoding: .utf8)
                webSocketTask.send(text.map(URLSessionWebSocketTask.Message.string) ?? .data(body)) { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.finished else { return }
                        if let error { self.finish(error: error.localizedDescription); return }
                        self.transaction.websocketFrames = [WSFrame(direction: .upstream, opcode: text == nil ? 2 : 1,
                                                                      fin: true, masked: true, payload: body)]
                        self.receive()
                    }
                }
            } else { receive() }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                switch result {
                case .success(let message):
                    let bytes: Data; let opcode: UInt8
                    switch message {
                    case .string(let value): bytes = Data(value.utf8); opcode = 1
                    case .data(let value): bytes = value; opcode = 2
                    @unknown default: self.finish(error: "Unrecognized WebSocket message"); return
                    }
                    self.transaction.appendResponseBody(bytes)
                    var frames = self.transaction.websocketFrames
                    frames.append(WSFrame(direction: .downstream, opcode: opcode, fin: true, masked: false,
                                          payload: self.transaction.responseBody))
                    self.transaction.websocketFrames = frames
                    self.transaction.contentType = opcode == 1 ? "text/plain; charset=utf-8" : "application/octet-stream"
                    self.finish(error: nil)
                case .failure(let error): self.finish(error: error.localizedDescription)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [self] in
            guard !finished else { return }
            if let response = task.response as? HTTPURLResponse, transaction.statusCode == 0 {
                transaction.statusCode = response.statusCode
            }
            finish(error: error?.localizedDescription ?? (transaction.statusCode == 101 ? nil : "WebSocket handshake failed"))
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [self] in
            finish(error: closeCode == .normalClosure ? nil : "WebSocket closed (\(closeCode.rawValue))")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.followRedirects ? newRequest : nil)
    }

    /// All callers run on queue; completion is exactly once, including cancel and timeout.
    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        transaction.duration = Date().timeIntervalSince(transaction.startedAt)
        transaction.responseBodyComplete = error == nil
        transaction.errorText = error
        transaction.state = error == nil ? .completed : .failed
        transaction.captureReservation?.finish(transaction: transaction)
        owner.releaseNetwork()
        DispatchQueue.main.async { [transaction, onResult] in onResult(transaction) }
    }
}
