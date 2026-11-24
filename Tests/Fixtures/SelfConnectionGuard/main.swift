import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix

@main
struct SelfConnectionGuardChecks {
    static func main() throws {
        var count = 0
        for ip in ["127.0.0.1", "127.12.0.3", "::1", "::ffff:127.0.0.1", "192.0.2.7", "::ffff:192.0.2.7", "2001:db8::7", "0.0.0.0", "::", "::ffff:0.0.0.0"] {
            let channel = EmbeddedChannel(handler: ProxySelfConnectionGuard(port: 9090, addresses: ["127.0.0.1", "192.0.2.7", "2001:db8:0:0::7"]))
            do {
                try channel.connect(to: SocketAddress(ipAddress: ip, port: 9090)).wait()
                preconditionFailure("Connected to own listener: \(ip)")
            } catch is ProxySelfConnectionGuard.Rejected { count += 1 }
            _ = try? channel.finish()
        }
        for (ip, port) in [("127.0.0.1", 8080), ("192.0.2.8", 9090), ("2001:db8::8", 9090)] {
            let channel = EmbeddedChannel(handler: ProxySelfConnectionGuard(port: 9090, addresses: ["192.0.2.7", "2001:db8::7"]))
            try channel.connect(to: SocketAddress(ipAddress: ip, port: port)).wait()
            count += 1
            _ = try channel.finish()
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group).childChannelInitializer { $0.close() }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let port = server.localAddress!.port!
        // A baseline confirms localhost resolves on this host, then the exact
        // same DNS/Happy Eyeballs connection is rejected by the production guard.
        let baseline = try ClientBootstrap(group: group).connect(host: "localhost", port: port).wait()
        try? baseline.close().wait()
        do {
            _ = try ClientBootstrap(group: group).channelInitializer { channel in
                channel.pipeline.addHandler(ProxySelfConnectionGuard(port: port, addresses: ["127.0.0.1"]))
            }.connect(host: "localhost", port: port).wait()
            preconditionFailure("DNS-resolved self connection succeeded")
        } catch {
            precondition(String(describing: error).contains("Rejected"), "Unexpected DNS failure: \(error)")
            count += 1
        }
        print("PASS: \(count) NIO resolved-connect rejection and allowed-port checks")
    }
}
