import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS

struct HTTPOrigin: Hashable {
    let host: String
    let dialHost: String
    let port: Int
    let tls: Bool
    let cleartextHTTP2: Bool
    let external: ExternalProxyConfig?
    let clientIdentityID: UUID?

    init(host: String, dialHost: String, port: Int, tls: Bool) {
        let proxy = InterceptionConfig.shared.externalProxy.value
        self.init(host: host, dialHost: dialHost, port: port, tls: tls, external: proxy.applies(to: host) ? proxy : nil)
    }

    private init(host: String, dialHost: String, port: Int, tls: Bool, external: ExternalProxyConfig?) {
        self.host = host
        self.dialHost = dialHost
        self.port = port
        self.tls = tls
        cleartextHTTP2 = !tls && InterceptionConfig.shared.h2cUpstream.value.matches(host: host)
        self.external = external
        clientIdentityID = tls ? ClientTLSIdentities.shared.identity(for: host)?.id : nil
    }

    func resolvingProxy(path: String, tunnel: Bool = false, on loop: EventLoop) -> EventLoopFuture<Self> {
        guard let external, external.mode == .pac else { return loop.makeSucceededFuture(self) }
        let scheme = tls || tunnel ? "https" : "http"
        let authority = URLParser.authority(host: host, port: port, scheme: scheme)
        guard let url = URL(string: "\(scheme)://\(authority)\(path.hasPrefix("/") ? path : "/")") else {
            return loop.makeFailedFuture(ExternalProxyError("PAC 目标 URL 无效。"))
        }
        return external.resolve(for: url, on: loop).map {
            Self(host: self.host, dialHost: self.dialHost, port: self.port, tls: self.tls, external: $0)
        }
    }

    func connect(on loop: EventLoop, listenerPort: UInt16, resolver: TimedDNSResolver?,
                 initialize: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        if let external {
            // NIOSSL uses the socket peer for IP SAN verification when it cannot send an SNI name.
            if tls && URLParser.isIPAddress(host) {
                return loop.makeFailedFuture(ExternalProxyError("外部代理连接 HTTPS 时需要目标域名以验证证书。"))
            }
            return ExternalProxyConnector.connect(via: external, host: dialHost, port: port, on: loop,
                localListenerPort: Int(listenerPort), initialize: initialize)
        }
        return ClientBootstrap(group: loop)
            .connectTimeout(.seconds(20))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .resolver(resolver)
            .channelInitializer(initialize)
            .connect(host: dialHost, port: port)
    }

    var externalLabel: String? {
        external.map { "\($0.mode.rawValue) \(URLParser.authority(host: $0.host, port: $0.port, scheme: ""))" }
    }
}

struct ProxyConnectionDetails: Codable {
    var address: String?
    var dnsMilliseconds: Double?
    var tcpMilliseconds: Double?
    var tlsMilliseconds: Double?
    var alpn: String?
    var externalProxy: String?
    var reused = false
    var downstreamStream: Int?
    var upstreamStream: Int?
}

enum ProxyHTTP2Error: LocalizedError {
    case invalidHeaders, invalidAuthority, invalidMessage, negotiationTimeout, responseTimeout, connectionClosed, pushUnsupported
    case connectionLimit

    var errorDescription: String? {
        switch self {
        case .invalidHeaders: return "HTTP/2 头部字段无效"
        case .invalidAuthority: return "HTTP/2 目标与 CONNECT 主机不一致"
        case .invalidMessage: return "HTTP/2 报文顺序或长度无效"
        case .negotiationTimeout: return "上游 TLS 协商超时"
        case .responseTimeout: return "等待上游响应超时"
        case .connectionClosed: return "上游连接提前关闭"
        case .pushUnsupported: return "代理不接受服务端推送流"
        case .connectionLimit: return "上游连接池繁忙，请重试"
        }
    }
}

/// Prevent an HTTP/2-to-HTTP/1 conversion from interpreting invalid header bytes as HTTP/1 delimiters.
final class HTTP2HeaderValidation: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias InboundOut = HTTP2Frame.FramePayload

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        if case .headers(let frame) = payload {
            for field in frame.headers {
                let pseudo = field.name.hasPrefix(":")
                let name = pseudo ? field.name.dropFirst() : field.name[...]
                guard !name.isEmpty, name.utf8.allSatisfy(Self.isToken),
                      Self.validValue(field.value, pseudo: pseudo) else {
                    context.fireErrorCaught(ProxyHTTP2Error.invalidHeaders)
                    context.close(promise: nil)
                    return
                }
            }
        }
        context.fireChannelRead(data)
    }

    static func isToken(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
            || "!#$%&'*+-.^_`|~".utf8.contains(value)
    }

    static func validValue(_ value: String, pseudo: Bool = false) -> Bool {
        value.utf8.allSatisfy {
            pseudo ? $0 > 32 && $0 < 127 : ($0 == 9 || $0 >= 32) && $0 != 127
        }
    }
}

