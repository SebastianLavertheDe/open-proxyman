import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

extension ExternalProxyConfig {
    /// Final target decision. URL patterns are evaluated only once a request path is available.
    func applies(to host: String, url: String? = nil, respectGlobalSwitch: Bool = true) -> Bool {
        guard routingAvailable(host: host, respectGlobalSwitch: respectGlobalSwitch) else { return false }
        switch effectiveRoutingMode {
        case .all: return true
        case .bypass: return !matchesBypass(host)
        case .inclusive:
            return (includedTargets ?? []).contains { ExternalProxyTarget($0)?.matches(host: host, url: url) == true }
        }
    }

    /// A URL-inclusive rule cannot be discarded while only the CONNECT/host is
    /// known. HTTPOrigin retains it until resolvingProxy supplies the full URL.
    func couldApply(to host: String, respectGlobalSwitch: Bool = true) -> Bool {
        guard routingAvailable(host: host, respectGlobalSwitch: respectGlobalSwitch) else { return false }
        switch effectiveRoutingMode {
        case .all: return true
        case .bypass: return !matchesBypass(host)
        case .inclusive:
            return (includedTargets ?? []).contains { raw in
                guard let target = ExternalProxyTarget(raw) else { return false }
                return target.isURL || target.matches(host: host, url: nil)
            }
        }
    }

    private func routingAvailable(host: String, respectGlobalSwitch: Bool) -> Bool {
        guard enabled, !respectGlobalSwitch || RuleOrganizationStore.shared.isEnabled("external"),
              let target = ExternalProxyHost(host), !target.isLoopback else { return false }
        return true
    }

    private func matchesBypass(_ host: String) -> Bool {
        guard let host = ExternalProxyHost(host) else { return false }
        return (bypassHosts ?? []).contains { pattern in
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("*.") {
                guard let domain = ExternalProxyHost(String(trimmed.dropFirst(2))), domain.isDNS else { return false }
                return host.isDNS && host.name.hasSuffix("." + domain.name)
            }
            return ExternalProxyHost(trimmed)?.name == host.name
        }
    }

    func targetsLoopback(port listener: Int) -> Bool {
        enabled && mode != .pac && port == listener && ExternalProxyHost(host)?.isLoopback == true
    }

    var validationError: String? {
        if let includedTargets {
            guard includedTargets.count <= 256 else { return "包含目标最多 256 项。" }
            if let invalid = includedTargets.first(where: { ExternalProxyTarget($0) == nil }) {
                return "包含目标格式无效：\(String(invalid.prefix(128)))"
            }
        }
        if enabled, effectiveRoutingMode == .inclusive, includedTargets?.isEmpty != false {
            return "仅包含列表模式至少需要一个目标主机或 URL。"
        }
        if let invalid = (bypassHosts ?? []).first(where: { pattern in
            if pattern.hasPrefix("*.") {
                return ExternalProxyHost(String(pattern.dropFirst(2)))?.isDNS != true
            }
            return ExternalProxyHost(pattern) == nil
        }) { return "直连主机格式无效：\(invalid)" }
        if mode == .pac { return proxyPACURL == nil ? "请输入 HTTP、HTTPS 或本机文件的 PAC URL。" : nil }
        guard ExternalProxyHost(host) != nil else { return "请输入主机名、IPv4 或 IPv6 地址。" }
        guard (1...65535).contains(port) else { return "端口必须在 1–65535 之间。" }
        guard useAuth else { return nil }
        if username.isEmpty || password.isEmpty { return "请输入代理用户名和密码。" }
        if mode == .socks5 && (username.utf8.count > 255 || password.utf8.count > 255) {
            return "SOCKS5 用户名和密码各限 255 字节。"
        }
        if mode != .socks5 && (username.contains(":") || username.utf8.count + password.utf8.count > 4096) {
            return "HTTP Basic 用户名不能包含冒号，凭据总长限 4096 字节。"
        }
        if [username, password].contains(where: { $0.utf8.contains { $0 < 32 || $0 == 127 } }) {
            return "代理凭据包含控制字符。"
        }
        return nil
    }
}

struct ExternalProxyHost {
    let name: String
    private let ip: [UInt8]?
    var isDNS: Bool { ip == nil }

