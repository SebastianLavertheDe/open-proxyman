import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The worker's only I/O capability. URLSession runs without the system proxy,
/// cookie jar or credential storage; response buffering is bounded in delegates.
final class ScriptNetworkBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Limits {
        var wallTimeMilliseconds = 10_000
        var requestTimeoutMilliseconds = 5_000
        var responseBytes = 1024 * 1024
        var requestBytes = 256 * 1024
        var maximumRequests = 8
        var concurrentRequests = 4
        var blockedProxyPort = 9090
        var blockedProxyHosts = ["localhost", "localhost.", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

        init(_ object: [String: Any] = [:]) {
            wallTimeMilliseconds = min(30_000, max(1000, object["wallTimeMs"] as? Int ?? 10_000))
            requestTimeoutMilliseconds = min(wallTimeMilliseconds, max(100, object["requestTimeoutMs"] as? Int ?? 5_000))
            responseBytes = min(1024 * 1024, max(1024, object["responseLimit"] as? Int ?? 1024 * 1024))
            blockedProxyPort = object["blockedProxyPort"] as? Int ?? 9090
            if let hosts = object["blockedProxyHosts"] as? [String] { blockedProxyHosts += hosts.map { $0.lowercased() } }
        }
    }

    private final class Pending {
        let id: String
        let task: URLSessionDataTask
        let redirect: String
        var response: HTTPURLResponse?
        var data = Data()
        var redirects = 0
        var timer: DispatchWorkItem?
        init(id: String, task: URLSessionDataTask, redirect: String) { self.id = id; self.task = task; self.redirect = redirect }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var count = 0
    private var closed = false
    private var session: URLSession!
    private let limits: Limits
    private let localAddresses: Set<String>
    private let complete: @Sendable ([String: Any]) -> Void