/// Connection pool scoped to one downstream HTTP/2 connection and its event loop.
final class HTTP2UpstreamPool: @unchecked Sendable {
    struct Exchange {
        let channel: Channel
        let protocolName: String
        let connection: ProxyConnectionDetails
        let connectedAt: Date
    }

    private struct Endpoint {
        let channel: Channel
        let multiplexer: HTTP2StreamMultiplexer?
        let connection: ProxyConnectionDetails
        let connectedAt: Date
    }

    private final class Dial {
        let promise: EventLoopPromise<Endpoint>
        var completed = false
        var claimed = false
        var closing = false
        var activeStreams = 0
        var idleSince: NIODeadline?
        var idleTimeout: Scheduled<Void>?
        weak var channel: Channel?
        var cleartextMultiplexer: HTTP2StreamMultiplexer?

        init(loop: EventLoop) { promise = loop.makePromise(of: Endpoint.self) }

        func complete(_ result: Result<Endpoint, Error>) {
            guard !completed else { return }
            completed = true
            promise.completeWith(result)
        }

        func stopIdleTimer() {
            idleTimeout?.cancel()
            idleTimeout = nil
            idleSince = nil
        }
    }

    private struct WaitingDial {
        let dial: Dial
        let origin: HTTPOrigin
        let negotiateHTTP2: Bool
        let timeout: Scheduled<Void>
    }

    private let loop: EventLoop
    private let listenerPort: UInt16
    private var tlsDials: [HTTPOrigin: Dial] = [:]
    // A slot is reserved before a dial starts and released when its parent has closed.
    private var parents: [ObjectIdentifier: Dial] = [:]
    private var waiting: [WaitingDial] = []
    private var draining = false
    private var closed = false
    private static let maxParents = 32
    private static let maxWaiting = 128
    private static let idleTimeout = TimeAmount.seconds(30)

    init(downstream: Channel, listenerPort: UInt16) {
        loop = downstream.eventLoop
        self.listenerPort = listenerPort
        downstream.closeFuture.whenComplete { [weak self] _ in self?.closeAll() }
    }

