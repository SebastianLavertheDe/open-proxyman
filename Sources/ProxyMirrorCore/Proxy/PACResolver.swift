import CFNetwork
import Foundation
import NIOCore

extension ExternalProxyConfig {
    var proxyPACURL: URL? {
        guard let text = pacURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        switch scheme {
        case "file":
            return (parts.host == nil || parts.host == "" || parts.host == "localhost")
                && parts.path.hasPrefix("/") && parts.query == nil ? url : nil
        case "http", "https":
            return parts.host?.isEmpty == false ? url : nil
        default:
            return nil
        }
    }

    /// Resolves disabled, bypass and DIRECT routes to nil. PAC failures propagate to the caller.
    func resolve(for target: URL, on loop: EventLoop,
                 timeout: TimeAmount = .seconds(5), respectGlobalSwitch: Bool = true) -> EventLoopFuture<ExternalProxyConfig?> {
        guard enabled else { return loop.makeSucceededFuture(nil) }
        guard let host = target.host, !host.isEmpty else {
            return loop.makeFailedFuture(ExternalProxyError("无法解析 PAC 请求目标主机。"))
        }
        guard applies(to: host, respectGlobalSwitch: respectGlobalSwitch) else { return loop.makeSucceededFuture(nil) }
        if let issue = validationError { return loop.makeFailedFuture(ExternalProxyError(issue)) }
        if mode != .pac { return loop.makeSucceededFuture(self) }
        guard let proxyPACURL else {
            return loop.makeFailedFuture(ExternalProxyError("PAC URL 无效。"))
        }
        return PACResolver.resolve(config: self, script: proxyPACURL, target: target, on: loop, timeout: timeout)
    }
}

private enum PACResolver {
    // CFNetwork evaluates scripts on workers with a run loop. Bound simultaneous script work even
    // if an evaluation or system callback stalls after the caller's timeout.
    private static let workerSlots = DispatchSemaphore(value: 8)
    private struct FlightKey: Hashable {
        let config: ExternalProxyConfig
        let target: String
        let timeoutNanoseconds: Int64
    }
    private static let flightLock = NSLock()
    private struct Flight {
        let request: PACRequest
        var participants: Int
    }
    private static var flights: [FlightKey: Flight] = [:]
    private static let maxParticipants = 256

    static func resolve(config: ExternalProxyConfig, script: URL, target: URL, on loop: EventLoop,
                        timeout: TimeAmount) -> EventLoopFuture<ExternalProxyConfig?> {
        guard timeout.nanoseconds > 0 else {
            return loop.makeFailedFuture(ExternalProxyError("PAC 解析超时。"))
        }
        let key = FlightKey(config: config, target: target.absoluteString, timeoutNanoseconds: timeout.nanoseconds)
        flightLock.lock()
        if var existing = flights[key] {
            guard existing.participants < maxParticipants else {
                flightLock.unlock()
                return loop.makeFailedFuture(ExternalProxyError("PAC 解析繁忙，请重试。"))
            }
            existing.participants += 1
            flights[key] = existing
            flightLock.unlock()
            return existing.request.promise.futureResult.hop(to: loop)
        }
        guard workerSlots.wait(timeout: .now()) == .success else {
            flightLock.unlock()
            return loop.makeFailedFuture(ExternalProxyError("PAC 解析繁忙，请重试。"))
        }
        let request = PACRequest(loop, beforeCompletion: {
            flightLock.lock()
            flights.removeValue(forKey: key)
            flightLock.unlock()
        })
        flights[key] = Flight(request: request, participants: 1)
        flightLock.unlock()

        let timer = loop.scheduleTask(in: timeout) {
            request.finish(.failure(ExternalProxyError("PAC 解析超时。")))
        }
        request.promise.futureResult.whenComplete { _ in timer.cancel() }

        DispatchQueue.global(qos: .utility).async {
            defer { workerSlots.signal() }
            autoreleasepool {
                let runLoop = CFRunLoopGetCurrent()!
                var context = CFStreamClientContext(
                    version: 0, info: Unmanaged.passUnretained(request).toOpaque(),
                    retain: { value in
                        guard let value else { return nil }
                        _ = Unmanaged<PACRequest>.fromOpaque(value).retain()
                        return value
                    },
                    release: { value in
                        if let value { Unmanaged<PACRequest>.fromOpaque(value).release() }
                    }, copyDescription: nil)
                let callback: CFProxyAutoConfigurationResultCallback = { info, list, error in
                    let request = Unmanaged<PACRequest>.fromOpaque(info).takeUnretainedValue()
                    if let error {
                        let code = CFErrorGetCode(error)
                        request.finish(.failure(ExternalProxyError("PAC 下载或执行失败（\(code)）。")))
                        return
                    }
                    request.finish(Result { try PACResolver.firstRoute(list) })
                }
                let source: CFRunLoopSource
                do {
                    if script.isFileURL {
                        let text = try PACResolver.localScript(script)
                        // 新 SDK 将其导入为自动内存管理的 CFRunLoopSource（不再返回 Unmanaged）
                        source = CFNetworkExecuteProxyAutoConfigurationScript(text as CFString, target as CFURL,
                            callback, &context)
                    } else {
                        source = CFNetworkExecuteProxyAutoConfigurationURL(script as CFURL, target as CFURL,
                            callback, &context)
                    }
                } catch {
                    request.finish(.failure(error))
                    return
                }
                defer { CFRunLoopSourceInvalidate(source) }
                guard request.bind(to: runLoop) else { return }
                CFRunLoopAddSource(runLoop, source, .defaultMode)
                if !request.finished {
                    CFRunLoopRunInMode(.defaultMode, Double(timeout.nanoseconds) / 1_000_000_000, false)
                }
                request.finish(.failure(ExternalProxyError("PAC 未返回可用结果。")))
            }
        }
        return request.promise.futureResult
    }