    init?(_ value: String) {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("[") && name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            self.name = name
            ip = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &text, socklen_t(text.count)) != nil else { return nil }
            self.name = String(cString: text)
            ip = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.utf8.count <= 253, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
        }) else { return nil }
        self.name = name
        ip = nil
    }

    var isLoopback: Bool {
        if let ip {
            if ip.count == 4 { return ip[0] == 127 }
            let local = Array(repeating: UInt8(0), count: 15) + [1]
            let mapped = ip.prefix(10).allSatisfy { $0 == 0 } && ip[10] == 255 && ip[11] == 255
            return ip == local || (mapped && ip[12] == 127)
        }
        return name == "localhost" || name.hasSuffix(".localhost")
    }

    func authority(port: Int) -> String {
        ip?.count == 16 ? "[\(name)]:\(port)" : "\(name):\(port)"
    }

    var socksAddress: [UInt8] {
        if let ip { return [ip.count == 4 ? 1 : 4] + ip }
        let bytes = Array(name.utf8)
        return [3, UInt8(bytes.count)] + bytes
    }
}

enum ExternalProxyConnector {
    /// Install the origin pipeline in initialize. Do not await origin handshake/data there:
    /// application bytes and channelActive are delivered after the initializer succeeds.
    static func connect(via config: ExternalProxyConfig, host: String, port: Int, on loop: EventLoop,
                        timeout: TimeAmount = .seconds(20), localListenerPort: Int? = nil,
                        initialize: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        guard config.mode != .pac else { return loop.makeFailedFuture(ExternalProxyError("请先解析 PAC 路由。")) }
        if let reason = config.validationError { return loop.makeFailedFuture(ExternalProxyError(reason)) }
        guard let endpoint = ExternalProxyHost(config.host), let target = ExternalProxyHost(host),
              (1...65535).contains(port) else {
            return loop.makeFailedFuture(ExternalProxyError("外部代理目标地址无效。"))
        }
        if target.isLoopback {
            guard port != localListenerPort else {
                return loop.makeFailedFuture(ExternalProxyError("目标不能指向 ProxyMirror 自身监听端口。"))
            }
            return ClientBootstrap(group: loop).connectTimeout(timeout)
                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .channelInitializer(initialize).connect(host: target.name, port: port)
        }
        if endpoint.name == target.name && config.port == port {
            return loop.makeFailedFuture(ExternalProxyError("目标与外部代理地址相同。"))
        }
        // Pause transport reads until both the handshake gate and optional proxy TLS are installed.
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
        return bootstrap.connect(host: endpoint.name, port: config.port).flatMap { channel in
            if config.port == localListenerPort,
               let address = channel.remoteAddress?.ipAddress,
               (ExternalProxyHost(address)?.isLoopback == true || address == channel.localAddress?.ipAddress) {
                channel.close(promise: nil)
                return loop.makeFailedFuture(ExternalProxyError("外部代理不能指向 ProxyMirror 自身。"))
            }
            let gate = ExternalProxyHandshake(config: config, target: target, port: port, timeout: timeout,
                                              loop: loop, initialize: initialize)
            let tls = config.mode == .https ? UpstreamTrust.context(on: loop).map(Optional.some)
                                            : loop.makeSucceededFuture(nil)
            return tls.flatMapThrowing { context in
                var handlers: [ChannelHandler] = []
                if let context {
                    handlers.append(try NIOSSLClientHandler(context: context,
                                                            serverHostname: endpoint.isDNS ? endpoint.name : nil))
                }
                handlers.append(gate)
                try channel.pipeline.syncOperations.addHandlers(handlers)
            }.flatMap {
                channel.setOption(ChannelOptions.autoRead, value: true)
            }.flatMap {
                gate.ready.futureResult
            }.flatMapError { error in
                channel.close(promise: nil)
                return loop.makeFailedFuture(error)
            }
        }
    }
}