    func exchange(to origin: HTTPOrigin, path: String = "/", relay: HTTP2UpstreamRelay) -> EventLoopFuture<Exchange> {
        loop.assertInEventLoop()
        guard !closed else { return loop.makeFailedFuture(ProxyHTTP2Error.connectionClosed) }
        if origin.external?.mode == .pac {
            return origin.resolvingProxy(path: path, on: loop).flatMap { self.exchange(to: $0, path: path, relay: relay) }
        }
        guard origin.tls || origin.cleartextHTTP2 else {
            return dial(origin, negotiateHTTP2: false).promise.futureResult.flatMap {
                self.attachHTTP1($0, relay: relay)
            }
        }
        let existing = tlsDials[origin].flatMap { $0.closing ? nil : $0 }
        let dial = existing ?? self.dial(origin, negotiateHTTP2: true)
        if existing == nil {
            tlsDials[origin] = dial
            dial.promise.futureResult.whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let endpoint):
                    // An HTTP/1.1 socket can serve only the exchange that acquired it.
                    endpoint.channel.closeFuture.whenComplete { [weak self] _ in self?.remove(origin, dial: dial) }
                case .failure:
                    self.remove(origin, dial: dial)
                }
            }
        }

        return dial.promise.futureResult.flatMap { endpoint in
            guard !self.closed, !dial.closing else { return self.loop.makeFailedFuture(ProxyHTTP2Error.connectionClosed) }
            if let multiplexer = endpoint.multiplexer {
                dial.stopIdleTimer()
                dial.activeStreams += 1
                let promise = self.loop.makePromise(of: Channel.self)
                multiplexer.createStreamChannel(promise: promise) { child in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandlers([
                            HTTP2HeaderValidation(),
                            HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: origin.tls ? .https : .http),
                            relay,
                        ])
                    }
                }
                return promise.futureResult.map { child in
                    child.closeFuture.whenComplete { [weak self] _ in self?.releaseStream(dial) }
                    var details = endpoint.connection
                    details.reused = dial.claimed
                    dial.claimed = true
                    return Exchange(channel: child, protocolName: "HTTP/2", connection: details,
                                    connectedAt: endpoint.connectedAt)
                }.flatMapError { error in
                    self.remove(origin, dial: dial)
                    dial.closing = true
                    self.releaseStream(dial)
                    return self.loop.makeFailedFuture(error)
                }
            }
            if !dial.claimed && endpoint.channel.isActive {
                dial.claimed = true
                return self.attachHTTP1(endpoint, relay: relay)
            }
            return self.dial(origin, negotiateHTTP2: false).promise.futureResult.flatMap {
                self.attachHTTP1($0, relay: relay)
            }
        }
    }

    private func attachHTTP1(_ endpoint: Endpoint, relay: HTTP2UpstreamRelay) -> EventLoopFuture<Exchange> {
        let channel = endpoint.channel
        guard !closed, channel.isActive else { return loop.makeFailedFuture(ProxyHTTP2Error.connectionClosed) }
        return channel.pipeline.addHTTPClientHandlers().flatMap {
            channel.pipeline.addHandler(relay)
        }.map {
            Exchange(channel: channel, protocolName: "HTTP/1.1", connection: endpoint.connection,
                     connectedAt: endpoint.connectedAt)
        }.flatMapError { error in
            channel.close(promise: nil)
            return self.loop.makeFailedFuture(error)
        }
    }

    private func dial(_ origin: HTTPOrigin, negotiateHTTP2: Bool) -> Dial {
        let dial = Dial(loop: loop)
        if parents.count < Self.maxParents && waiting.isEmpty {
            startDial(dial, origin: origin, negotiateHTTP2: negotiateHTTP2)
        } else if waiting.count < Self.maxWaiting {
            let timeout = loop.scheduleTask(in: .seconds(25)) { [weak self, weak dial] in
                guard let self, let dial else { return }
                self.waiting.removeAll { $0.dial === dial }
                dial.complete(.failure(ProxyHTTP2Error.connectionLimit))
            }
            waiting.append(WaitingDial(dial: dial, origin: origin, negotiateHTTP2: negotiateHTTP2, timeout: timeout))
            drainWaitingDials()
        } else {
            dial.complete(.failure(ProxyHTTP2Error.connectionLimit))
        }
        return dial
    }

    private func startDial(_ dial: Dial, origin: HTTPOrigin, negotiateHTTP2: Bool) {
        let id = ObjectIdentifier(dial)
        parents[id] = dial
        let started = Date()
        let resolver = URLParser.isIPAddress(origin.dialHost) || origin.external != nil ? nil : TimedDNSResolver(loop: loop)
        origin.connect(on: loop, listenerPort: listenerPort, resolver: resolver) { channel in
                guard !dial.closing else {
                    return channel.eventLoop.makeFailedFuture(ProxyHTTP2Error.connectionClosed)
                }
                dial.channel = channel
                if origin.cleartextHTTP2 {
                    return Self.configureClient(channel).map { mux in dial.cleartextMultiplexer = mux }
                }
                guard origin.tls else { return channel.eventLoop.makeSucceededVoidFuture() }
                return UpstreamTrust.context(on: channel.eventLoop, enableHTTP2: negotiateHTTP2, host: origin.host)
                    .flatMapThrowing { context in
                    guard !dial.closing else { throw ProxyHTTP2Error.connectionClosed }
                    let sni = URLParser.isIPAddress(origin.host) ? nil : origin.host
                    let ssl = try NIOSSLClientHandler(context: context, serverHostname: sni)
                    let relay = TCPConnectionTiming()
                    let negotiation = ApplicationProtocolNegotiationHandler { result, channel in
                        let alpn: String?
                        if case .negotiated(let token) = result { alpn = token } else { alpn = nil }
                        let now = Date()
                        var details = ProxyConnectionDetails(address: channel.remoteAddress?.ipAddress,
                                                             dnsMilliseconds: resolver?.milliseconds, alpn: alpn,
                                                             externalProxy: origin.externalLabel)
                        if let connected = relay.tcpConnectedAt {
                            details.tcpMilliseconds = max(0, connected.timeIntervalSince(started) * 1000 - (resolver?.milliseconds ?? 0))
                            details.tlsMilliseconds = now.timeIntervalSince(connected) * 1000
                        }
                        if alpn == "h2" {
                            return Self.configureClient(channel)
                                .map { mux in
                                    dial.complete(.success(Endpoint(channel: channel, multiplexer: mux,
                                        connection: details, connectedAt: relay.tcpConnectedAt ?? now)))
                                }.flatMapError { error in
                                    dial.complete(.failure(error))
                                    channel.close(promise: nil)
                                    return channel.eventLoop.makeFailedFuture(error)
                                }
                        }
                        dial.complete(.success(Endpoint(channel: channel, multiplexer: nil, connection: details,
                                                       connectedAt: relay.tcpConnectedAt ?? now)))
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    try channel.pipeline.syncOperations.addHandlers([relay, ssl, negotiation])
                }
            }.whenComplete { result in
            switch result {
            case .failure(let error):
                dial.complete(.failure(error))
                self.parents.removeValue(forKey: id)
                self.drainWaitingDials()
            case .success(let channel):
                dial.channel = channel
                channel.closeFuture.whenComplete { [weak self] _ in
                    dial.closing = true
                    dial.stopIdleTimer()
                    dial.complete(.failure(ProxyHTTP2Error.connectionClosed))
                    self?.parents.removeValue(forKey: id)
                    self?.drainWaitingDials()
                }
                guard !self.closed, !dial.closing else {
                    channel.close(promise: nil)
                    return
                }
                if !origin.tls {
                    let now = Date()
                    let details = ProxyConnectionDetails(address: channel.remoteAddress?.ipAddress,
                                                         dnsMilliseconds: resolver?.milliseconds,
                                                         tcpMilliseconds: max(0, now.timeIntervalSince(started) * 1000 - (resolver?.milliseconds ?? 0)),
                                                         externalProxy: origin.externalLabel)
                    dial.complete(.success(Endpoint(channel: channel, multiplexer: dial.cleartextMultiplexer,
                                                   connection: details, connectedAt: now)))
                }
            }
        }
        let deadline = loop.scheduleTask(in: .seconds(25)) {
            dial.closing = true
            dial.complete(.failure(ProxyHTTP2Error.negotiationTimeout))
            dial.channel?.close(promise: nil)
        }
        dial.promise.futureResult.whenComplete { _ in deadline.cancel() }
    }

    private func releaseStream(_ dial: Dial) {
        dial.activeStreams -= 1
        guard dial.activeStreams == 0, !closed else { return }
        if dial.closing {
            dial.channel?.close(promise: nil)
        } else {
            dial.idleSince = .now()
            dial.idleTimeout = loop.scheduleTask(in: Self.idleTimeout) { [weak self, weak dial] in
                if let dial { self?.retire(dial) }
            }
            drainWaitingDials()
        }
    }

    private func retire(_ dial: Dial) {
        guard dial.activeStreams == 0, !dial.closing else { return }
        dial.closing = true
        dial.stopIdleTimer()
        dial.channel?.close(promise: nil)
    }

    private func drainWaitingDials() {
        guard !closed, !draining else { return }
        draining = true
        defer { draining = false }
        while !waiting.isEmpty {
            if parents.count >= Self.maxParents {
                guard !parents.values.contains(where: { $0.closing && $0.activeStreams == 0 }),
                      let oldest = parents.values.compactMap({ dial in dial.idleSince.map { ($0, dial) } })
                        .min(by: { $0.0 < $1.0 })?.1 else { return }
                retire(oldest)
                if parents.count >= Self.maxParents { return }
            }
            let next = waiting.removeFirst()
            next.timeout.cancel()
            startDial(next.dial, origin: next.origin, negotiateHTTP2: next.negotiateHTTP2)
        }
    }

    private static func configureClient(_ channel: Channel) -> EventLoopFuture<HTTP2StreamMultiplexer> {
        let settings = nioDefaultSettings + [HTTP2Setting(parameter: .enablePush, value: 0)]
        return channel.configureHTTP2Pipeline(mode: .client, initialLocalSettings: settings,
            inboundStreamInitializer: { child in child.eventLoop.makeFailedFuture(ProxyHTTP2Error.pushUnsupported) })
    }

    private func remove(_ origin: HTTPOrigin, dial: Dial) {
        if tlsDials[origin] === dial { tlsDials.removeValue(forKey: origin) }
    }

    private func closeAll() {
        closed = true
        let active = parents.values
        parents.removeAll()
        tlsDials.removeAll()
        for dial in active {
            dial.closing = true
            dial.stopIdleTimer()
            dial.complete(.failure(ProxyHTTP2Error.connectionClosed))
            dial.channel?.close(promise: nil)
        }
        let queued = waiting
        waiting.removeAll()
        for entry in queued {
            entry.timeout.cancel()
            entry.dial.complete(.failure(ProxyHTTP2Error.connectionClosed))
        }
    }
}

private final class TCPConnectionTiming: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var tcpConnectedAt: Date?

    func channelActive(context: ChannelHandlerContext) {
        tcpConnectedAt = Date()
        context.fireChannelActive()
    }
}
