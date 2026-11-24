import Foundation
import NIOCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs at the resolved socket address boundary, including Happy Eyeballs
/// attempts. No hostname preflight can protect against DNS rebinding.
final class ProxySelfConnectionGuard: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer

    struct Rejected: LocalizedError {
        var errorDescription: String? { "Target resolves to ProxyMirror's own listener." }
    }

    private let port: Int
    private let localAddresses: Set<Data>

    init(port: Int, addresses: [String]) {
        self.port = port
        localAddresses = Set(addresses.compactMap(Self.numericAddress))
    }

    func rejects(_ address: SocketAddress) -> Bool {
        guard address.port == port, let ip = address.ipAddress, let bytes = Self.numericAddress(ip) else { return false }
        let loopback = bytes.count == 4 ? bytes.first == 127 : bytes == Data(repeating: 0, count: 15) + Data([1])
        // Some kernels route an unspecified destination back to this host.
        return loopback || bytes.allSatisfy({ $0 == 0 }) || localAddresses.contains(bytes)
    }

    func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        guard !rejects(address) else {
            promise?.fail(Rejected())
            context.close(promise: nil)
            return
        }
        context.connect(to: address, promise: promise)
    }

    private static func numericAddress(_ input: String) -> Data? {
        guard let literal = input.split(separator: "%", maxSplits: 1).first else { return nil }
        let value = String(literal)
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 { return withUnsafeBytes(of: &ipv4) { Data($0) } }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, value, &ipv6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &ipv6) { Data($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 { return Data(bytes.suffix(4)) }
        return bytes
    }
}
