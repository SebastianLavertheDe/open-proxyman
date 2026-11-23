import Foundation
import NIOCore
import ProxyMirrorProtocolSupport

/// SOCKS5 CONNECT shares the HTTP listener and its access-control policy. After
/// negotiation, translating to the existing CONNECT path retains SSL rules,
/// interception, capture, upstream routing, pacing and tunnel backpressure.
/// BIND/UDP ASSOCIATE and username/password authentication are not advertised.
final class SOCKS5ProxyHandshake: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Stage { case detecting, greeting, request, connecting, relay, failed }
    private var stage = Stage.detecting
    private var input = ByteBuffer()
    private var response = ByteBuffer()
    private var promises: [EventLoopPromise<Void>] = []
    private var deadline: Scheduled<Void>?
    private let conn: ConnState

    init(conn: ConnState) { self.conn = conn }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if stage == .relay { context.fireChannelRead(data); return }
        guard stage != .failed else { return }
        var bytes = unwrapInboundIn(data)
        if stage == .detecting, let first: UInt8 = bytes.getInteger(at: bytes.readerIndex), first != 5 {
            stage = .relay
            context.fireChannelRead(data)
            context.pipeline.removeHandler(self, promise: nil)
            return
        }
        guard bytes.readableBytes <= 64 * 1024 - input.readableBytes else {
            reject(1, context: context); return
        }
        input.writeBuffer(&bytes)
        if stage == .detecting {
            guard let first: UInt8 = input.getInteger(at: input.readerIndex) else { return }
            guard first == 5 else {
                stage = .relay
                if let bytes = input.readSlice(length: input.readableBytes) {
                    context.fireChannelRead(wrapInboundOut(bytes))
                }
                context.pipeline.removeHandler(self, promise: nil)
                return
            }
            stage = .greeting
            deadline = context.eventLoop.scheduleTask(in: .seconds(10)) { [weak self] in
                self?.reject(1, context: context)
            }
        }
        advance(context)
    }

    private func advance(_ context: ChannelHandlerContext) {
        if stage == .greeting {
            let bytes = Array(input.readableBytesView)
            var consumed = 0
            let status = bytes.withUnsafeBufferPointer { pm_socks5_greeting($0.baseAddress, $0.count, &consumed) }
            guard status != 0 else { return }
            guard status == 1 else {
                stage = .failed
                deadline?.cancel()
                context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, 255]))).whenComplete { _ in
                    context.close(promise: nil)
                }
                return
            }
            input.moveReaderIndex(forwardBy: consumed)
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, 0])), promise: nil)
            stage = .request
        }
        guard stage == .request else { return }
        let bytes = Array(input.readableBytesView)
        var parsed = pm_socks5_request()
        let status = bytes.withUnsafeBufferPointer { pm_socks5_parse_request($0.baseAddress, $0.count, &parsed) }
        guard status != 0 else { return }
        guard status == 1 else { reject(UInt8(-status), context: context); return }
        let rawAddress = Array(bytes[parsed.address_offset..<(parsed.address_offset + parsed.address_length)])
        let address: String
        switch parsed.address_type {
        case 1: address = rawAddress.map(String.init).joined(separator: ".")
        case 4:
            address = stride(from: 0, to: 16, by: 2).map {
                String(UInt16(rawAddress[$0]) << 8 | UInt16(rawAddress[$0 + 1]), radix: 16)
            }.joined(separator: ":")
        case 3:
            guard let name = String(bytes: rawAddress, encoding: .utf8) else { reject(8, context: context); return }
            address = name
        default: reject(8, context: context); return
        }
        let port = parsed.port
        guard let host = ExternalProxyHost(address) else { reject(8, context: context); return }
        let isLocalAddress = LANAccess.addresses.contains { address in
            if let lhs = NumericIPAddress(address), let rhs = NumericIPAddress(host.name) { return lhs.bytes == rhs.bytes }
            return address == host.name
        }
        if port == conn.engine.port, host.isLoopback || isLocalAddress {
            reject(2, context: context); return
        }
        input.moveReaderIndex(forwardBy: parsed.consumed)
        stage = .connecting
        conn.isSOCKS5 = true
        let authority = host.authority(port: Int(port))
        let request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n"
        context.fireChannelRead(wrapInboundOut(ByteBuffer(string: request)))
        context.fireChannelReadComplete()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard stage == .connecting else { context.write(data, promise: promise); return }
        if let promise { promises.append(promise) }
        var bytes = unwrapOutboundIn(data)
        guard bytes.readableBytes <= 64 * 1024 - response.readableBytes else {
            reject(1, context: context); return
        }
        response.writeBuffer(&bytes)
        let all = Array(response.readableBytesView)
        guard all.count >= 4, let end = (0...(all.count - 4)).first(where: {
            all[$0] == 13 && all[$0 + 1] == 10 && all[$0 + 2] == 13 && all[$0 + 3] == 10
        }) else { return }
        let head = String(decoding: all.prefix(end), as: UTF8.self)
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let fields = firstLine.split(separator: " ")
        guard fields.count >= 2, let status = Int(fields[1]) else { reject(1, context: context); return }
        guard (200..<300).contains(status) else {
            reject(status == 403 || status == 407 ? 2 : 5, context: context)
            return
        }
        let headerLength = end + 4
        response.moveReaderIndex(forwardBy: headerLength)
        stage = .relay
        deadline?.cancel()
        // The internal HTTP CONNECT path has accepted responsibility for the
        // tunnel; future connection errors follow its existing close semantics.
        let sent = context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])))
        let waiting = promises
        promises.removeAll()
        sent.whenComplete { result in
            for promise in waiting { promise.completeWith(result) }
            switch result {
            case .failure: context.close(promise: nil)
            case .success:
                if let leftover = self.response.readSlice(length: self.response.readableBytes), leftover.readableBytes > 0 {
                    context.writeAndFlush(self.wrapOutboundOut(leftover), promise: nil)
                }
                // Leave the current CONNECT call stack before replaying bytes.
                context.eventLoop.execute {
                    if let pending = self.input.readSlice(length: self.input.readableBytes), pending.readableBytes > 0 {
                        context.fireChannelRead(self.wrapInboundOut(pending))
                        context.fireChannelReadComplete()
                    }
                    context.pipeline.removeHandler(self, promise: nil)
                }
            }
        }
    }

    private func reject(_ code: UInt8, context: ChannelHandlerContext) {
        guard stage != .failed, stage != .relay else { return }
        stage = .failed
        deadline?.cancel()
        let error = ChannelError.inappropriateOperationForState
        for promise in promises { promise.fail(error) }
        promises.removeAll()
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: [5, code, 0, 1, 0, 0, 0, 0, 0, 0]))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        for promise in promises { promise.fail(ChannelError.ioOnClosedChannel) }
        promises.removeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
