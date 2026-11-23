import Foundation
import NIOCore
import NIOPosix
import NIOHTTP2
import NIOSSL
import NIOTLS
import Darwin

// MARK: - 事件桥接（引擎线程 → 主线程 UI）

protocol TrafficSink: AnyObject {
    func transactionCreated(_ tx: Transaction)
    func transactionUpdated(_ tx: Transaction)
    func transactionBodyUpdated(_ tx: Transaction)
}

extension TrafficSink {
    func transactionBodyUpdated(_ tx: Transaction) {}
}

func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
}

// MARK: - 引擎

final class ProxyEngine: @unchecked Sendable {

    static let shared = ProxyEngine()

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
    private var serverChannel: Channel?
    private var lanChannel: Channel?
    private let stateLock = NSLock()
    private var transparentIngress: TransparentProxyIngress?
    private let clientsLock = NSLock()
    private var acceptingClients = false
    private var clients: [ObjectIdentifier: Channel] = [:]
    private(set) var isRunning = false
    private(set) var port: UInt16 = 9090
    private(set) var lanAccess: LANAccess?

    private let recording = LockedBox(true)
    private let limit = LockedBox(20 * 1024 * 1024)
    private let mitm = LockedBox(true)
    private let http2 = LockedBox(true)
    private let excludedHosts = LockedBox<[String]>([])
    private let breakpointWait = LockedBox(TimeAmount.seconds(60))
    var breakpointTimeout: TimeAmount {
        get { breakpointWait.value }
        set { breakpointWait.set(newValue) }
    }
    private let breakpointSession = LockedBox(UUID())
    var breakpointSessionID: UUID { breakpointSession.value }
    func clearBreakpointSession() { breakpointSession.set(UUID()) }
    var recordingEnabled: Bool {
        get { recording.value }
        set { recording.set(newValue) }
    }
    var captureLimit: Int {
        get { limit.value }
        set { limit.set(max(0, newValue)) }
    }
    var mitmEnabled: Bool {
        get { mitm.value }
        set { mitm.set(newValue) }
    }
    var http2Enabled: Bool {
        get { http2.value }
        set { http2.set(newValue) }
    }
    /// 不做 MITM 的主机（支持 *.example.com / example.com）
    var mitmExcludedHosts: [String] {
        get { excludedHosts.value }
        set { excludedHosts.set(newValue) }
    }
    weak var sink: TrafficSink?

    var listenAddress: String { "127.0.0.1:\(port)" }

    func start(port: UInt16, lan: LANAccess? = nil) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isRunning else { return }
        if let lan, !lan.valid { throw ProxyError.invalidLANAccess }
        clientsLock.lock()
        acceptingClients = true
        clientsLock.unlock()
        func bootstrap(policy: NetworkAccessPolicy?) -> ServerBootstrap {
            ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeFailedFuture(ProxyError.shutdown) }
                if let policy {
                    guard let peer = channel.remoteAddress?.ipAddress, policy.allows(peer) else {
                        return channel.eventLoop.makeFailedFuture(ProxyError.unapprovedDevice)
                    }
                }
                guard self.track(channel) else { return channel.eventLoop.makeFailedFuture(ProxyError.shutdown) }
                let conn = ConnState(engine: self)
                let sniffer = SniPeekHandler(state: conn)
                let proxy = ProxyConnectionHandler(conn: conn)
                conn.proxyHandler = proxy
                conn.snifferHandler = sniffer
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([SOCKS5ProxyHandshake(conn: conn), sniffer, proxy])
                }
            }
        }

        let channel: Channel
        do {
            channel = try bootstrap(policy: nil).bind(host: "127.0.0.1", port: Int(port)).wait()
            if let lan {
                do {
                    guard let policy = lan.peerPolicy else { throw ProxyError.invalidLANAccess }
                    lanChannel = try bootstrap(policy: policy).bind(host: lan.address,
                        port: channel.localAddress?.port ?? Int(port)).wait()
                } catch {
                    try? channel.close().wait()
                    throw error
                }
            }
        } catch {
            clientsLock.lock()
            acceptingClients = false
            clientsLock.unlock()
            throw error
        }
        self.port = UInt16(channel.localAddress?.port ?? Int(port))
        lanAccess = lan
        serverChannel = channel
        isRunning = true
        NSLog("[ProxyMirror] 代理已启动 127.0.0.1:\(self.port)")
    }

    func startTransparentIngress() throws -> (port: UInt16, token: String) {
        try stateLock.withLock {
            guard isRunning else { throw TransparentProxyIngress.Failure.unavailable }
            if let ingress = transparentIngress, let port = ingress.port { return (port, ingress.token) }
            let ingress = TransparentProxyIngress()
            try ingress.start(group: group, engine: self)
            guard let port = ingress.port else {
                ingress.stop()
                throw TransparentProxyIngress.Failure.unavailable
            }
            transparentIngress = ingress
            return (port, ingress.token)
        }
    }

    func stopTransparentIngress() {
        stateLock.withLock {
            transparentIngress?.stop()
            transparentIngress = nil
        }
    }

    func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard isRunning else { return }
        transparentIngress?.stop()
        transparentIngress = nil
        clientsLock.lock()
        acceptingClients = false
        let children = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()
        try? serverChannel?.close().wait()
        try? lanChannel?.close().wait()
        for child in children { child.close(promise: nil) }
        serverChannel = nil
        lanChannel = nil
        lanAccess = nil
        isRunning = false
        NSLog("[ProxyMirror] 代理已停止")
    }

    private func track(_ channel: Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        clientsLock.lock()
        let accepting = acceptingClients
        if accepting { clients[id] = channel }
        clientsLock.unlock()
        if accepting {
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                self.clientsLock.lock()
                self.clients.removeValue(forKey: id)
                self.clientsLock.unlock()
            }
        }
        return accepting
    }
}

enum ProxyError: LocalizedError {
    case shutdown, invalidLANAccess, unapprovedDevice

    var errorDescription: String? {
        switch self {
        case .shutdown: return "代理已停止"
        case .invalidLANAccess: return "选择明确的本机局域网地址，并填写至少一个有效的设备 IP 或 CIDR 范围。"
        case .unapprovedDevice: return "此设备未加入代理访问名单"
        }
    }
}

struct LANAccess: Equatable {
    let address: String
    let device: String
    let allowedPeerRanges: [String]

    init(address: String, device: String, allowedPeerRanges: [String] = []) {
        self.address = address
        self.device = device
        self.allowedPeerRanges = allowedPeerRanges
    }

    var peerPolicy: NetworkAccessPolicy? {
        let ranges = allowedPeerRanges.isEmpty ? (device.isEmpty ? [] : [device]) : allowedPeerRanges
        guard !ranges.isEmpty else { return nil }
        return try? NetworkAccessPolicy(ranges: ranges)
    }

    var valid: Bool {
        guard Self.addresses.contains(address), let local = NumericIPAddress(address), local.isUnicast,
              !local.isLoopback, let policy = peerPolicy, !policy.ranges.isEmpty else { return false }
        if allowedPeerRanges.isEmpty {
            guard local.bytes.count == 4, let peer = NumericIPAddress(device), peer.bytes.count == 4, peer.isUnicast,
                  !peer.isLoopback, peer.description != local.description else { return false }
        }
        return true
    }

    static var addresses: [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [] }
        defer { freeifaddrs(list) }
        var result = Set<String>()
        for item in sequence(first: list, next: { $0.pointee.ifa_next }) {
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.pointee.ifa_addr,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if let parsed = NumericIPAddress(value), parsed.isUnicast, !parsed.isLoopback { result.insert(value) }
            }
        }
        return result.sorted { lhs, rhs in
            let lhsV4 = NumericIPAddress(lhs)?.bytes.count == 4
            let rhsV4 = NumericIPAddress(rhs)?.bytes.count == 4
            return lhsV4 == rhsV4 ? lhs < rhs : lhsV4
        }
    }
}

// MARK: - 每连接共享状态

final class ConnState {
    let engine: ProxyEngine
    let reverseRoute: ReverseProxyRoute?
    weak var proxyHandler: ProxyConnectionHandler?
    weak var snifferHandler: SniPeekHandler?
    /// CONNECT 之后武装嗅探器（缓冲 ClientHello 直到决策完成）
    var snifferArmed = false
    var awaitingCertificate = false
    /// CONNECT authority 里的目标主机
    var resolvedConnectHost: String?
    var sniffedServerName: String?
    var resolvedConnectPort = 443
    var clientApplication: ProcessAppInfo?
    var transparentFlow: TransparentProxyFlow?
    var http2WebSocket: HTTP2WebSocketRequest?
    var isSOCKS5 = false
    var sslRules = RulesSnapshot()

    init(engine: ProxyEngine, reverseRoute: ReverseProxyRoute? = nil) {
        self.engine = engine
        self.reverseRoute = reverseRoute
    }

    func allowsMITM(host: String) -> Bool {
        engine.mitmEnabled && !engine.mitmExcludedHosts.contains { Self.hostMatches(host: host, pattern: $0) }
    }

    func shouldMITM(host: String) -> Bool {
        allowsMITM(host: host) && sslRules.shouldSSLProxy(host: host, application: transparentFlow?.application ?? clientApplication?.bundleID)
    }

    static func hostMatches(host: String, pattern: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let h = host.lowercased()
        if p == h { return true }
        if p.hasPrefix("*.") {
            let rest = String(p.dropFirst(2))
            return h.hasSuffix("." + rest)
        }
        return false
    }
}

// MARK: - SNI 嗅探 Handler（TLS 握手前缓冲 ClientHello，动态注入 MITM 证书）