struct ExternalProxyError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ExternalProxyHandshake: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Stage {
        case starting, proxyTLS, http, socksMethod, socksAuth, socksConnect, installing, ready, failed
    }

    let ready: EventLoopPromise<Channel>
    private let config: ExternalProxyConfig
    private let target: ExternalProxyHost
    private let port: Int
    private let timeout: TimeAmount
    private let initialize: (Channel) -> EventLoopFuture<Void>
    private var stage = Stage.starting
    private var timer: Scheduled<Void>?
    private var buffer = ByteBuffer()
    private var headerSearch = 0
    private var informationalResponses = 0

    init(config: ExternalProxyConfig, target: ExternalProxyHost, port: Int, timeout: TimeAmount,
         loop: EventLoop, initialize: @escaping (Channel) -> EventLoopFuture<Void>) {
        ready = loop.makePromise(of: Channel.self)
        self.config = config
        self.target = target
        self.port = port
        self.timeout = timeout
        self.initialize = initialize
    }

    func handlerAdded(context: ChannelHandlerContext) {
        timer = context.eventLoop.scheduleTask(in: timeout) { [weak self] in
            self?.fail(ExternalProxyError("外部代理握手超时。"), context: context)
        }
        switch config.mode {
        case .http: startHTTP(context)
        case .https: stage = .proxyTLS
        case .socks5:
            stage = .socksMethod
            send([5, 1, config.useAuth ? 2 : 0], context)
        case .pac: fail(ExternalProxyError("请先解析 PAC 路由。"), context: context)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if stage == .proxyTLS, case .handshakeCompleted(let protocolName)? = event as? TLSUserEvent {
            if protocolName == nil || protocolName == "http/1.1" {
                startHTTP(context)
            } else {
                fail(ExternalProxyError("HTTPS 代理未协商 HTTP/1.1。"), context: context)
            }
        } else if stage == .ready {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if stage == .ready {
            context.fireChannelRead(data)
            return
        }
        guard stage != .failed else { return }
        var bytes = unwrapInboundIn(data)
        buffer.writeBuffer(&bytes)
        do {
            try advance(context)
            if buffer.readableBytes > 256 * 1024, stage == .installing {
                throw ExternalProxyError("初始化期间的隧道缓存超过 256 KiB。")
            }
        } catch {
            fail(error, context: context)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if stage == .ready { context.fireChannelReadComplete() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if stage == .ready { context.fireChannelInactive() }
        else { fail(ExternalProxyError("外部代理在握手时关闭连接。"), context: context, close: false) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if stage == .ready { context.fireErrorCaught(error) }
        else { fail(error, context: context) }
    }

    private func startHTTP(_ context: ChannelHandlerContext) {
        stage = .http
        let authority = target.authority(port: port)
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if config.useAuth {
            let token = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        send(Array((request + "\r\n").utf8), context)
    }

    private func startSOCKSConnect(_ context: ChannelHandlerContext) {
        stage = .socksConnect
        send([5, 1, 0] + target.socksAddress + [UInt8(port >> 8), UInt8(port & 255)], context)
    }

    private func advance(_ context: ChannelHandlerContext) throws {
        while true {
            switch stage {
            case .http:
                guard let status = try readHTTPStatus() else { return }
                if (100..<200).contains(status), status != 101, informationalResponses < 8 {
                    informationalResponses += 1
                    continue
                }
                guard (200..<300).contains(status) else {
                    throw ExternalProxyError("外部 HTTP 代理拒绝 CONNECT（\(status)）。")
                }
                established(context)
                return
            case .socksMethod:
                guard let version: UInt8 = buffer.getInteger(at: buffer.readerIndex),
                      let method: UInt8 = buffer.getInteger(at: buffer.readerIndex + 1) else { return }
                buffer.moveReaderIndex(forwardBy: 2)
                guard version == 5, method == (config.useAuth ? 2 : 0) else {
                    throw ExternalProxyError("SOCKS5 代理未接受配置的认证方式。")
                }
                if config.useAuth {
                    stage = .socksAuth
                    let username = Array(config.username.utf8)
                    let password = Array(config.password.utf8)
                    send([1, UInt8(username.count)] + username + [UInt8(password.count)] + password, context)
                } else {
                    startSOCKSConnect(context)
                }
            case .socksAuth:
                guard let version: UInt8 = buffer.getInteger(at: buffer.readerIndex),
                      let status: UInt8 = buffer.getInteger(at: buffer.readerIndex + 1) else { return }
                buffer.moveReaderIndex(forwardBy: 2)
                guard version == 1, status == 0 else { throw ExternalProxyError("SOCKS5 用户名或密码验证失败。") }
                startSOCKSConnect(context)
            case .socksConnect:
                guard let length = try socksReplyLength() else { return }
                buffer.moveReaderIndex(forwardBy: length)
                established(context)
                return
            default:
                return
            }
        }
    }

    private func readHTTPStatus() throws -> Int? {
        let start = buffer.readerIndex
        let length = buffer.readableBytes
        let limit = 32 * 1024
        let last = min(length, limit) - 4
        if headerSearch <= last {
            for index in headerSearch...last {
                if buffer.getInteger(at: start + index, as: UInt32.self) == 0x0d0a0d0a {
                    let head = buffer.readString(length: index + 4) ?? ""
                    headerSearch = 0
                    let line = head.components(separatedBy: "\r\n").first ?? ""
                    let tokens = line.split(separator: " ", maxSplits: 2)
                    guard tokens.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(tokens[0]),
                          tokens[1].utf8.count == 3, let status = Int(tokens[1]),
                          (100...599).contains(status) else {
                        throw ExternalProxyError("外部 HTTP 代理返回了无效的状态行。")
                    }
                    return status
                }
            }
            headerSearch = last + 1
        }
        if length >= limit { throw ExternalProxyError("外部 HTTP 代理响应头超过 32 KiB。") }
        return nil
    }

    private func socksReplyLength() throws -> Int? {
        guard buffer.readableBytes >= 4 else { return nil }
        let start = buffer.readerIndex
        let version = buffer.getInteger(at: start, as: UInt8.self)
        let status = buffer.getInteger(at: start + 1, as: UInt8.self)
        let reserved = buffer.getInteger(at: start + 2, as: UInt8.self)
        guard version == 5, reserved == 0 else { throw ExternalProxyError("SOCKS5 CONNECT 响应无效。") }
        guard let status, status == 0 else {
            throw ExternalProxyError("SOCKS5 代理拒绝 CONNECT（\(status.map(String.init) ?? "?")）。")
        }
        let length: Int
        switch buffer.getInteger(at: start + 3, as: UInt8.self) {
        case 1: length = 10
        case 4: length = 22
        case 3:
            guard let count: UInt8 = buffer.getInteger(at: start + 4) else { return nil }
            guard count > 0 else { throw ExternalProxyError("SOCKS5 返回了空地址。") }
            length = 7 + Int(count)
        default: throw ExternalProxyError("SOCKS5 CONNECT 响应地址类型无效。")
        }
        return buffer.readableBytes >= length ? length : nil
    }

    private func established(_ context: ChannelHandlerContext) {
        stage = .installing
        initialize(context.channel).whenComplete { result in
            guard self.stage == .installing else { return }
            do {
                try result.get()
                guard context.channel.isActive else { throw ChannelError.ioOnClosedChannel }
                self.timer?.cancel()
                self.stage = .ready
                context.fireChannelActive()
                if let leftover = self.buffer.readSlice(length: self.buffer.readableBytes), leftover.readableBytes > 0 {
                    context.fireChannelRead(self.wrapInboundOut(leftover))
                    context.fireChannelReadComplete()
                }
                context.pipeline.syncOperations.removeHandler(self).whenComplete { removal in
                    switch removal {
                    case .success where context.channel.isActive: self.ready.succeed(context.channel)
                    case .success: self.ready.fail(ChannelError.ioOnClosedChannel)
                    case .failure(let error): self.ready.fail(error)
                    }
                }
            } catch {
                self.fail(error, context: context)
            }
        }
    }

    private func send(_ bytes: [UInt8], _ context: ChannelHandlerContext) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { [weak self] error in self?.fail(error, context: context) }
        context.writeAndFlush(NIOAny(ByteBuffer(bytes: bytes)), promise: promise)
    }

    private func fail(_ error: Error, context: ChannelHandlerContext, close: Bool = true) {
        guard stage != .failed, stage != .ready else { return }
        stage = .failed
        timer?.cancel()
        ready.fail(error)
        if close { context.close(promise: nil) }
    }
}