    init(limits: Limits, complete: @escaping @Sendable ([String: Any]) -> Void) {
        self.limits = limits; self.complete = complete
        localAddresses = Self.interfaceAddresses().union(limits.blockedProxyHosts)
        super.init()
        #if canImport(Glibc)
        // swift-corelibs Foundation uses libcurl and can ignore Apple's proxy
        // dictionary. This type lives only in the disposable worker executable.
        // Remove libcurl's inherited proxy environment before creating a session.
        for name in ["http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"] { unsetenv(name) }
        setenv("NO_PROXY", "*", 1); setenv("no_proxy", "*", 1)
        #endif
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = Double(limits.requestTimeoutMilliseconds) / 1000
        config.timeoutIntervalForResource = Double(limits.wallTimeMilliseconds) / 1000
        config.httpMaximumConnectionsPerHost = limits.concurrentRequests
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func start(_ serialized: String) {
        var id = ""
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any],
                  let identifier = object["id"] as? String, !identifier.isEmpty, identifier.utf8.count <= 128,
                  let address = object["url"] as? String else { throw NetworkError("网络请求参数无效") }
            id = identifier
            guard serialized.utf8.count <= 2 * 1024 * 1024 else { throw NetworkError("网络请求参数超过 2 MiB") }
            let url = try validateURL(address)
            let method = (object["method"] as? String ?? "GET").uppercased()
            guard !method.isEmpty, method.utf8.allSatisfy(Self.token), !["CONNECT", "TRACE", "TRACK"].contains(method) else {
                throw NetworkError("网络请求方法无效或不支持")
            }
            let redirect = object["redirect"] as? String ?? "follow"
            guard ["follow", "manual", "error"].contains(redirect) else { throw NetworkError("redirect 支持 follow/manual/error") }
            var request = URLRequest(url: url)
            request.httpMethod = method
            let timeout = min(limits.wallTimeMilliseconds, max(1, object["timeoutMs"] as? Int ?? limits.requestTimeoutMilliseconds))
            request.timeoutInterval = Double(timeout) / 1000
            if let encoded = object["bodyBase64"] as? String {
                guard let body = Data(base64Encoded: encoded) else { throw NetworkError("请求 base64 无效") }
                request.httpBody = body
            } else if let body = object["body"] as? String { request.httpBody = Data(body.utf8) }
            guard (request.httpBody?.count ?? 0) <= limits.requestBytes,
                  !["GET", "HEAD"].contains(method) || request.httpBody == nil else {
                throw NetworkError("请求正文最多 256 KiB，GET/HEAD 不接受正文")
            }
            let fields = object["headers"] as? [[String]] ?? []
            guard fields.count <= 128, fields.reduce(0, { $0 + $1.joined().utf8.count }) <= 64 * 1024 else { throw NetworkError("网络请求头超限") }
            let reserved: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "proxy-connection", "proxy-authorization", "upgrade", "te", "trailer"]
            for field in fields {
                guard field.count == 2, !field[0].isEmpty, field[0].utf8.allSatisfy(Self.token),
                      field[1].utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { throw NetworkError("网络请求头无效") }
                guard !reserved.contains(field[0].lowercased()) else { throw NetworkError("不能手动设置连接或代理报文头：\(field[0])") }
                request.addValue(field[1], forHTTPHeaderField: field[0])
            }
            lock.lock()
            guard !closed, count < limits.maximumRequests, pending.count < limits.concurrentRequests else {
                lock.unlock(); throw NetworkError("每个脚本最多 8 次网络请求、4 个并发请求")
            }
            guard !pending.values.contains(where: { $0.id == id }) else { lock.unlock(); throw NetworkError("重复的网络请求 ID") }
            let task = session.dataTask(with: request)
            let item = Pending(id: id, task: task, redirect: redirect)
            pending[task.taskIdentifier] = item; count += 1
            let taskID = task.taskIdentifier
            let timer = DispatchWorkItem { [weak self] in self?.finish(taskID, error: "网络请求超时 (\(timeout) ms)", name: "TimeoutError") }
            item.timer = timer
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeout), execute: timer)
            task.resume()
        } catch { complete(["id": id, "error": error.localizedDescription, "name": "TypeError"]) }
    }

    var hasPendingRequests: Bool {
        lock.lock(); defer { lock.unlock() }
        return !pending.isEmpty
    }

    func cancel(_ id: String) {
        lock.lock(); let taskID = pending.first(where: { $0.value.id == id })?.key; lock.unlock()
        if let taskID { finish(taskID, error: "网络请求已取消", name: "AbortError") }
    }

    func cancelAll() {
        lock.lock(); closed = true; let items = Array(pending.values); pending.removeAll(); lock.unlock()
        for item in items { item.timer?.cancel(); item.task.cancel() }
        session.invalidateAndCancel()
    }

    private func validateURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 8192, let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              let url = components.url else { throw NetworkError("fetch 需要不含用户名密码的 HTTP/HTTPS 绝对 URL") }
        let normalized = host.lowercased()
        let port = components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw NetworkError("网络 URL 端口需在 1...65535 之间") }
        guard port != limits.blockedProxyPort || !isLocalProxyHost(normalized) else {
            throw NetworkError("网络 API 不能请求 ProxyMirror 自身监听端口，请直接请求目标服务")
        }
        return url
    }

    private func isLocalProxyHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if localAddresses.contains(host) || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.") { return true }
        // Resolve aliases only when they point at the proxy's port. This catches
        // localhost aliases and numeric forms such as 2130706433 or 127.1.
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0 else { return false }
        defer { if let first { freeaddrinfo(first) } }
        var entry = first
        while let current = entry {
            if let address = current.pointee.ai_addr,
               let numeric = Self.numericAddress(address, length: current.pointee.ai_addrlen),
               localAddresses.contains(numeric) || numeric.hasPrefix("127.") || numeric == "::1" || numeric.hasPrefix("::ffff:127.") { return true }
            entry = current.pointee.ai_next
        }
        return false
    }

    private static func numericAddress(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer).lowercased()
    }

    private static func interfaceAddresses() -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { if let first { freeifaddrs(first) } }
        var result = Set<String>(); var entry = first
        while let current = entry {
            if let address = current.pointee.ifa_addr {
                let family = Int32(address.pointee.sa_family)
                let length = family == AF_INET ? MemoryLayout<sockaddr_in>.size : family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : 0
                if length > 0, let numeric = numericAddress(address, length: socklen_t(length)) { result.insert(numeric) }
            }
            entry = current.pointee.ifa_next
        }
        return result
    }

    private static func token(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); finish(dataTask.taskIdentifier, error: "未收到 HTTP 响应"); return }
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else { lock.unlock(); completionHandler(.cancel); return }
        item.response = http
        let tooManyHeaders = http.allHeaderFields.count > 128 || http.allHeaderFields.reduce(0, { $0 + String(describing: $1.key).utf8.count + String(describing: $1.value).utf8.count }) > 64 * 1024
        let tooLarge = http.expectedContentLength > Int64(limits.responseBytes)
        lock.unlock()
        if tooManyHeaders { completionHandler(.cancel); finish(dataTask.taskIdentifier, error: "网络响应头超过上限"); return }
        if tooLarge { completionHandler(.cancel); finish(dataTask.taskIdentifier, error: "网络响应超过 \(limits.responseBytes) 字节上限"); return }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        guard data.count <= limits.responseBytes - item.data.count else {
            lock.unlock(); finish(dataTask.taskIdentifier, error: "网络响应超过 \(limits.responseBytes) 字节上限"); return
        }
        item.data.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task.taskIdentifier, error: error?.localizedDescription,
               name: (error as NSError?)?.code == NSURLErrorTimedOut ? "TimeoutError" : "TypeError")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        guard let item = pending[task.taskIdentifier] else { lock.unlock(); completionHandler(nil); return }
        item.redirects += 1
        let mode = item.redirect, count = item.redirects
        lock.unlock()
        if mode == "manual" { completionHandler(nil); return }
        if mode == "error" || count > 5 {
            completionHandler(nil); finish(task.taskIdentifier, error: count > 5 ? "网络重定向超过 5 次" : "网络请求不允许重定向"); return
        }
        do {
            _ = try validateURL(request.url?.absoluteString ?? "")
            var next = request
            if response.url?.host?.lowercased() != next.url?.host?.lowercased()
                || response.url?.scheme?.lowercased() != next.url?.scheme?.lowercased()
                || response.url?.port != next.url?.port {
                next.setValue(nil, forHTTPHeaderField: "Authorization")
                next.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            completionHandler(next)
        } catch { completionHandler(nil); finish(task.taskIdentifier, error: error.localizedDescription) }
    }

    private func finish(_ taskID: Int, error: String?, name: String = "TypeError") {
        lock.lock(); let item = pending.removeValue(forKey: taskID); lock.unlock()
        guard let item else { return }
        item.timer?.cancel()
        if let error { item.task.cancel(); complete(["id": item.id, "error": error, "name": name]); return }
        guard let response = item.response else { complete(["id": item.id, "error": "未收到 HTTP 响应", "name": "TypeError"]); return }
        let headers = response.allHeaderFields.map { [String(describing: $0.key), String(describing: $0.value)] }
        complete(["id": item.id, "status": response.statusCode,
                  "statusText": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                  "headers": headers, "url": response.url?.absoluteString ?? "",
                  "bodyBase64": item.data.base64EncodedString()])
    }

    struct NetworkError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