final class SniPeekHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let state: ConnState
    private var buffered: [ByteBuffer] = []
    private var bufferedBytes = 0
    private var helloBytes: [UInt8] = []
    private var decided = false

    init(state: ConnState) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !state.snifferArmed || decided {
            context.fireChannelRead(data)
            return
        }
        let bytes = unwrapInboundIn(data)
        guard bytes.readableBytes <= 1_048_576 - bufferedBytes, buffered.count < 1024 else {
            context.close(promise: nil)
            return
        }
        buffered.append(bytes)
        bufferedBytes += bytes.readableBytes
        guard !state.awaitingCertificate else { return }
        helloBytes.append(contentsOf: bytes.readableBytesView)

        let result = ClientHelloSniffer.parse(helloBytes)
        guard result.complete else { return }
        state.sniffedServerName = result.sni
        let connectHost = state.resolvedConnectHost ?? "unknown"
        let certHost = result.sni ?? connectHost
        guard helloBytes.first == 0x16, state.shouldMITM(host: certHost) else {
            finishDecision(context, host: nil)
            return
        }

        state.awaitingCertificate = true
        state.proxyHandler?.refreshReads()
        let loop = context.eventLoop
        let handler = NIOLoopBound((self, context), eventLoop: loop)
        CertificateAuthority.shared.leafContext(forHost: certHost, enableHTTP2: state.engine.http2Enabled) { tls in
            loop.execute {
                let (sniffer, context) = handler.value
                guard context.channel.isActive else { return }
                guard let tls else { sniffer.finishDecision(context, host: nil); return }
                sniffer.installTLS(tls, context: context, certHost: certHost, connectHost: connectHost)
            }
        }
    }

    private func installTLS(_ tls: NIOSSLContext, context: ChannelHandlerContext, certHost: String, connectHost: String) {
        let ssl = NIOSSLServerHandler(context: tls)
        let negotiation = ApplicationProtocolNegotiationHandler { [state] result, channel in
            guard result == .negotiated("h2"), let proxy = state.proxyHandler else {
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            return channel.pipeline.removeHandler(proxy).flatMap {
                configureHTTP2Proxy(channel, engine: state.engine, host: state.transparentFlow == nil ? connectHost : certHost,
                                    port: state.resolvedConnectPort, clientApplication: state.clientApplication,
                                    transparentFlow: state.transparentFlow)
            }
        }
        do {
            try context.pipeline.syncOperations.addHandlers([ssl, negotiation], position: .after(self))
            finishDecision(context, host: certHost)
        } catch {
            NSLog("[ProxyMirror] 添加 TLS handler 失败: \(error)")
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        buffered.removeAll()
        helloBytes.removeAll()
        context.fireChannelInactive()
    }

    private func finishDecision(_ context: ChannelHandlerContext, host: String?) {
        decided = true
        state.awaitingCertificate = false
        state.proxyHandler?.clientHelloResolved(mitmHost: host, socksHTTP: state.isSOCKS5 &&
            ["GET ", "POST ", "PUT ", "PATCH ", "DELETE ", "HEAD ", "OPTIONS ", "TRACE ", "QUERY "].contains {
                String(decoding: helloBytes.prefix(8), as: UTF8.self).hasPrefix($0)
            })
        state.proxyHandler?.refreshReads()
        for bytes in buffered {
            context.fireChannelRead(wrapInboundOut(bytes))
        }
        buffered.removeAll()
        helloBytes.removeAll()
        context.fireChannelReadComplete()
        context.channel.pipeline.removeHandler(self, promise: nil)
    }
}

// MARK: - 上游中继 Handler

final class UpstreamRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private weak var conn: ProxyConnectionHandler?

    init(conn: ProxyConnectionHandler) {
        self.conn = conn
    }

    func channelActive(context: ChannelHandlerContext) {
        conn?.upstreamConnected(context.channel)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        conn?.handleUpstreamData(unwrapInboundIn(data), channel: context.channel)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        conn?.upstreamWritabilityChanged(context.channel)
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        conn?.upstreamFailed(error, channel: context.channel)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        conn?.upstreamClosed(context.channel)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read {
            conn?.upstreamReadTimeout(context.channel)
        }
        if let tls = event as? TLSUserEvent, case .handshakeCompleted(let protocolName) = tls {
            conn?.upstreamTLSReady(context.channel, protocolName: protocolName)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

// MARK: - 客户端连接处理（状态机核心；全部方法运行在连接自己的 event loop 上）

final class ProxyConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let conn: ConnState
    private let tunnelRules: () -> RulesSnapshot
    private let requestRules: () -> RulesSnapshot
    private weak var clientChannel: Channel?

    enum Mode {
        case readingHead        // 等待下一个请求头
        case inFlight           // 请求在途
        case requestPaused
        case responsePaused
        case finishingResponse   // 等待当前响应写入客户端，保持流水线顺序
        case resolvingConnect   // 查询客户端应用后再应答 CONNECT
        case resolvingLocal     // 在后台打开 Map Local 文件
        case sendingLocal       // 分块发送 Map Local 文件
        case tunnelConnecting   // 裸隧道，上游连接中
        case tunnelRelay        // 裸隧道转发中
        case tlsPending         // MITM TLS 握手中（数据由 sniffer 缓冲）
        case wsRelay            // WebSocket 双向裸中继
        case closed
    }

    private var mode: Mode = .readingHead

    // 请求头解析
    private var headParser = RequestHeadParser()

    // 当前请求上下文
    private var tx: Transaction?
    private var diagnosticHeaders = DiagnosticHeaders()
    private var bodyCapture: TransactionCapture?
    private var mapLocalSender: MapLocalSender?
    private struct BreakpointTarget {
        let method: String
        let scheme: String
        let host: String
        let path: String
        let query: String
        let url: String

        init(_ tx: Transaction) {
            method = tx.method
            scheme = tx.scheme
            host = tx.host
            path = tx.path
            query = tx.query
            url = tx.fullURL
        }

        func rule(for phase: BreakpointRule.Phase) -> BreakpointRule? {
            guard BreakpointManager.enabledSnapshot.value, RuleOrganizationStore.shared.isEnabled("breakpoints") else { return nil }
            return InterceptionConfig.shared.breakpoints.value.first {
                $0.enabled && RuleOrganizationStore.shared.ruleIsEnabled(tool: "breakpoints", id: $0.id) &&
                    $0.rule.enabled && $0.phase == phase &&
                    $0.rule.matches(method: method, scheme: scheme, host: host, path: path, query: query, fullURL: url)
            }
        }

        var scripting: ScriptingTarget {
            ScriptingTarget(method: method, scheme: scheme, host: host, path: path, query: query, url: url)
        }
    }

    private final class BreakpointGate {
        let id = UUID()
        let head: BreakpointHead
        let source: Channel
        let rule: BreakpointRule?
        let script: ScriptingPlan?
        let captureBytes: Int?
        let deadline: Date
        let session: UUID
        var body = Data()
        var following: [ByteBuffer] = []
        var followingBytes = 0
        var submitted = false
        var sourceClosed = false
        var timer: Scheduled<Void>?

        init(head: BreakpointHead, source: Channel, rule: BreakpointRule?, script: ScriptingPlan?,
             captureBytes: Int?, deadline: Date, session: UUID) {
            self.head = head
            self.source = source
            self.rule = rule
            self.script = script
            self.captureBytes = captureBytes
            self.deadline = deadline
            self.session = session
        }

        var label: String? { rule.map { $0.rule.name.isEmpty ? $0.rule.summary : $0.rule.name } }
    }

    private var breakpointTarget: BreakpointTarget?
    private var breakpointGate: BreakpointGate?
    private var scriptingOperationName: String?
    private var upstreamChannel: Channel?
    private var upstreamOrigin: HTTPOrigin?
    private var upstreamResolver: TimedDNSResolver?
    private var upstreamDialAt: Date?
    private var upstreamConnectedAt: Date?
    private var http2DownstreamStreamID: Int?
    private var upstreamConnection: ProxyConnectionDetails?
    private var upstreamReusable = false

    // 请求 body 跟踪
    private var reqChunked: ChunkedTracker?
    private var reqRemainingCL: Int?
    private var pendingToUpstream: [ByteBuffer] = []
    private var pendingUploadBytes = 0
    private var pendingHeadBytes: Data?
    private var upstreamReady = false
    private var keepAlive = true
    private var simulation = LatencySimulation()
    private var simulatedDelay: Scheduled<Void>?
    private var uploadPacer: BytePacingQueue?
    private var downloadPacer: BytePacingQueue?
    private var responseWriteCompletion: ((Result<Void, Error>) -> Void)?
    private var closeAfterResponse = false

    // 响应跟踪
    private var respParser = ResponseHeadParser()
    private var respHeadParsed = false
    private var respChunked: ChunkedTracker?
    private var respRemainingCL: Int?
    private var respCloseDelimited = false
    private var respShouldClose = false
    private var stoppedUpload = false
    private var responseStart = Date()

    // pipelining 缓冲
    private var pipelined: [ByteBuffer] = []
    private var pipelinedBytes = 0
    private static let pipelineHighWatermark = 384 * 1024
    private static let pipelineHighParts = 128
    private static let maxBufferedBytes = 4 * 1024 * 1024
    private static let maxBufferedParts = 1024

    // CONNECT 上下文
    private var connectTx: Transaction?
    private var socksReplyPending = false
    private var wsUpstreamInterceptor: WSRelayInterceptor?
    private var wsDownstreamInterceptor: WSRelayInterceptor?
    private var connectAttributionTimeout: Scheduled<Void>?
    private var earlyConnectBytes: [ByteBuffer] = []
    private var earlyConnectByteCount = 0
    /// MITM 后该连接上的明文请求都是 https origin-form
    private var mitmActive = false
    private var downstreamShutdownStarted = false
    private var downstreamInputClosed = false

    init(conn: ConnState, tunnelRules: @escaping () -> RulesSnapshot = { RulesStore.shared.snapshot() },
         requestRules: @escaping () -> RulesSnapshot = { RulesStore.shared.snapshot() }) {
        self.conn = conn
        self.tunnelRules = tunnelRules
        self.requestRules = requestRules
    }

    func handlerAdded(context: ChannelHandlerContext) {
        clientChannel = context.channel
        if conn.http2WebSocket != nil {
            context.channel.getOption(HTTP2StreamChannelOptions.streamID).whenSuccess { streamID in
                self.http2DownstreamStreamID = Int(streamID)
            }
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        clientChannel = context.channel
    }

    // MARK: 客户端数据入口

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        refreshReads()
        mapLocalSender?.resume()
        context.fireChannelWritabilityChanged()
    }

    fileprivate func upstreamWritabilityChanged(_ channel: Channel) {
        if channel === upstreamChannel { refreshReads() }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        receiveClientBytes(unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard conn.transparentFlow != nil || conn.http2WebSocket != nil, (event as? ChannelEvent) == .inputClosed else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        downstreamInputClosed = true
        switch mode {
        case .readingHead, .tlsPending, .resolvingConnect:
            closeClient()
        case .tunnelRelay:
            upstreamChannel?.close(mode: .output, promise: nil)
        case .wsRelay:
            finishWebSocketUpload()
        case .inFlight, .requestPaused, .responsePaused:
            if (reqRemainingCL ?? 0) > 0 || reqChunked != nil { closeClient() }
        default:
            // If a tunnel is still connecting, forward FIN after the buffered bytes.
            break
        }
    }

    private func receiveClientBytes(_ bb: ByteBuffer) {
        switch mode {
        case .readingHead:
            tryParseRequestHead(with: bb)
        case .inFlight:
            forwardRequestBody(bb)
        case .requestPaused:
            collectBreakpointBytes(bb)
        case .responsePaused:
            forwardRequestBody(bb)
        case .finishingResponse, .sendingLocal:
            if !closeAfterResponse { _ = bufferPipeline(bb) }
        case .resolvingLocal:
            _ = bufferPipeline(bb)
        case .resolvingConnect:
            bufferConnectBytes(bb)
        case .tunnelConnecting:
            _ = bufferUpload(bb)
        case .tunnelRelay:
            upstreamChannel?.writeAndFlush(NIOAny(bb), promise: nil)
        case .tlsPending:
            break
        case .wsRelay:
            if let interceptor = wsUpstreamInterceptor {
                interceptor.feed(Data(copyOf(bb)))
            } else {
                writeWebSocketUpstream(bb)
                bodyCapture?.append(bb.readableBytesView, direction: .upstream, webSocket: true)
            }
        case .closed:
            break
        }
    }

    // MARK: 请求头解析

    private func tryParseRequestHead(with bb: ByteBuffer) {
        let data = Data(copyOf(bb))
        var head: HTTPRequestHead?
        do {
            head = try headParser.feed(data)
        } catch {
            writeRawAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        guard let req = head else { return }
        // 头部之后同批到达的 body 字节
        let trailing = headParser.trailing
        if req.method == "CONNECT", conn.reverseRoute == nil {
            guard conn.transparentFlow == nil else {
                writeRawAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            startConnect(req, trailing: trailing)
            return
        }
        handleRequestHead(req)
        if !trailing.isEmpty { receiveClientBytes(ByteBuffer(bytes: trailing)) }
    }

    private func handleRequestHead(_ originalRequest: HTTPRequestHead) {
        responseStart = Date()

        let req: HTTPRequestHead
        if let reverse = conn.reverseRoute {
            guard let routed = reverse.forward(originalRequest) else {
                writeRawAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            req = routed
        } else {
            req = originalRequest
        }

        // MITM 隧道上的明文请求都是 https
        let https = mitmActive || (conn.transparentFlow == nil && req.target.lowercased().hasPrefix("https://"))

        // 解析目标：absolute-form 或 Host 头
        let parsed = URLParser.parse(target: req.target)
        let host: String
        let port: Int
        let path: String
        if let p = parsed, let h = p.host {
            host = h; port = p.port; path = p.path
        } else if let hostHeader = req.headers.value(of: "Host") {
            let scheme = https ? "https" : "http"
            guard let parsed = URLParser.parse(target: "\(scheme)://\(hostHeader)"), let parsedHost = parsed.host else {
                writeRawAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            host = parsedHost
            port = parsed.port
            path = req.target.isEmpty ? "/" : req.target
        } else {
            writeRawAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }

        let (pathOnly, query) = splitQueryPath(path)

        let recording = conn.engine.recordingEnabled
        let tx = Transaction(captureBudget: recording ? .live : nil)
        tx.method = conn.http2WebSocket == nil ? req.method : "CONNECT"
        tx.scheme = conn.http2WebSocket?.scheme ?? (https ? "https" : "http")
        tx.host = host
        tx.port = conn.transparentFlow?.port ?? port
        tx.path = pathOnly
        tx.query = query
        tx.requestHeaders = conn.http2WebSocket?.captureHeaders(req.headers) ?? req.headers
        tx.requestVersion = conn.http2WebSocket == nil ? req.version : "HTTP/2"
        if conn.http2WebSocket != nil { tx.responseVersion = "HTTP/2" }
        tx.captureLimit = recording ? conn.engine.captureLimit : 0
        tx.peerPort = UInt16(clientChannel?.remoteAddress?.port ?? 0)
        tx.clientAddress = clientChannel?.remoteAddress?.ipAddress
        tx.setClientApplication(conn.clientApplication)
        conn.transparentFlow?.mark(tx)
        tx.isTLSIntercepted = conn.http2WebSocket != nil || (conn.reverseRoute == nil && https)
        tx.originalURL = conn.reverseRoute?.clientURL(target: originalRequest.target)
        tx.state = .awaiting
        self.tx = tx
        diagnosticHeaders = DiagnosticHeaders(requestID: tx.id)
        if recording, let loop = clientChannel?.eventLoop {
            bodyCapture = TransactionCapture(transaction: tx, on: loop, sink: conn.engine.sink)
        }
        let target = BreakpointTarget(tx)
        breakpointTarget = target
        let breakpoint = target.rule(for: .request)
        let script = ScriptingService.plan(for: target.scripting, phase: .request)
        if breakpoint != nil || script != nil, let clientChannel {
            let bodyLength = req.headers.contains("Content-Length") ? fixedBreakpointLength(req.headers) : 0
            let capture = req.headers.contains("Expect") || req.headers.contains("Transfer-Encoding") ? nil : bodyLength
            mode = .requestPaused
            startBreakpoint(.request(req), source: clientChannel, rule: breakpoint, script: script, capture: capture)
            return
        }
        routeRequest(req, transaction: tx)
    }

    private func routeRequest(_ req: HTTPRequestHead, transaction tx: Transaction) {
        // body framing
        let teHeader = (req.headers.value(of: "Transfer-Encoding") ?? "").lowercased()
        if teHeader.contains("chunked") {
            reqChunked = ChunkedTracker()
            tx.requestBodyComplete = false
        } else if let cl = req.headers.value(of: "Content-Length"), let n = Int(cl), n > 0 {
            reqRemainingCL = n
            tx.requestBodyComplete = false
        } else {
            tx.requestBodyComplete = true
        }

        keepAlive = conn.http2WebSocket == nil && !HTTPClientWantsClose(req)
        // Block → Allow → Map Local → Map Remote → No Caching
        let rules = requestRules()
        let url = tx.fullURL

        // Block List / Allow List
        if rules.isBlocked(url: url) {
            tx.matchedByBlock = true
            diagnosticHeaders.record(.block)
            finishWithSynthesizedResponse(tx: tx, status: 403, reason: "Forbidden",
                                          contentType: "text/plain",
                                          body: Data("ProxyMirror: blocked by Block List".utf8))
            return
        }
        if !rules.isAllowed(url: url) {
            tx.matchedByBlock = true
            diagnosticHeaders.record(.block)
            finishWithSynthesizedResponse(tx: tx, status: 403, reason: "Forbidden",
                                          contentType: "text/plain",
                                          body: Data("ProxyMirror: not in Allow List".utf8))
            return
        }

        if let channel = clientChannel,
           let lookup = rules.prepareMapLocalResponse(for: url, includeBody: tx.method != "HEAD", on: channel.eventLoop) {
            mode = .resolvingLocal
            refreshReads()
            lookup.whenComplete { [weak self] result in
                guard let self, self.mode == .resolvingLocal, self.tx === tx, channel.isActive else { return }
                switch result {
                case .success(let hit?):
                    tx.matchedByMapLocal = true
                    self.diagnosticHeaders.record(.mapLocal)
                    self.finishWithSynthesizedResponse(tx: tx, status: hit.status, reason: TrafficStore.reason(for: hit.status),
                        contentType: hit.contentType, body: ByteBuffer(), contentLength: hit.contentLength,
                        extraHeaders: hit.headers, file: hit.body)
                case .success(nil):
                    let buffered = self.pipelined
                    self.pipelined.removeAll()
                    self.pipelinedBytes = 0
                    self.routeUpstream(req, transaction: tx, rules: rules, url: url)
                    for bytes in buffered { self.receiveClientBytes(bytes) }
                case .failure(let error):
                    self.finishWithSynthesizedResponse(tx: tx, status: 503, reason: "Service Unavailable",
                        contentType: "text/plain", body: Data(error.localizedDescription.utf8))
                }
            }
            return
        }
        routeUpstream(req, transaction: tx, rules: rules, url: url)
    }

    private func routeUpstream(_ req: HTTPRequestHead, transaction tx: Transaction, rules: RulesSnapshot, url: String) {
        // Map Remote：改写上游目标
        var effectivePath = tx.urlText
        var effectiveHeaders = req.headers
        if let target = rules.mapRemoteTarget(for: url) {
            tx.matchedByMapRemote = true
            diagnosticHeaders.record(.mapRemote)
            if tx.originalURL == nil { tx.originalURL = url }
            tx.host = target.host
            tx.port = target.port
            tx.scheme = target.scheme
            effectivePath = target.requestTarget(path: tx.path, query: tx.query)
            (tx.path, tx.query) = splitQueryPath(effectivePath)
            effectiveHeaders.set(name: "Host", value: URLParser.authority(host: tx.host, port: tx.port, scheme: tx.scheme))
        }

        // No Caching：剥离条件请求头
        if rules.noCaching {
            effectiveHeaders.remove(name: "If-None-Match")
            effectiveHeaders.remove(name: "If-Modified-Since")
            effectiveHeaders.remove(name: "If-Unmodified-Since")
        }
        effectiveHeaders = diagnosticHeaders.appending(to: effectiveHeaders)
        let effectiveReq = HTTPRequestHead(method: req.method, target: effectivePath, version: req.version, headers: effectiveHeaders)
        tx.requestHeaders = conn.http2WebSocket?.captureHeaders(effectiveHeaders) ?? effectiveHeaders
        tx.resolvedAddress = InterceptionConfig.shared.mappedIP(for: tx.host)
        simulation = LatencyConditions.snapshot().sample(for: tx.host)
        let delay = simulation.requestDelay
        tx.simulatedLatencyMs = !simulation.disconnect && delay > 0 ? delay : nil
        publish(tx)
        if simulation.disconnect {
            disconnectSimulatedRequest(tx)
            return
        }
        pendingHeadBytes = sanitizedRequestHead(head: effectiveReq, originFormTarget: effectivePath, keepAlive: keepAlive)

        mode = .inFlight
        let https = tx.scheme == "https"
        if delay > 0, let channel = clientChannel {
            tryCloseUpstream()
            refreshReads()
            simulatedDelay = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(delay))) { [weak self] in
                guard let self, self.mode == .inFlight, self.tx === tx, channel.isActive else { return }
                self.simulatedDelay = nil
                self.openUpstream(https: https)
            }
        } else {
            openUpstream(https: https)
        }
    }

    private func disconnectSimulatedRequest(_ tx: Transaction) {
        mode = .closed
        tryCloseUpstream()
        refreshReads()
        let sink = conn.engine.sink
        onMain {
            tx.state = .failed
            tx.errorText = LatencyConditions.disconnectReason
            tx.duration = Date().timeIntervalSince(tx.startedAt)
            sink?.transactionUpdated(tx)
        }
        guard let channel = clientChannel else { return }
        let close = {
            // Skip TLS close_notify to simulate a transport reset.
            if let tls = try? channel.pipeline.syncOperations.context(handlerType: NIOSSLServerHandler.self) {
                tls.close(promise: nil)
            } else {
                channel.close(promise: nil)
            }
        }
        if let socket = channel as? SocketOptionProvider {
            socket.setSoLinger(linger(l_onoff: 1, l_linger: 0)).whenComplete { _ in close() }
        } else {
            close()
        }
    }

    private func publish(_ tx: Transaction) {
        guard tx.captureReservation != nil else { return }
        let sink = conn.engine.sink
        onMain { sink?.transactionCreated(tx) }
    }

    // MARK: HTTP breakpoint lifecycle (connection event loop)

    private func fixedBreakpointLength(_ headers: HTTPHeaders) -> Int? {
        let lengths = headers.values(of: "Content-Length")
        guard lengths.count == 1, let size = Int(lengths[0]), (0...BreakpointMessage.bodyLimit).contains(size),
              !headers.contains("Transfer-Encoding"), !headers.contains("Content-Encoding"),
              !SSEStreamState.matches(headers.value(of: "Content-Type") ?? "") else { return nil }
        return size
    }

    private func startBreakpoint(_ head: BreakpointHead, source: Channel, rule: BreakpointRule?,
                                 script: ScriptingPlan?, capture: Int?) {
        let timeout = conn.engine.breakpointTimeout
        let deadline = Date().addingTimeInterval(Double(timeout.nanoseconds) / 1_000_000_000)
        let gate = BreakpointGate(head: head, source: source, rule: rule, script: script, captureBytes: capture,
                                  deadline: deadline, session: conn.engine.breakpointSessionID)
        breakpointGate = gate
        gate.timer = source.eventLoop.scheduleTask(in: timeout) { [weak self] in
            self?.failBreakpoint(rule == nil ? "等待脚本报文超时" : "断点等待超时", timeout: true)
        }
        if (capture ?? 0) == 0 { submitBreakpoint(gate) }
        else { refreshReads() }
    }

    private func collectBreakpointBytes(_ input: ByteBuffer) {
        guard let gate = breakpointGate else { return }
        var buffer = input
        if let length = gate.captureBytes, gate.body.count < length,
           let bytes = buffer.readBytes(length: min(length - gate.body.count, buffer.readableBytes)) {
            gate.body.append(contentsOf: bytes)
        }
        if buffer.readableBytes > 0 {
            gate.followingBytes += buffer.readableBytes
            guard gate.followingBytes <= 1_048_576 else {
                failBreakpoint("断点等待期间缓冲超过 1 MiB")
                return
            }
            gate.following.append(buffer)
        }
        if !gate.submitted, gate.body.count == (gate.captureBytes ?? 0) { submitBreakpoint(gate) }
    }

    private func submitBreakpoint(_ gate: BreakpointGate) {
        guard let tx, let target = breakpointTarget else { return }
        gate.submitted = true
        refreshReads()
        guard let rule = gate.rule, let label = gate.label else {
            resumeBreakpoint(gate.id, decision: .original)
            return
        }
        guard gate.session == conn.engine.breakpointSessionID else { failBreakpoint("会话已清空"); return }
        let editableBody = gate.captureBytes == nil ? nil : BreakpointMessage.editableText(gate.body)
        let address = clientChannel?.remoteAddress?.description ?? "本机客户端"
        let item = BreakpointManager.HeldItem(id: gate.id, txID: tx.id, phase: rule.phase,
            summary: "\(target.method) \(target.url)", source: address, rule: label,
            message: BreakpointMessage(head: gate.head, body: editableBody), deadline: gate.deadline)
        let loop = gate.source.eventLoop
        let engine = conn.engine
        let session = gate.session
        DispatchQueue.main.async {
            guard session == engine.breakpointSessionID else {
                loop.execute { [weak self] in self?.resumeBreakpoint(item.id, decision: .discard) }
                return
            }
            BreakpointManager.shared.hold(item) { [weak self] decision in
                loop.execute { [weak self] in self?.resumeBreakpoint(item.id, decision: decision) }
            }
        }
    }

    private func takeBreakpoint() -> BreakpointGate? {
        guard let gate = breakpointGate else { return nil }
        breakpointGate = nil
        gate.timer?.cancel()
        let id = gate.id
        if gate.rule != nil { DispatchQueue.main.async { BreakpointManager.shared.forget(id) } }
        return gate
    }

    private func failBreakpoint(_ text: String, timeout: Bool = false) {
        guard let gate = takeBreakpoint() else { return }
        if mode == .requestPaused, let tx {
            if let label = gate.label { tx.breakpointRules.append(label) }
            if !gate.body.isEmpty { tx.appendRequestBody(gate.body) }
            if gate.rule == nil || gate.session == conn.engine.breakpointSessionID { publish(tx) }
        } else if let tx, let label = gate.label {
            onMain { tx.breakpointRules.append(label) }
        }
        respHeadParsed = false
        mode = .inFlight
        if timeout { finishRequestWithFailure(text, status: 504, reason: "Gateway Timeout") }
        else { finishRequestWithFailure(text) }
    }

    private func resumeBreakpoint(_ id: UUID, decision: BreakpointManager.Decision) {
        guard let gate = breakpointGate, gate.id == id else { return }
        if case .drop(let reason) = decision { failBreakpoint(reason); return }
        if case .discard = decision { failBreakpoint("会话已清空"); return }
        let edit: BreakpointMessage?
        if case .apply(let message) = decision { edit = message } else { edit = nil }
        let body = edit?.body ?? gate.body
        let head = edit?.head ?? gate.head
        if let script = gate.script {
            let editableBody = gate.captureBytes == nil ? nil : BreakpointMessage.editableText(body)
            let loop = gate.source.eventLoop
            ScriptingService.run(script, head: head, body: editableBody, graphqlName: scriptingOperationName) { [weak self] result in
                loop.execute { [weak self] in
                    guard let self, self.breakpointGate?.id == id else { return }
                    if script.phase == .request { self.scriptingOperationName = result.graphqlOperationName }
                    if script.phase == .request, let mock = result.mockResponse {
                        self.finishMockInterception(id: id, head: result.head, body: result.body ?? body,
                                                    mock: mock, logs: result.logs)
                    } else {
                        self.finishInterception(id: id, head: result.head, body: result.body ?? body, logs: result.logs)
                    }
                }
            }
        } else {
            finishInterception(id: id, head: head, body: body, logs: [])
        }
    }

    private func finishMockInterception(id: UUID, head: BreakpointHead, body: Data,
                                        mock: ScriptingMockResponse, logs: [String]) {
        guard breakpointGate?.id == id, let tx, let gate = takeBreakpoint(), case .request(let req) = head else { return }
        if gate.script != nil { diagnosticHeaders.record(.scripting) }
        if gate.rule != nil { diagnosticHeaders.record(.breakpoint) }
        if let label = gate.label { tx.breakpointRules.append(label) }
        if !logs.isEmpty { tx.appendScriptingLogs(logs) }
        tx.requestHeaders = conn.http2WebSocket?.captureHeaders(req.headers) ?? req.headers
        keepAlive = conn.http2WebSocket == nil && !HTTPClientWantsClose(req) && gate.following.isEmpty
        let complete = !req.headers.contains("Transfer-Encoding") &&
            (Int(req.headers.value(of: "Content-Length") ?? "0") ?? -1) == body.count
        tx.requestBodyComplete = complete
        if !body.isEmpty { tx.appendRequestBody(body) }
        mode = .inFlight
        finishWithSynthesizedResponse(tx: tx, status: mock.status, reason: TrafficStore.reason(for: mock.status),
            contentType: mock.headers.value(of: "Content-Type") ?? "text/plain; charset=utf-8",
            body: ByteBuffer(bytes: mock.body), contentLength: mock.body.count, extraHeaders: mock.headers)
        refreshReads()
    }

    private func finishInterception(id: UUID, head: BreakpointHead, body: Data, logs: [String]) {
        guard breakpointGate?.id == id, let tx, let gate = takeBreakpoint() else { return }
        if gate.script != nil { diagnosticHeaders.record(.scripting) }
        if gate.rule != nil { diagnosticHeaders.record(.breakpoint) }
        let label = gate.label
        switch head {
        case .request(let req):
            if let label { tx.breakpointRules.append(label) }
            if !logs.isEmpty { tx.appendScriptingLogs(logs) }
            tx.requestHeaders = conn.http2WebSocket?.captureHeaders(req.headers) ?? req.headers
            routeRequest(req, transaction: tx)
            if !body.isEmpty, mode == .inFlight || mode == .resolvingLocal {
                receiveClientBytes(ByteBuffer(bytes: body))
            }
            for buffer in gate.following { receiveClientBytes(buffer) }
        case .response(let resp):
            onMain {
                if let label { tx.breakpointRules.append(label) }
                if !logs.isEmpty { tx.appendScriptingLogs(logs) }
            }
            mode = .inFlight
            respHeadParsed = true
            deliverResponseHead(resp)
            if !body.isEmpty { deliverResponseBody(ByteBuffer(bytes: body)) }
            if gate.captureBytes == nil {
                for buffer in gate.following where self.tx === tx && mode == .inFlight { deliverResponseBody(buffer) }
            }
            if gate.sourceClosed && self.tx === tx && mode == .inFlight {
                if respCloseDelimited { finishRequest() }
                else { finishRequestWithFailure("断点等待期间上游连接中断") }
            }
        }
        refreshReads()
    }

    /// 工具规则命中时的本地合成响应（Block 403 / Map Local 文件内容）
    private func finishWithSynthesizedResponse(tx: Transaction, status: Int, reason: String,
                                               contentType: String, body: Data) {
        let buffer = tx.method == "HEAD" ? ByteBuffer() : ByteBuffer(bytes: body)
        finishWithSynthesizedResponse(tx: tx, status: status, reason: reason, contentType: contentType,
                                      body: buffer, contentLength: body.count, extraHeaders: HTTPHeaders())
    }

    private func finishWithSynthesizedResponse(tx: Transaction, status: Int, reason: String,
                                               contentType: String, body: ByteBuffer, contentLength: Int,
                                               extraHeaders: HTTPHeaders, file: MapLocalFile? = nil) {
        let sendBody = tx.method != "HEAD" && ![204, 205, 304].contains(status)
        let shouldClose = !keepAlive || !tx.requestBodyComplete
        tx.statusCode = status
        tx.statusReason = reason
        tx.contentType = contentType
        tx.responseHeaders = extraHeaders
        tx.responseHeaders.set(name: "Content-Type", value: contentType)
        if ![204, 304].contains(status) {
            tx.responseHeaders.set(name: "Content-Length", value: status == 205 ? "0" : String(contentLength))
        }
        tx.requestHeaders = diagnosticHeaders.appending(to: tx.requestHeaders)
        tx.responseHeaders = diagnosticHeaders.appending(to: tx.responseHeaders)
        if shouldClose { tx.responseHeaders.set(name: "Connection", value: "close") }
        tx.responseBodyComplete = file == nil

        var headOut = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        headOut.append(tx.responseHeaders.rawBytes)
        headOut.append(Data("\r\n".utf8))
        if let request = conn.http2WebSocket { tx.responseHeaders = request.captureHeaders(tx.responseHeaders, response: true) }
        writeDownstream(ByteBuffer(bytes: headOut), paced: false)
        if let file, let channel = clientChannel {
            respHeadParsed = true
            mode = .sendingLocal
            closeAfterResponse = shouldClose
            publish(tx)
            let sender = MapLocalSender(file: file, channel: channel, write: { [weak self] channel, bytes in
                self?.bodyCapture?.append(bytes.readableBytesView, direction: .downstream)
                return channel.writeAndFlush(bytes)
            }, completion: { [weak self] result in
                guard let self, self.mode == .sendingLocal else { return }
                self.mapLocalSender = nil
                switch result {
                case .success:
                    self.bodyCapture?.flush()
                    self.finishResponseWrites(transaction: tx, close: self.closeAfterResponse)
                case .failure(let error):
                    self.finishRequestWithFailure("本地文件发送失败：\(error.localizedDescription)")
                }
            })
            mapLocalSender = sender
            refreshReads()
            sender.resume()
            return
        }
        if sendBody {
            if let channel = clientChannel {
                let send = { channel.writeAndFlush(body, promise: nil) }
                if let downloadPacer { downloadPacer.afterWrites(send) } else { send() }
            }
        }

        if sendBody {
            bodyCapture?.append(body.readableBytesView, direction: .downstream)
            bodyCapture?.flush()
        }
        publish(tx)
        finishResponseWrites(transaction: tx, close: shouldClose)
    }

    // MARK: CONNECT

    func beginTransparentFlow() {
        guard let flow = conn.transparentFlow, flow.port == 443 else { return }
        let authority = URLParser.authority(host: flow.host, port: flow.port, scheme: "https")
        startConnect(HTTPRequestHead(method: "CONNECT", target: authority, version: "HTTP/1.1", headers: HTTPHeaders()),
                     trailing: [])
    }

    private func startConnect(_ req: HTTPRequestHead, trailing: [UInt8]) {
        let authority = req.target
        guard let client = clientChannel, let parsed = URLParser.parse(target: "https://\(authority)"),
              let host = parsed.host else {
            writeRawAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let port = parsed.port
        conn.resolvedConnectHost = host
        conn.resolvedConnectPort = port

        let tx = Transaction(captureBudget: conn.engine.recordingEnabled ? .live : nil)
        tx.method = "CONNECT"
        tx.scheme = "Tunnel"
        tx.host = host
        tx.port = port
        tx.path = ""
        tx.isTunnel = true
        tx.statusCode = 200
        tx.statusReason = "Connection Established"
        tx.requestVersion = req.version
        tx.requestHeaders = req.headers
        tx.requestBodyComplete = true
        tx.resolvedAddress = InterceptionConfig.shared.mappedIP(for: host)
        tx.peerPort = UInt16(clientChannel?.remoteAddress?.port ?? 0)
        tx.clientAddress = clientChannel?.remoteAddress?.ipAddress
        tx.state = .awaiting
        connectTx = tx
        diagnosticHeaders = DiagnosticHeaders(requestID: tx.id)
        conn.sslRules = RulesStore.shared.snapshot()
        mode = .resolvingConnect
        if !trailing.isEmpty { bufferConnectBytes(ByteBuffer(bytes: trailing)) }
        guard mode == .resolvingConnect else { return }

        guard conn.transparentFlow == nil, conn.sslRules.hasSSLApplicationRules, conn.allowsMITM(host: host),
              client.remoteAddress?.ipAddress == "127.0.0.1", client.localAddress?.ipAddress == "127.0.0.1",
              let peerPort = client.remoteAddress?.port, let listenPort = client.localAddress?.port else {
            finishConnect(application: nil)
            return
        }

        refreshReads()
        let loop = client.eventLoop
        connectAttributionTimeout = loop.scheduleTask(in: .milliseconds(750)) { [weak self] in
            self?.finishConnect(application: nil)
        }
        ProcessAttribution.shared.attributeConnection(peerPort: peerPort, listenPort: listenPort,
                                                      deadline: .now() + .milliseconds(750)) { [weak self] application in
            loop.execute { [weak self] in self?.finishConnect(application: application) }
        }
    }

    private func bufferConnectBytes(_ buffer: ByteBuffer) {
        earlyConnectByteCount += buffer.readableBytes
        guard earlyConnectByteCount <= 1_048_576, earlyConnectBytes.count < Self.maxBufferedParts else {
            writeRawAndClose("HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        earlyConnectBytes.append(buffer)
    }

    private func finishConnect(application: ProcessAppInfo?) {
        guard mode == .resolvingConnect, let client = clientChannel, client.isActive, let tx = connectTx else { return }
        connectAttributionTimeout?.cancel()
        connectAttributionTimeout = nil
        conn.clientApplication = application
        tx.setClientApplication(application)
        conn.transparentFlow?.mark(tx)
        let intercept = conn.transparentFlow != nil ? conn.allowsMITM(host: tx.host) : conn.shouldMITM(host: tx.host)
        if !intercept, rejectTunnelIfNeeded(tx, sendResponse: conn.transparentFlow == nil) { return }
        publish(tx)
        let sniff = intercept || (conn.isSOCKS5 && tx.port == 80)
        socksReplyPending = conn.isSOCKS5 && !sniff
        if conn.transparentFlow == nil, !socksReplyPending { writeRaw("HTTP/1.1 200 Connection Established\r\n\r\n") }

        let earlyBytes = earlyConnectBytes
        earlyConnectBytes.removeAll(keepingCapacity: true)
        earlyConnectByteCount = 0

        // A transparent flow may only carry an IP until its TLS ClientHello supplies SNI.
        if sniff {
            mode = .tlsPending
            conn.snifferArmed = true
            refreshReads()
            for buffer in earlyBytes { client.pipeline.syncOperations.fireChannelRead(NIOAny(buffer)) }
        } else {
            beginRawTunnel(host: tx.host, port: tx.port)
            for buffer in earlyBytes { receiveClientBytes(buffer) }
        }
    }

    /// sniffer 决策完成（与 sniffer 同线程同步调用，先于缓冲数据回放）
    fileprivate func clientHelloResolved(mitmHost: String?, socksHTTP: Bool = false) {
        if mitmHost != nil || socksHTTP {
            mode = .readingHead
            headParser = RequestHeadParser()
            mitmActive = !socksHTTP
            if let tx = connectTx {
                let sink = conn.engine.sink
                onMain {
                    tx.isTLSIntercepted = !socksHTTP
                    tx.state = .completed
                    tx.duration = Date().timeIntervalSince(tx.startedAt)
                    sink?.transactionUpdated(tx)
                }
            }
        } else {
            // 回退为裸隧道
            if let tx = connectTx, mode == .tlsPending {
                // CONNECT was already acknowledged before peeking at ClientHello.
                // A rejected TLS flow must close, rather than injecting plaintext into TLS.
                if rejectTunnelIfNeeded(tx, sendResponse: false, published: true) { return }
                beginRawTunnel(host: tx.host, port: tx.port)
            }
        }
    }

    @discardableResult
    private func rejectTunnelIfNeeded(_ tx: Transaction, sendResponse: Bool, published: Bool = false) -> Bool {
        let serverName = conn.transparentFlow == nil ? nil : conn.sniffedServerName
        guard let reason = tunnelRules().tunnelRejection(host: tx.host, port: tx.port,
                                                         serverName: serverName) else { return false }
        let body = Data(reason.utf8)
        tx.matchedByBlock = true
        diagnosticHeaders.record(.block)
        tx.statusCode = 403
        tx.statusReason = "Forbidden"
        tx.contentType = "text/plain"
        tx.requestHeaders = diagnosticHeaders.appending(to: tx.requestHeaders)
        tx.responseHeaders = diagnosticHeaders.appending(to: HTTPHeaders([
            ("Content-Type", "text/plain"), ("Content-Length", String(body.count)), ("Connection", "close"),
        ]))
        tx.appendResponseBody(body)
        tx.responseBodyComplete = true
        tx.state = .failed
        tx.errorText = reason
        tx.duration = Date().timeIntervalSince(tx.startedAt)
        if published {
            let sink = conn.engine.sink
            onMain { sink?.transactionUpdated(tx) }
        } else { publish(tx) }
        connectTx = nil
        earlyConnectBytes.removeAll()
        earlyConnectByteCount = 0
        mode = .closed
        if sendResponse {
            let headers = String(decoding: tx.responseHeaders.rawBytes, as: UTF8.self)
            writeRawAndClose("HTTP/1.1 403 Forbidden\r\n\(headers)\r\n\(reason)")
        } else { closeClient() }
        return true
    }

    private func beginRawTunnel(host: String, port: Int) {
        mode = .tunnelConnecting
        upstreamReusable = false
        tx = nil
        let origin = HTTPOrigin(host: host, dialHost: connectTx?.resolvedAddress ?? conn.transparentFlow?.dialHost ?? host,
                                port: port, tls: false)
        guard let client = clientChannel else { return }
        refreshReads()
        origin.resolvingProxy(path: "/", tunnel: true, on: client.eventLoop).whenComplete { [weak self] result in
            guard let self, client.isActive, self.mode == .tunnelConnecting else { return }
            switch result {
            case .success(let resolved): self.dialUpstream(resolved, tunnel: true)
            case .failure(let error): self.upstreamFailed(error)
            }
        }
    }

    private func openUpstream(https: Bool) {
        upstreamReady = false
        guard let tx, let client = clientChannel else { return }
        let dialHost = conn.transparentFlow?.upstreamHost(for: tx) ?? tx.resolvedAddress ?? tx.host
        let origin = HTTPOrigin(host: tx.host, dialHost: dialHost, port: tx.port, tls: https)
        refreshReads()
        origin.resolvingProxy(path: tx.urlText, on: client.eventLoop).whenComplete { [weak self] result in
            guard let self, client.isActive, self.mode == .inFlight, self.tx === tx else { return }
            switch result {
            case .success(let resolved): self.openResolvedUpstream(resolved, transaction: tx)
            case .failure(let error): self.upstreamFailed(error)
            }
        }
    }

    private func openResolvedUpstream(_ origin: HTTPOrigin, transaction tx: Transaction) {
        if upstreamReusable, let channel = upstreamChannel, channel.isActive, upstreamOrigin == origin {
            upstreamReady = true
            var details = upstreamConnection
            details?.reused = true
            let now = Date()
            onMain {
                tx.tConnected = now
                tx.connectionDetails = details
                tx.upstreamProtocol = "HTTP/1.1"
            }
            flushPendingToUpstream()
            refreshReads()
            return
        }
        tryCloseUpstream()
        dialUpstream(origin, tunnel: false)
    }

    private func dialUpstream(_ origin: HTTPOrigin, tunnel: Bool) {
        guard let client = clientChannel else { return }
        let loop = client.eventLoop
        let resolver = URLParser.isIPAddress(origin.dialHost) || origin.external != nil ? nil : TimedDNSResolver(loop: loop)
        upstreamOrigin = origin
        upstreamResolver = resolver
        upstreamDialAt = Date()
        upstreamConnectedAt = nil
        upstreamConnection = nil
        refreshReads()
        origin.connect(on: loop, listenerPort: conn.engine.port, resolver: resolver) { [weak self] channel in
            guard let self else { return channel.eventLoop.makeFailedFuture(ProxyError.shutdown) }
            if tunnel { return channel.pipeline.addHandler(UpstreamRelayHandler(conn: self)) }
            let tls = origin.tls ? UpstreamTrust.context(on: loop, host: origin.host).map(Optional.some)
                                 : loop.makeSucceededFuture(nil)
            return tls.flatMapThrowing { context in
                var handlers: [ChannelHandler] = [IdleStateHandler(readTimeout: .seconds(30))]
                if let context {
                    let sni = URLParser.isIPAddress(origin.host) ? nil : origin.host
                    handlers.append(try NIOSSLClientHandler(context: context, serverHostname: sni))
                }
                handlers.append(UpstreamRelayHandler(conn: self))
                try channel.pipeline.syncOperations.addHandlers(handlers)
            }
        }.whenFailure { [weak self] error in
            self?.upstreamFailed(error)
        }
    }

    fileprivate func upstreamConnected(_ channel: Channel) {
        guard mode == .inFlight || mode == .tunnelConnecting else {
            channel.close(promise: nil)
            return
        }
        NSLog("[ProxyMirror][upstream] connected %@ mode=%@", channel.remoteAddress?.description ?? "?", String(describing: mode))
        upstreamChannel = channel
        let connected = Date()
        upstreamConnectedAt = connected
        let dns = upstreamResolver?.milliseconds
        let tcp = upstreamDialAt.map { max(0, connected.timeIntervalSince($0) * 1000 - (dns ?? 0)) }
        var details = ProxyConnectionDetails(address: channel.remoteAddress?.ipAddress, dnsMilliseconds: dns,
                                             tcpMilliseconds: tcp, externalProxy: upstreamOrigin?.externalLabel)
        details.downstreamStream = http2DownstreamStreamID
        upstreamConnection = details
        if mode == .tunnelConnecting {
            if socksReplyPending {
                socksReplyPending = false
                writeRaw("HTTP/1.1 200 Connection Established\r\n\r\n")
            }
            mode = .tunnelRelay
            if let tx = connectTx {
                let sink = conn.engine.sink
                onMain {
                    tx.state = .completed
                    tx.tConnected = connected
                    tx.connectionDetails = details
                    tx.duration = Date().timeIntervalSince(tx.startedAt)
                    sink?.transactionUpdated(tx)
                }
            }
            connectTx = nil
            for bb in pendingToUpstream { channel.write(NIOAny(bb), promise: nil) }
            if !pendingToUpstream.isEmpty { channel.flush() }
            pendingToUpstream.removeAll(keepingCapacity: true)
            pendingUploadBytes = 0
            if downstreamInputClosed { channel.close(mode: .output, promise: nil) }
        } else if mode == .inFlight {
            upstreamReady = upstreamOrigin?.tls != true
            upstreamReusable = upstreamReady
            if let tx {
                onMain {
                    tx.tConnected = connected
                    tx.connectionDetails = details
                    tx.upstreamProtocol = "HTTP/1.1"
                }
            }
            flushPendingToUpstream()
        }
        refreshReads()
    }

    fileprivate func upstreamTLSReady(_ channel: Channel, protocolName: String?) {
        guard upstreamChannel === channel, let connected = upstreamConnectedAt,
              var details = upstreamConnection else { return }
        details.alpn = protocolName
        details.tlsMilliseconds = max(0, Date().timeIntervalSince(connected) * 1000)
        upstreamConnection = details
        upstreamReady = true
        upstreamReusable = true
        flushPendingToUpstream()
        refreshReads()
        if let tx {
            onMain {
                tx.connectionDetails = details
                self.conn.engine.sink?.transactionUpdated(tx)
            }
        }
    }

    private func flushPendingToUpstream() {
        guard upstreamReady, let ch = upstreamChannel else { return }
        let head = pendingHeadBytes
        pendingHeadBytes = nil
        let buffered = pendingToUpstream
        pendingToUpstream.removeAll(keepingCapacity: true)
        pendingUploadBytes = 0
        if let head { ch.write(ByteBuffer(bytes: head), promise: nil) }

        let rate = simulation.bandwidth.uploadKbps
        guard rate != nil || simulation.bodyPause.enabled else {
            for bytes in buffered { ch.write(bytes, promise: nil) }
            if head != nil || !buffered.isEmpty { ch.flush() }
            return
        }
        if head != nil { ch.flush() }
        guard !buffered.isEmpty else { return }
        if uploadPacer == nil {
            uploadPacer = BytePacingQueue(loop: ch.eventLoop, onBackpressure: { [weak self] _ in
                self?.refreshReads()
            }, onFailure: { [weak self] error in
                self?.upstreamFailed(error, channel: ch)
            })
        }
        for bytes in buffered where mode == .inFlight || mode == .responsePaused {
            uploadPacer?.write(bytes, kilobitsPerSecond: rate, pauseMs: simulation.bodyPause.sample()) { ch.writeAndFlush($0) }
        }
    }

    fileprivate func upstreamFailed(_ error: Error, channel: Channel? = nil) {
        if let channel, upstreamChannel !== channel { return }
        switch mode {
        case .tunnelConnecting, .tunnelRelay:
            if socksReplyPending {
                socksReplyPending = false
                writeRaw("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            }
            if let tx = connectTx {
                let sink = conn.engine.sink
                onMain {
                    tx.state = .failed
                    tx.errorText = "隧道建立失败: \(error)"
                    tx.duration = Date().timeIntervalSince(tx.startedAt)
                    sink?.transactionUpdated(tx)
                }
            }
            connectTx = nil
            mode = .closed
            closeDownstreamAfterWrites()
        case .inFlight:
            finishRequestWithFailure("无法连接上游: \(error)")
        case .responsePaused:
            if breakpointGate?.submitted == true { breakpointGate?.sourceClosed = true }
            else { failBreakpoint("断点等待期间上游连接中断") }
        case .wsRelay:
            if let transaction = tx {
                let sink = conn.engine.sink
                onMain {
                    transaction.errorText = "WebSocket 限速写入失败：\(error.localizedDescription)"
                    transaction.state = .failed
                    sink?.transactionUpdated(transaction)
                }
            }
            closeWebSocketRelay()
        default:
            break
        }
    }

    fileprivate func upstreamClosed(_ channel: Channel) {
        guard upstreamChannel === channel else { return }
        upstreamChannel = nil
        upstreamReusable = false
        switch mode {
        case .tunnelRelay:
            bodyCapture?.flush()
            mode = .closed
            closeDownstreamAfterWrites()
        case .wsRelay:
            finishWebSocketDownload()
        case .inFlight:
            if respHeadParsed && (respChunked == nil && respRemainingCL == nil && !respCloseDelimited) {
                finishRequest()
            } else if respHeadParsed && respCloseDelimited {
                finishRequest()
            } else {
                finishRequestWithFailure(respHeadParsed ? "上游连接中断" : "上游未响应")
            }
        case .responsePaused:
            if breakpointGate?.submitted == true { breakpointGate?.sourceClosed = true }
            else { failBreakpoint("断点等待期间上游连接中断") }
        default:
            break
        }
    }

    fileprivate func upstreamReadTimeout(_ channel: Channel) {
        guard upstreamChannel === channel else { return }
        if mode == .inFlight && uploadPacer?.hasPendingWrites != true
            && (!upstreamReady || (channel.isWritable && clientChannel?.isWritable == true
                                  && downloadPacer?.isBackpressured != true)) {
            finishRequestWithFailure("等待上游响应超时", status: 504, reason: "Gateway Timeout")
        } else if mode == .readingHead || mode == .resolvingLocal || mode == .finishingResponse || mode == .sendingLocal {
            tryCloseUpstream()
        }
    }

    // MARK: 请求 body 转发

    private func forwardRequestBody(_ bb: ByteBuffer) {
        guard !stoppedUpload, mode == .inFlight || mode == .responsePaused else { return }

        let current = tx
        if var tracker = reqChunked {
            do {
                let wireBytes = try tracker.consume(bb.readableBytesView) {
                    bodyCapture?.append($0, direction: .upstream)
                }
                var remaining = bb
                if let wire = remaining.readSlice(length: wireBytes), !bufferUpload(wire) { return }
                if remaining.readableBytes > 0, !bufferPipeline(remaining) { return }
                reqChunked = tracker.finished ? nil : tracker
                if tracker.finished { reqRemainingCL = 0 }
                if tracker.finished {
                    let trailers = tracker.trailers
                    bodyCapture?.flush()
                    onMain {
                        current?.requestTrailers = trailers
                        current?.requestBodyComplete = true
                    }
                }
            } catch {
                writeRawAndClose("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                tryCloseUpstream()
                return
            }
        } else if let remaining = reqRemainingCL {
            if remaining == 0 {
                _ = bufferPipeline(bb)
            } else if bb.readableBytes <= remaining {
                reqRemainingCL = remaining - bb.readableBytes
                guard bufferUpload(bb) else { return }
                bodyCapture?.append(bb.readableBytesView, direction: .upstream)
                if reqRemainingCL == 0 {
                    bodyCapture?.flush()
                    onMain { current?.requestBodyComplete = true }
                }
            } else {
                var full = bb
                let bodyPart = full.readSlice(length: remaining) ?? full
                guard bufferUpload(bodyPart) else { return }
                reqRemainingCL = 0
                bodyCapture?.append(bodyPart.readableBytesView, direction: .upstream)
                bodyCapture?.flush()
                onMain { current?.requestBodyComplete = true }
                if full.readableBytes > 0, !bufferPipeline(full) { return }
            }
        } else {
            _ = bufferPipeline(bb)
        }

        if upstreamReady && (mode == .inFlight || mode == .responsePaused) { flushPendingToUpstream() }
    }

    private func bufferUpload(_ bytes: ByteBuffer) -> Bool {
        guard bytes.readableBytes <= Self.maxBufferedBytes - pendingUploadBytes,
              pendingToUpstream.count < Self.maxBufferedParts else {
            if mode == .tunnelConnecting {
                upstreamFailed(ExternalProxyError("等待隧道上游的发送缓冲已满"))
            } else {
                failBufferedInput("等待上游的发送缓冲已满")
            }
            return false
        }
        pendingUploadBytes += bytes.readableBytes
        pendingToUpstream.append(bytes)
        return true
    }

    private func bufferPipeline(_ bytes: ByteBuffer) -> Bool {
        guard bytes.readableBytes <= Self.maxBufferedBytes - pipelinedBytes,
              pipelined.count < Self.maxBufferedParts else {
            failBufferedInput("后续请求的缓冲已满")
            return false
        }
        pipelinedBytes += bytes.readableBytes
        pipelined.append(bytes)
        if pipelinedBytes >= Self.pipelineHighWatermark || pipelined.count >= Self.pipelineHighParts {
            refreshReads()
        }
        return true
    }

    private func failBufferedInput(_ message: String) {
        if breakpointGate != nil {
            failBreakpoint(message)
        } else if mode == .finishingResponse || mode == .sendingLocal {
            // The current response is already on the wire. Discard later requests
            // and keep reading while the local file drains to detect a peer close.
            closeAfterResponse = true
            pipelined.removeAll()
            pipelinedBytes = 0
            refreshReads()
        } else {
            finishRequestWithFailure(message, status: 413, reason: "Payload Too Large")
        }
    }

    // MARK: 上游数据 → 客户端 + 捕获

    /// 决策回调投递器：把脚本队列的结果投回本方向的事件循环
    private static func loopDispatcher(_ channel: Channel) -> (@escaping @Sendable () -> Void) -> Void {
        let target = channel   // 拷贝为局部量后再被返回闭包捕获
        return { @Sendable (block: @escaping @Sendable () -> Void) in target.eventLoop.execute(block) }
    }

    /// Both ordinary WS bytes and scripted replacements use the same bounded
    /// upload queue. HTTP/2 stream reads pause when this queue is backpressured.
    private func writeWebSocketUpstream(_ bytes: ByteBuffer) {
        guard let channel = upstreamChannel, channel.isActive else { return }
        let rate = simulation.bandwidth.uploadKbps
        let pause = simulation.bodyPause.sample()
        if (rate != nil || pause > 0), uploadPacer == nil {
            uploadPacer = BytePacingQueue(loop: channel.eventLoop, onBackpressure: { [weak self] _ in
                self?.refreshReads()
            }, onFailure: { [weak self] error in
                self?.upstreamFailed(error, channel: channel)
            })
        }
        if let uploadPacer {
            uploadPacer.write(bytes, kilobitsPerSecond: rate, pauseMs: pause) { channel.writeAndFlush($0) }
        } else { channel.writeAndFlush(bytes, promise: nil) }
    }

    /// WebSocket 脚本管道的有效字节写出（两条方向各自的引擎循环上调用）
    private func relayWebSocketBytes(_ data: Data, direction: WSFrame.Direction) {
        let buffer = ByteBuffer(bytes: [UInt8](data))
        if direction == .upstream {
            writeWebSocketUpstream(buffer)
            bodyCapture?.append(data, direction: .upstream, webSocket: true)
        } else {
            writeDownstream(buffer, paced: true)
            bodyCapture?.append(data, direction: .downstream, webSocket: true)
        }
    }

    private func finishWebSocketUpload() {
        let finish: @Sendable () -> Void = { [weak self] in
            guard let self, self.mode == .wsRelay else { return }
            let shutdown = { [weak self] in
                guard let self, self.mode == .wsRelay else { return }
                self.upstreamChannel?.close(mode: .output, promise: nil)
            }
            // The interceptor has already cancelled its 5s script timeout.
            // A legitimate low-bandwidth transfer may take much longer.
            if let pacer = self.uploadPacer { pacer.afterWrites(shutdown) }
            else { shutdown() }
        }
        if let interceptor = wsUpstreamInterceptor { interceptor.finish(finish) }
        else { finish() }
    }

    private func finishWebSocketDownload() {
        let finish: @Sendable () -> Void = { [weak self] in
            guard let self, self.mode == .wsRelay else { return }
            self.bodyCapture?.flush()
            // afterDownstreamWrites includes the pacing barrier and then a
            // socket-write acknowledgement, including the H2 adapter's lastWrite.
            self.afterDownstreamWrites { [weak self] _ in
                guard let self, self.mode == .wsRelay else { return }
                self.mode = .closed
                self.closeClient()
            }
        }
        if let interceptor = wsDownstreamInterceptor { interceptor.finish(finish) }
        else { finish() }
    }

    private func closeWebSocketRelay() {
        guard mode == .wsRelay else { return }
        wsUpstreamInterceptor?.cancel()
        wsDownstreamInterceptor?.cancel()
        mode = .closed
        tryCloseUpstream()
        closeDownstreamAfterWrites()
    }

    fileprivate func handleUpstreamData(_ bb: ByteBuffer, channel: Channel) {
        guard upstreamChannel === channel else { return }
        switch mode {
        case .tunnelRelay:
            writeDownstream(bb, paced: false)
            return
        case .wsRelay:
            if let interceptor = wsDownstreamInterceptor {
                interceptor.feed(Data(copyOf(bb)))
            } else {
                writeDownstream(bb, paced: true)
                bodyCapture?.append(bb.readableBytesView, direction: .downstream, webSocket: true)
            }
            return
        case .inFlight:
            break
        case .responsePaused:
            collectBreakpointBytes(bb)
            return
        default:
            return
        }

        var buffer = bb
        while !respHeadParsed {
            let head: HTTPResponseHead?
            do {
                head = try respParser.feed(copyOf(buffer))
            } catch {
                finishRequestWithFailure("响应解析失败")
                return
            }
            guard let resp = head else { return }   // 头部未完整，parser 已缓冲
            buffer = ByteBuffer(bytes: respParser.trailing)
            if (100..<200).contains(resp.status), resp.status != 101 {
                sendResponseHead(resp, headers: resp.headers)
                respParser = ResponseHeadParser()
                guard buffer.readableBytes > 0 else { return }
                continue
            }
            let breakpoint = breakpointTarget?.rule(for: .response)
            let script = breakpointTarget.flatMap { ScriptingService.plan(for: $0.scripting, phase: .response) }
            if resp.status != 101, let tx, breakpoint != nil || script != nil {
                let bodyless = tx.method == "HEAD" || BreakpointMessage.noBodyStatus(resp.status)
                mode = .responsePaused
                startBreakpoint(.response(resp), source: channel, rule: breakpoint, script: script,
                                capture: bodyless ? nil : fixedBreakpointLength(resp.headers))
                collectBreakpointBytes(buffer)
                return
            }
            respHeadParsed = true
            deliverResponseHead(resp)
            if mode == .wsRelay, buffer.readableBytes > 0 {
                handleUpstreamData(buffer, channel: channel)
                return
            }
            break
        }
        deliverResponseBody(buffer)
    }

    private func sendResponseHead(_ resp: HTTPResponseHead, headers: HTTPHeaders, pauseMs: Int = 0) {
        var bytes = Data("\(resp.version) \(resp.status) \(resp.reason)\r\n".utf8)
        bytes.append(headers.rawBytes)
        bytes.append(Data("\r\n".utf8))
        writeDownstream(ByteBuffer(bytes: bytes), paced: false, pauseMs: pauseMs)
    }

    private func deliverResponseHead(_ resp: HTTPResponseHead) {
        guard let tx else { return }
        var resp = resp
        resp.headers = diagnosticHeaders.appending(to: resp.headers)

        // 101 协议升级（WebSocket 等）
        if resp.status == 101 {
            if let request = conn.http2WebSocket, !request.accepts(resp) {
                finishRequestWithFailure("上游 WebSocket 握手校验失败")
                return
            }
            bodyCapture?.upgradeToWebSocket(headers: resp.headers)
            let sink = conn.engine.sink
            onMain {
                tx.responseVersion = self.conn.http2WebSocket == nil ? resp.version : "HTTP/2"
                tx.statusCode = self.conn.http2WebSocket == nil ? resp.status : 200
                tx.statusReason = self.conn.http2WebSocket == nil ? resp.reason : ""
                tx.responseHeaders = self.conn.http2WebSocket?.captureHeaders(resp.headers, response: true, webSocket: true) ?? resp.headers
                tx.isWebSocket = true
                tx.state = .completed
                tx.duration = Date().timeIntervalSince(self.responseStart)
                sink?.transactionUpdated(tx)
            }

            let wsTarget = breakpointTarget?.scripting ?? ScriptingTarget(method: tx.method, scheme: tx.scheme,
                host: tx.host, path: tx.path, query: tx.query, url: tx.originalURL ?? tx.fullURL)
            if let plan = ScriptingService.plan(for: wsTarget, phase: .webSocket),
               let clientChannel, let upstreamChannel {
                if let issue = WebSocketDeflate.scriptingIssue(in: resp.headers) {
                    recordWebSocketScriptIssue("\(issue)，此连接未执行帧脚本并保留原始转发", target: wsTarget, tx: tx)
                } else {
                    let graphqlName = scriptingOperationName
                    let report: @Sendable (String) -> Void = { [weak self] issue in
                        self?.recordWebSocketScriptIssue(issue, target: wsTarget, tx: tx)
                    }
                    wsUpstreamInterceptor = WSRelayInterceptor(direction: .upstream, maskOutgoing: true,
                        loop: clientChannel.eventLoop,
                        emit: { [weak self] data, direction in self?.relayWebSocketBytes(data, direction: direction) },
                        close: { [weak self] in self?.closeWebSocketRelay() },
                        deflate: WebSocketDeflate.negotiated(in: resp.headers, direction: .upstream), issue: report,
                        script: { frame, done in
                            ScriptingService.rewriteFrame(plan: plan, frame: frame, graphqlName: graphqlName,
                                                          completion: done)
                        })
                    wsDownstreamInterceptor = WSRelayInterceptor(direction: .downstream, maskOutgoing: false,
                        loop: upstreamChannel.eventLoop,
                        emit: { [weak self] data, direction in self?.relayWebSocketBytes(data, direction: direction) },
                        close: { [weak self] in self?.closeWebSocketRelay() },
                        deflate: WebSocketDeflate.negotiated(in: resp.headers, direction: .downstream), issue: report,
                        script: { frame, done in
                            ScriptingService.rewriteFrame(plan: plan, frame: frame, graphqlName: graphqlName,
                                                          completion: done)
                        })
                }
            }
            sendResponseHead(resp, headers: resp.headers, pauseMs: simulation.responseDelay)
            mode = .wsRelay
            if downstreamInputClosed { finishWebSocketUpload() }
            refreshReads()
            return
        }

        // body framing 判定
        let te = (resp.headers.value(of: "Transfer-Encoding") ?? "").lowercased()
        let connectionClose = resp.headers.value(of: "Connection")?.lowercased().contains("close") ?? false
        var noBody = BreakpointMessage.noBodyStatus(resp.status) || tx.method == "HEAD" || (resp.status >= 100 && resp.status < 200)
        if !noBody, te.contains("chunked") {
            respChunked = ChunkedTracker()
        } else if let cl = resp.headers.value(of: "Content-Length"), let n = Int(cl) {
            if n == 0 { noBody = true } else if !noBody { respRemainingCL = n }
        } else if !noBody {
            respCloseDelimited = true   // 等上游关闭
        }
        stoppedUpload = reqChunked != nil || (reqRemainingCL ?? 0) > 0 || uploadPacer?.hasPendingWrites == true
        if stoppedUpload { cancelPacedUpload() }
        respShouldClose = connectionClose || respCloseDelimited || stoppedUpload
        refreshReads()

        let sink = conn.engine.sink
        if !noBody { bodyCapture?.setResponseHeadersForSSE(resp.headers) }
        let contentType = resp.headers.value(of: "Content-Type") ?? ""
        let headerAt = Date()
        onMain {
            tx.responseVersion = self.conn.http2WebSocket == nil ? resp.version : "HTTP/2"
            tx.statusCode = resp.status
            tx.statusReason = self.conn.http2WebSocket == nil ? resp.reason : ""
            tx.responseHeaders = self.conn.http2WebSocket?.captureHeaders(resp.headers, response: true) ?? resp.headers
            tx.contentType = contentType
            tx.tHeaderAt = headerAt
            sink?.transactionUpdated(tx)
        }

        // 转发响应头（重建，保序）；No Caching 开启时剥离缓存头
        var outHeaders = resp.headers
        if RulesStore.shared.snapshot().noCaching {
            for name in ["Cache-Control", "ETag", "Last-Modified", "Expires", "Age"] {
                outHeaders.remove(name: name)
            }
        }
        if respShouldClose || !keepAlive { outHeaders.set(name: "Connection", value: "close") }
        sendResponseHead(resp, headers: outHeaders, pauseMs: simulation.responseDelay)

        if noBody {
            onMain { tx.responseBodyComplete = true }
            finishRequest()
        }
    }

    private func recordWebSocketScriptIssue(_ text: String, target: ScriptingTarget, tx: Transaction) {
        let sink = conn.engine.sink
        DispatchQueue.main.async {
            let line = "WebSocket · \(text)"
            tx.appendScriptingLogs([line])
            ScriptingActivity.shared.record(url: target.url, lines: [line])
            sink?.transactionUpdated(tx)
        }
    }

    private func deliverResponseBody(_ bb: ByteBuffer) {
        guard bb.readableBytes > 0, mode == .inFlight else { return }

        let current = tx
        if var tracker = respChunked {
            do {
                let wireBytes = try tracker.consume(bb.readableBytesView) {
                    bodyCapture?.append($0, direction: .downstream)
                }
                var buffer = bb
                if let wire = buffer.readSlice(length: wireBytes) {
                    writeDownstream(wire, paced: true)
                }
                let trailers = tracker.trailers
                let complete = tracker.finished
                respChunked = complete ? nil : tracker
                if complete {
                    bodyCapture?.flush()
                    onMain { current?.responseTrailers = trailers }
                    finishRequest()
                }
            } catch {
                finishRequestWithFailure("无效的分块响应")
            }
        } else if let remaining = respRemainingCL {
            guard remaining > 0 else { return }
            var full = bb
            let bodyPart: ByteBuffer
            if full.readableBytes > remaining {
                bodyPart = full.readSlice(length: remaining) ?? full
                // 顺序 HTTP 下 CL 之外不应有额外数据；忽略
            } else {
                bodyPart = full
            }
            writeDownstream(bodyPart, paced: true)
            bodyCapture?.append(bodyPart.readableBytesView, direction: .downstream)
            respRemainingCL = remaining - bodyPart.readableBytes
            if respRemainingCL == 0 { finishRequest() }
        } else if respCloseDelimited {
            writeDownstream(bb, paced: true)
            bodyCapture?.append(bb.readableBytesView, direction: .downstream)
        }
    }

    // MARK: 请求完成 / 失败

    private func finishRequest() {
        guard mode == .inFlight else { return }
        bodyCapture?.flush()
        finishResponseWrites(transaction: tx, close: respShouldClose || !keepAlive)
    }

    private func finishResponseWrites(transaction: Transaction?, close: Bool) {
        bodyCapture?.finishSSE()
        let sink = conn.engine.sink
        let started = responseStart
        let upstreamElapsed = Date().timeIntervalSince(started)
        let waitsForPacer = downloadPacer?.hasPendingWrites == true
        mode = .finishingResponse
        closeAfterResponse = close
        responseWriteCompletion = { [weak self] result in
            if let transaction {
                let elapsed = waitsForPacer ? Date().timeIntervalSince(started) : upstreamElapsed
                onMain {
                    transaction.responseBodyComplete = true
                    transaction.duration = elapsed
                    switch result {
                    case .success:
                        transaction.state = .completed
                    case .failure(let error):
                        transaction.state = .failed
                        transaction.errorText = "向客户端写入响应失败：\(error.localizedDescription)"
                    }
                    sink?.transactionUpdated(transaction)
                }
            }
            guard let self, self.mode == .finishingResponse else { return }
            if self.closeAfterResponse || self.downstreamInputClosed || (try? result.get()) == nil {
                self.mode = .closed
                self.closeClient()
                self.tryCloseUpstream()
            } else {
                self.resetForNextRequest()
            }
        }
        if close { tryCloseUpstream() }
        refreshReads()
        afterDownstreamWrites { [weak self] result in
            guard let self, let loop = self.clientChannel?.eventLoop else { return }
            // Finish the current read before replaying bytes of a pipelined request.
            loop.execute { self.completeResponseWrite(result) }
        }
    }

    private func completeResponseWrite(_ result: Result<Void, Error>) {
        let completion = responseWriteCompletion
        responseWriteCompletion = nil
        completion?(result)
    }

    private func finishRequestWithFailure(_ text: String, status: Int = 502, reason: String = "Bad Gateway") {
        mapLocalSender?.cancel()
        mapLocalSender = nil
        bodyCapture?.finishSSE(complete: false)
        let generatedBody = respHeadParsed ? nil : Data("ProxyMirror: \(text)".utf8)
        if let tx {
            let sink = conn.engine.sink
            let elapsed = Date().timeIntervalSince(responseStart)
            onMain {
                tx.state = .failed
                tx.errorText = text
                tx.duration = elapsed
                if let body = generatedBody {
                    tx.statusCode = status
                    tx.statusReason = reason
                    tx.contentType = "text/plain"
                    tx.responseHeaders = HTTPHeaders([
                        ("Content-Type", "text/plain"), ("Content-Length", String(body.count)), ("Connection", "close"),
                    ])
                    if tx.method != "HEAD" { tx.appendResponseBody(body) }
                    tx.responseBodyComplete = true
                }
                sink?.transactionUpdated(tx)
            }
        }
        if respHeadParsed {
            mode = .closed
            closeDownstreamAfterWrites()
        } else {
            let body = generatedBody ?? Data()
            let payload = tx?.method == "HEAD" ? "" : String(decoding: body, as: UTF8.self)
            writeRawAndClose("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(payload)")
        }
        tryCloseUpstream()
    }

    private func resetForNextRequest() {
        mode = .readingHead
        headParser = RequestHeadParser()
        respParser = ResponseHeadParser()
        respHeadParsed = false
        respChunked = nil
        respRemainingCL = nil
        respCloseDelimited = false
        respShouldClose = false
        stoppedUpload = false
        reqChunked = nil
        reqRemainingCL = nil
        bodyCapture = nil
        tx = nil
        breakpointTarget = nil
        scriptingOperationName = nil
        pendingHeadBytes = nil
        pendingToUpstream.removeAll(keepingCapacity: true)
        pendingUploadBytes = 0
        upstreamReady = false
        simulation = LatencySimulation()
        closeAfterResponse = false

        // Preserve wire order even when a queued request finishes synchronously.
        let next = pipelined
        pipelined.removeAll(keepingCapacity: true)
        pipelinedBytes = 0
        for bb in next { receiveClientBytes(bb) }
        refreshReads()
    }

    // MARK: 错误 / 关闭

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if flagSuspectedPinningIfApplies(error) {
            context.close(promise: nil)
            mode = .closed
            return
        }
        switch mode {
        case .requestPaused, .responsePaused:
            failBreakpoint("断点等待期间连接已关闭")
        case .inFlight, .resolvingLocal, .sendingLocal:
            finishRequestWithFailure("连接错误: \(error)")
        case .tunnelRelay:
            mode = .closed
            clientChannel?.close(promise: nil)
        default:
            context.close(promise: nil)
            mode = .closed
        }
    }

    /// MITM 后客户端未发出任何明文请求、以证书相关 alert 拒绝代理证书 → 在 CONNECT 事务上标记疑似锁定
    @discardableResult
    private func flagSuspectedPinningIfApplies(_ error: Error) -> Bool {
        guard mitmActive, tx == nil, connectTx != nil,
              Self.looksLikeCertificateRejection(error), let connect = connectTx else { return false }
        connectTx = nil
        let sink = conn.engine.sink
        NSLog("[ProxyMirror] 疑似 SSL 证书锁定: \(connect.host)")
        onMain {
            connect.suspectedPinning = true
            sink?.transactionUpdated(connect)
        }
        return true
    }

    private static func looksLikeCertificateRejection(_ error: Error) -> Bool {
        var parts = [String(describing: error), error.localizedDescription]
        if let boring = error as? NIOSSL.BoringSSLError, case .sslError(let list) = boring {
            parts += list.map { String(describing: $0) }
        }
        if let extra = error as? NIOSSL.NIOSSLExtraError {
            parts.append(String(describing: extra) + " " + extra.localizedDescription)
        }
        let normalized = parts.joined(separator: " ").lowercased().replacingOccurrences(of: "_", with: " ")
        return ["certificate unknown", "bad certificate", "unknown ca", "certificate revoked",
                "certificate expired", "certificate verify failed"].contains { normalized.contains($0) }
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        wsUpstreamInterceptor?.cancel(); wsUpstreamInterceptor = nil
        wsDownstreamInterceptor?.cancel(); wsDownstreamInterceptor = nil
        mapLocalSender?.cancel()
        mapLocalSender = nil
        bodyCapture?.finishSSE(complete: false)
        bodyCapture = nil
        connectAttributionTimeout?.cancel()
        connectAttributionTimeout = nil
        downloadPacer?.cancel()
        downloadPacer = nil
        if breakpointGate != nil { failBreakpoint("断点等待期间客户端已断开") }
        if mode == .inFlight || mode == .sendingLocal, let tx {
            let sink = conn.engine.sink
            let duration = Date().timeIntervalSince(responseStart)
            onMain {
                tx.state = .failed
                tx.errorText = "客户端连接已关闭"
                tx.duration = duration
                sink?.transactionUpdated(tx)
            }
        }
        mode = .closed
        completeResponseWrite(.failure(ChannelError.ioOnClosedChannel))
        tryCloseUpstream()
        context.fireChannelUnregistered()
    }

    // MARK: 工具

    private func writeRaw(_ text: String) {
        writeDownstream(ByteBuffer(string: text), paced: false)
    }

    private func writeRawAndClose(_ text: String) {
        mode = .closed
        writeRaw(text)
        closeDownstreamAfterWrites()
    }

    private func tryCloseUpstream() {
        simulatedDelay?.cancel()
        simulatedDelay = nil
        let channel = upstreamChannel
        upstreamChannel = nil
        upstreamReusable = false
        upstreamReady = false
        cancelPacedUpload()
        if upstreamOrigin?.tls == true { try? channel?.syncOptions?.setOption(ChannelOptions.autoRead, value: true) }
        channel?.close(promise: nil)
    }

    private func cancelPacedUpload() {
        uploadPacer?.cancel()
        uploadPacer = nil
    }

    private func writeDownstream(_ bytes: ByteBuffer, paced: Bool, pauseMs: Int = 0) {
        guard let channel = clientChannel else { return }
        let rate = paced ? simulation.bandwidth.downloadKbps : nil
        let delay = paced ? simulation.bodyPause.sample() : pauseMs
        if (rate != nil || delay > 0), downloadPacer == nil {
            downloadPacer = BytePacingQueue(loop: channel.eventLoop, onBackpressure: { [weak self] _ in
                self?.refreshReads()
            }, onFailure: { [weak self] error in
                guard let self else { return }
                self.downloadPacer = nil
                if self.mode == .inFlight {
                    self.finishRequestWithFailure("限速写入失败：\(error.localizedDescription)")
                } else if self.mode == .finishingResponse {
                    self.completeResponseWrite(.failure(error))
                } else {
                    self.mode = .closed
                    self.tryCloseUpstream()
                    self.closeClient()
                }
            })
        }
        if let downloadPacer {
            downloadPacer.write(bytes, kilobitsPerSecond: rate, pauseMs: delay) { channel.writeAndFlush($0) }
        } else {
            channel.writeAndFlush(bytes, promise: nil)
        }
    }

    private func closeDownstreamAfterWrites() {
        refreshReads()
        afterDownstreamWrites { [weak self] _ in self?.closeClient() }
    }

    private func closeClient() {
        downstreamShutdownStarted = true
        refreshReads()
        clientChannel?.close(promise: nil)
    }

    private func afterDownstreamWrites(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard let channel = clientChannel, channel.isActive else {
            completion(.failure(ChannelError.ioOnClosedChannel))
            return
        }
        let drain = {
            // The zero-length write acknowledges all prior writes at the socket, including TLS output.
            channel.writeAndFlush(ByteBuffer()).whenComplete(completion)
        }
        if let downloadPacer { downloadPacer.afterWrites(drain) }
        else { drain() }
    }

    fileprivate func refreshReads() {
        guard let client = clientChannel, client.isActive else { return }
        let uploadWritable = upstreamChannel?.isWritable == true && uploadPacer?.isBackpressured != true
        let downloadWritable = client.isWritable && downloadPacer?.isBackpressured != true
        let pipelineHasRoom = pipelinedBytes < Self.pipelineHighWatermark && pipelined.count < Self.pipelineHighParts
        let readClient: Bool
        let readUpstream: Bool
        switch mode {
        case .readingHead:
            readClient = downloadWritable
            readUpstream = true
        case .requestPaused:
            readClient = breakpointGate?.submitted != true
            readUpstream = true
        case .inFlight, .responsePaused:
            readClient = !stoppedUpload && upstreamReady && uploadWritable && pipelineHasRoom
            readUpstream = !upstreamReady || (downloadWritable && breakpointGate?.submitted != true)
        case .tunnelRelay, .wsRelay:
            readClient = uploadWritable
            readUpstream = downloadWritable
        case .tlsPending:
            readClient = !conn.awaitingCertificate
            readUpstream = false
        case .resolvingLocal:
            readClient = false
            readUpstream = true
        case .sendingLocal:
            // On macOS NIO needs a read interest to observe EOF even when a write
            // is waiting. Pipelined input remains bounded by bufferPipeline.
            readClient = true
            readUpstream = false
        case .resolvingConnect, .tunnelConnecting, .finishingResponse:
            readClient = false
            readUpstream = false
        case .closed:
            readClient = mitmActive && downstreamShutdownStarted
            readUpstream = false
        }
        let clientReads = readClient && (!downstreamInputClosed || downstreamShutdownStarted)
        let wasReading = try? client.syncOptions?.getOption(ChannelOptions.autoRead)
        try? client.syncOptions?.setOption(ChannelOptions.autoRead, value: clientReads)
        if conn.http2WebSocket != nil, clientReads, wasReading != true {
            client.eventLoop.execute { if client.isActive { client.read() } }
        }
        try? upstreamChannel?.syncOptions?.setOption(ChannelOptions.autoRead, value: readUpstream)
    }
}

// MARK: - 工具函数

private func copyOf(_ bb: ByteBuffer) -> Data {
    Data(bb.readableBytesView)
}

func HTTPClientWantsClose(_ head: HTTPRequestHead) -> Bool {
    let conn = head.headers.value(of: "Connection")?.lowercased() ?? ""
    if conn.contains("close") { return true }
    if head.version == "HTTP/1.0" && !conn.contains("keep-alive") { return true }
    return false
}