    private static func localScript(_ url: URL) throws -> String {
        let limit = 256 * 1024
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, (1...limit).contains(size) else {
            throw ExternalProxyError("PAC 文件必须是 256 KiB 以内的普通文件。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let bytes = try handle.read(upToCount: 32 * 1024), !bytes.isEmpty {
            guard data.count + bytes.count <= limit else { throw ExternalProxyError("PAC 文件超过 256 KiB。") }
            data.append(bytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExternalProxyError("PAC 文件不是 UTF-8 文本。")
        }
        return text
    }

    private static func firstRoute(_ list: CFArray) throws -> ExternalProxyConfig? {
        guard let entries = list as? [[String: Any]], let first = entries.first,
              let type = first[kCFProxyTypeKey as String] as? String else {
            throw ExternalProxyError("PAC 未返回可用路由。")
        }
        if type == kCFProxyTypeNone as String { return nil }

        let mode: ExternalProxyConfig.Mode
        if type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String) {
            // CFNetwork calls PROXY for an HTTPS destination kCFProxyTypeHTTPS. It still uses
            // a plaintext HTTP tunnel to the proxy; it does not identify TLS-to-proxy.
            mode = .http
        } else if type == (kCFProxyTypeSOCKS as String) {
            guard first[kCFStreamPropertySOCKSVersion as String] as? String == kCFStreamSocketSOCKSVersion5 as String else {
                throw ExternalProxyError("PAC 未明确返回 SOCKS5 版本。")
            }
            mode = .socks5
        } else {
            throw ExternalProxyError("PAC 首选路由类型暂不支持。")
        }

        guard let rawHost = first[kCFProxyHostNameKey as String] as? String,
              let host = ExternalProxyHost(rawHost), let port = first[kCFProxyPortNumberKey as String] as? Int,
              (1...65535).contains(port) else {
            throw ExternalProxyError("PAC 返回了无效的代理主机或端口。")
        }
        var config = ExternalProxyConfig()
        config.enabled = true
        config.mode = mode
        config.host = host.name
        config.port = port
        return config
    }
}

private final class PACRequest: @unchecked Sendable {
    let promise: EventLoopPromise<ExternalProxyConfig?>
    private let lock = NSLock()
    private var complete = false
    private var runLoop: CFRunLoop?
    private let beforeCompletion: () -> Void

    init(_ loop: EventLoop, beforeCompletion: @escaping () -> Void) {
        promise = loop.makePromise(of: ExternalProxyConfig?.self)
        self.beforeCompletion = beforeCompletion
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }

    func bind(to runLoop: CFRunLoop) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !complete else { return false }
        self.runLoop = runLoop
        return true
    }

    func finish(_ outcome: Result<ExternalProxyConfig?, Error>) {
        lock.lock()
        guard !complete else { lock.unlock(); return }
        complete = true
        let runLoop = self.runLoop
        self.runLoop = nil
        lock.unlock()

        // Unpublish the flight before invoking the caller. Only concurrent lookups share a result.
        beforeCompletion()
        promise.completeWith(outcome)
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}
