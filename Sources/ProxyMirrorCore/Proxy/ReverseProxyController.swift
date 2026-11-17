import Combine
import Foundation
import NIOCore
import NIOPosix

struct ReverseProxyRoute: Equatable, Sendable {
    let listenPort: UInt16
    let host: String
    let port: Int
    let scheme: String

    init(_ rule: ReverseProxyRule) throws {
        let host = URLParser.bareHost(rule.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines))
        let scheme = rule.remoteScheme?.lowercased() ?? "http"
        let isDNSName = !host.isEmpty && host.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
        }
        guard rule.listenPort >= 1024, (1...65535).contains(rule.remotePort),
              ["http", "https"].contains(scheme), isDNSName || URLParser.isIPAddress(host) else {
            throw ReverseProxyError.invalidRule(rule.name)
        }
        listenPort = rule.listenPort
        self.host = host
        port = rule.remotePort
        self.scheme = scheme
    }

    var endpoint: String { "\(scheme)://\(URLParser.authority(host: host, port: port, scheme: scheme))" }
    var isLoopback: Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "localhost." || host == "::1"
            || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    func clientURL(target: String) -> String { "http://127.0.0.1:\(listenPort)\(target)" }

    func forward(_ request: HTTPRequestHead) -> HTTPRequestHead? {
        guard request.method != "CONNECT", request.target.hasPrefix("/"), !request.target.contains("#") else { return nil }
        var request = request
        request.target = endpoint + request.target
        request.headers.set(name: "Host", value: URLParser.authority(host: host, port: port, scheme: scheme))
        return request
    }
}

enum ReverseProxyError: LocalizedError {
    case invalidRule(String), duplicatePort(UInt16), loop(UInt16), bind(UInt16, Error), save

    var errorDescription: String? {
        switch self {
        case .invalidRule(let name): return "「\(name)」需要有效的主机、HTTP 或 HTTPS 协议和端口。本地端口须在 1024 到 65535 之间。"
        case .duplicatePort(let port): return "多个启用的规则使用了本地端口 \(port)。"
        case .loop(let port): return "上游端口 \(port) 指向 ProxyMirror 本机监听端口。"
        case .bind(let port, let error): return "无法监听 127.0.0.1:\(port)（\(error.localizedDescription)）。"
        case .save: return "无法保存反向代理规则。"
        }
    }
}

/// Owns the accepted children as well as the listening channel, so removing a rule closes keep-alive connections.
private final class ReversePortListener: @unchecked Sendable {
    private let lock = NSLock()
    private var route: ReverseProxyRoute?
    private var listener: Channel?
    private var clients: [ObjectIdentifier: Channel] = [:]

    func bind(port: UInt16, engine: ProxyEngine) throws {
        listener = try ServerBootstrap(group: engine.group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [weak self, weak engine] channel in
                guard let self, let engine, let route = self.attach(channel) else {
                    return channel.eventLoop.makeFailedFuture(ProxyError.shutdown)
                }
                let state = ConnState(engine: engine, reverseRoute: route)
                let handler = ProxyConnectionHandler(conn: state)
                state.proxyHandler = handler
                return channel.pipeline.addHandler(handler)
            }
            .bind(host: "127.0.0.1", port: Int(port)).wait()
    }

    private func attach(_ client: Channel) -> ReverseProxyRoute? {
        let id = ObjectIdentifier(client)
        lock.lock()
        let selected = route
        if selected != nil { clients[id] = client }
        lock.unlock()
        if selected != nil {
            client.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.clients.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
        return selected
    }

    func update(_ next: ReverseProxyRoute?) {
        lock.lock()
        guard route != next else { lock.unlock(); return }
        route = next
        let disconnected = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        for client in disconnected { client.close(promise: nil) }
    }

    func close() {
        update(nil)
        try? listener?.close().wait()
        listener = nil
    }
}

@MainActor
final class ReverseProxyController: ObservableObject {
    static let shared = ReverseProxyController()

    @Published private(set) var rules = InterceptionConfig.shared.reverse.value
    @Published private(set) var listening: Set<UInt16> = []
    @Published private(set) var errors: [UInt16: String] = [:]

    private weak var engine: ProxyEngine?
    private var listeners: [UInt16: ReversePortListener] = [:]

    func start(engine: ProxyEngine) {
        stop()
        self.engine = engine
        let enabled = rules.filter(\.enabled)
        let localPorts = Set(enabled.map(\.listenPort)).union([engine.port])
        for rule in enabled {
            do {
                let route = try ReverseProxyRoute(rule)
                guard listeners[route.listenPort] == nil else { throw ReverseProxyError.duplicatePort(route.listenPort) }
                try validate(route, localPorts: localPorts)
                let listener = try bind(route.listenPort, engine: engine)
                listener.update(route)
                listeners[route.listenPort] = listener
            } catch {
                errors[rule.listenPort] = error.localizedDescription
            }
        }
        listening = Set(listeners.keys)
    }

    func stop() {
        for listener in listeners.values { listener.close() }
        listeners = [:]
        listening = []
        errors = [:]
        engine = nil
    }

    func save(_ edited: [ReverseProxyRule]) throws {
        var routes: [UInt16: ReverseProxyRoute] = [:]
        for rule in edited {
            let route = try ReverseProxyRoute(rule)
            guard rule.enabled else { continue }
            guard routes[route.listenPort] == nil else { throw ReverseProxyError.duplicatePort(route.listenPort) }
            routes[route.listenPort] = route
        }
        var localPorts = Set(routes.keys)
        if let engine { localPorts.insert(engine.port) }
        for route in routes.values { try validate(route, localPorts: localPorts) }

        var staged: [UInt16: ReversePortListener] = [:]
        do {
            if let engine {
                for port in routes.keys where listeners[port] == nil {
                    staged[port] = try bind(port, engine: engine)
                }
            }
            guard RulesFileIO.save(edited, "reverse.json") else { throw ReverseProxyError.save }
        } catch {
            for listener in staged.values { listener.close() }
            throw error
        }

        for port in Array(listeners.keys) where routes[port] == nil {
            listeners.removeValue(forKey: port)?.close()
        }
        listeners.merge(staged) { existing, _ in existing }
        for (port, listener) in listeners { listener.update(routes[port]) }
        InterceptionConfig.shared.reverse.set(edited)
        rules = edited
        listening = Set(listeners.keys)
        errors = [:]
    }

    private func validate(_ route: ReverseProxyRoute, localPorts: Set<UInt16>) throws {
        if route.isLoopback && localPorts.contains(UInt16(route.port)) {
            throw ReverseProxyError.loop(UInt16(route.port))
        }
    }

    private func bind(_ port: UInt16, engine: ProxyEngine) throws -> ReversePortListener {
        let listener = ReversePortListener()
        do { try listener.bind(port: port, engine: engine) }
        catch { throw ReverseProxyError.bind(port, error) }
        return listener
    }
}
