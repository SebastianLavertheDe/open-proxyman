import Darwin
import Foundation
import NIOCore
import NIOPosix

/// Supplies both address families to ClientBootstrap's Happy Eyeballs connector.
final class TimedDNSResolver: Resolver, @unchecked Sendable {
    private static let resolverQueue = DispatchQueue(label: "ProxyMirror.DNS", qos: .utility, attributes: .concurrent)
    private let loop: EventLoop
    private let v4: EventLoopPromise<[SocketAddress]>
    private let v6: EventLoopPromise<[SocketAddress]>
    private let timing = LockedBox<Double?>(nil)
    private var started = false

    var milliseconds: Double? { timing.value }

    init(loop: EventLoop) {
        self.loop = loop
        v4 = loop.makePromise()
        v6 = loop.makePromise()
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        start(host: host, port: port)
        return v4.futureResult
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        start(host: host, port: port)
        return v6.futureResult
    }

    // getaddrinfo is blocking on the worker, so there is no cancellable system request.
    func cancelQueries() {}

    private func start(host: String, port: Int) {
        loop.assertInEventLoop()
        guard !started else { return }
        started = true
        let began = DispatchTime.now().uptimeNanoseconds
        Self.resolverQueue.async {
            let result = Result { try Self.resolve(host, port: port) }
            self.timing.set(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            self.v4.completeWith(result.map(\.ipv4))
            self.v6.completeWith(result.map(\.ipv6))
        }
    }

    private static func resolve(_ host: String, port: Int) throws -> (ipv4: [SocketAddress], ipv6: [SocketAddress]) {
        var head: UnsafeMutablePointer<addrinfo>?
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_NUMERICSERV
        guard getaddrinfo(host, String(port), &hints, &head) == 0, let head else {
            throw SocketAddressError.unknown(host: host, port: port)
        }
        defer { freeaddrinfo(head) }

        var ipv4: [SocketAddress] = []
        var ipv6: [SocketAddress] = []
        for node in sequence(first: head, next: { $0.pointee.ai_next }) {
            let info = node.pointee
            guard let address = info.ai_addr else { continue }
            if info.ai_family == AF_INET {
                let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                ipv4.append(SocketAddress(value, host: host))
            } else if info.ai_family == AF_INET6 {
                let value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                ipv6.append(SocketAddress(value, host: host))
            }
        }
        return (ipv4, ipv6)
    }
}
