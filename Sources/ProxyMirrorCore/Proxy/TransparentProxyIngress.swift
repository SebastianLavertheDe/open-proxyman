import CryptoKit
import Foundation
import NIOCore
import NIOPosix

struct TransparentProxyFlow: Decodable, Sendable {
    let host: String
    let port: Int
    let address: String?
    let application: String?

    var dialHost: String { address ?? host }

    var isValid: Bool {
        guard port == 80 || port == 443,
              Self.isIPAddress(host) || Self.isDNSName(host),
              address.map(Self.isIPAddress) ?? true else { return false }
        return application.map {
            !$0.isEmpty && $0.utf8.count <= 255 &&
            !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        } ?? true
    }

    private static func isIPAddress(_ host: String) -> Bool {
        !host.utf8.contains(0) && URLParser.isIPAddress(host)
    }

    private static func isDNSName(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? host.dropLast() : host[...]
        return !name.isEmpty && name.utf8.count <= 253 &&
            name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
            }
    }

    func mark(_ tx: Transaction) {
        tx.isTransparent = true
        tx.clientBundle = application
        tx.clientName = application ?? "透明代理"
        tx.clientAddress = nil
        tx.peerPort = 0
    }

    func upstreamHost(for tx: Transaction) -> String {
        tx.resolvedAddress ?? (tx.matchedByMapRemote ? tx.host : dialHost)
    }
}

final class TransparentProxyIngress: @unchecked Sendable {
    enum Failure: Error { case unavailable }

    let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    private var listener: Channel?
    private let lock = NSLock()
    private var accepting = true
    private var children: [ObjectIdentifier: Channel] = [:]
    // Only authenticated requests consume replay state.
    private var nonces: Set<UUID> = []

    var port: UInt16? { listener?.localAddress?.port.flatMap(UInt16.init(exactly:)) }

    func start(group: EventLoopGroup, engine: ProxyEngine) throws {
        listener = try ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [weak self, weak engine] channel in
                guard let self, let engine, self.track(channel) else {
                    return channel.eventLoop.makeFailedFuture(Failure.unavailable)
                }
                let conn = ConnState(engine: engine)
                let sniffer = SniPeekHandler(state: conn)
                let proxy = ProxyConnectionHandler(conn: conn)
                conn.proxyHandler = proxy
                conn.snifferHandler = sniffer
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        TransparentProxyHandshake(ingress: self, conn: conn), sniffer, proxy
                    ])
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    func stop() {
        let active = lock.withLock {
            accepting = false
            let active = Array(children.values)
            children.removeAll()
            nonces.removeAll()
            return active
        }
        try? listener?.close().wait()
        listener = nil
        for child in active { child.close(promise: nil) }
    }

    private func track(_ channel: Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        let accepted = lock.withLock {
            guard accepting, children.count < 1024 else { return false }
            children[id] = channel
            return true
        }
        if accepted {
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.children.removeValue(forKey: id) }
            }
        }
        return accepted
    }

    fileprivate func authenticate(_ lines: [String]) -> (TransparentProxyFlow, String)? {
        let prefix = "PMTP/1 "
        guard lines.count == 3, lines[0].hasPrefix(prefix), lines[2].utf8.count == 64 else { return nil }
        let nonceString = String(lines[0].dropFirst(prefix.count))
        guard let nonce = UUID(uuidString: nonceString), nonce.uuidString.lowercased() == nonceString else { return nil }
        let mac = Array(lines[2].utf8)
        func nibble(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 97...102: return value - 87
            default: return nil
            }
        }
        var code = Data(capacity: 32)
        for i in stride(from: 0, to: mac.count, by: 2) {
            guard let high = nibble(mac[i]), let low = nibble(mac[i + 1]) else { return nil }
            code.append(high << 4 | low)
        }
        let key = SymmetricKey(data: Data(token.utf8))
        let message = Data("\(lines[0])\r\n\(lines[1])\r\n".utf8)
        guard HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: message, using: key),
              let flow = try? JSONDecoder().decode(TransparentProxyFlow.self, from: Data(lines[1].utf8)),
              flow.isValid, claim(nonce) else { return nil }
        let response = HMAC<SHA256>.authenticationCode(for: Data("PMTP/1 OK \(nonceString)\r\n".utf8), using: key)
        return (flow, "OK " + response.map { String(format: "%02x", $0) }.joined() + "\r\n")
    }

    private func claim(_ nonce: UUID) -> Bool {
        lock.withLock {
            // Keep all accepted challenges for this session. A bounded set fails closed if saturated.
            guard accepting, nonces.count < 1_048_576, !nonces.contains(nonce) else { return false }
            return nonces.insert(nonce).inserted
        }
    }
}

private final class TransparentProxyHandshake: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let ingress: TransparentProxyIngress
    private let conn: ConnState
    private var deadline: Scheduled<Void>?
    private var header = [UInt8]()
    private var endings = [Int]()

    init(ingress: TransparentProxyIngress, conn: ConnState) {
        self.ingress = ingress
        self.conn = conn
    }

    func channelActive(context: ChannelHandlerContext) {
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: .seconds(3)) { bound.value.close(promise: nil) }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        while let byte = buffer.readInteger(as: UInt8.self), header.count < 4096 {
            header.append(byte)
            if byte == 10 {
                guard header.count > 1, header[header.count - 2] == 13 else { break }
                endings.append(header.count)
                if endings.count == 3 {
                    let lines = zip([0] + endings, endings).compactMap { start, end in
                        String(bytes: header[start..<(end - 2)], encoding: .utf8)
                    }
                    guard let (flow, response) = ingress.authenticate(lines) else { break }
                    deadline?.cancel()
                    conn.transparentFlow = flow
                    context.writeAndFlush(NIOAny(ByteBuffer(string: response)), promise: nil)
                    conn.proxyHandler?.beginTransparentFlow()
                    if buffer.readableBytes > 0 { context.fireChannelRead(NIOAny(buffer)) }
                    context.pipeline.syncOperations.removeHandler(self, promise: nil)
                    return
                }
            }
            if buffer.readableBytes == 0, header.count < 4096 { return }
        }
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? ChannelEvent) == .inputClosed {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        deadline?.cancel()
    }
}
