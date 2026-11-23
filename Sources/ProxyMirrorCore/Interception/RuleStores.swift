import Foundation

// MARK: - 规则模型（Map Local / Rewrite / Breakpoint / DNS Spoofing / Reverse Proxy / 网速模拟 / 外部代理 / h2c 上游）

/// Rewrite 动作
enum RewriteAction: Codable, Hashable, Identifiable {
    case requestHeader(op: HeaderOp, name: String, value: String)
    case responseHeader(op: HeaderOp, name: String, value: String)
    case redirect(scheme: String, host: String, port: Int)   // 空 scheme/host = 不变
    case replaceRequestBody(find: String, replace: String, isRegex: Bool)
    case replaceResponseBody(find: String, replace: String, isRegex: Bool)
    case setStatus(Int)
    case script(phase: ScriptingPhase, source: String)

    enum HeaderOp: String, Codable, CaseIterable {
        case set
        case add
        case remove
        case replaceExisting
        var localizedTitle: String {
            switch self {
            case .set: return Strings.Models.headerOperationSet
            case .add: return Strings.Models.headerOperationAdd
            case .remove: return Strings.Models.headerOperationRemove
            case .replaceExisting: return Strings.Models.headerOperationReplaceExisting
            }
        }
    }

    var id: String { hashValue.description }
    var summary: String {
        switch self {
        case .requestHeader(let op, let n, _): return Strings.Models.rewriteRequestHeaderSummary(op.localizedTitle, n)
        case .responseHeader(let op, let n, _): return Strings.Models.rewriteResponseHeaderSummary(op.localizedTitle, n)
        case .redirect(_, let h, let p): return Strings.Models.rewriteRedirectSummary(h + (p > 0 ? ":\(p)" : ""))
        case .replaceRequestBody(let f, _, let re): return Strings.Models.rewriteRequestBodySummary(re ? "(regex)" : "", f)
        case .replaceResponseBody(let f, _, let re): return Strings.Models.rewriteResponseBodySummary(re ? "(regex)" : "", f)
        case .setStatus(let c): return Strings.Models.rewriteStatusSummary(c)
        case .script(let phase, _): return Strings.Models.rewriteScriptSummary(phase.label)
        }
    }
}

/// Rewrite 规则（规则集内多条规则按序执行）
struct RewriteRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var rule: URLRule = URLRule()
    var actions: [RewriteAction] = []
}

/// Rewrite 规则集（Proxyman 的 Scripting 分组概念，简化为分组列表）
struct RewriteRuleSet: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = Strings.Models.ruleSetDefaultName
    var enabled: Bool = true
    var rules: [RewriteRule] = []
}

/// Breakpoint 规则
struct BreakpointRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var rule: URLRule = URLRule()
    var phase: Phase = .request

    enum Phase: String, Codable, CaseIterable {
        case request = "Request"
        case response = "Response"
        var localizedTitle: String {
            switch self {
            case .request: return Strings.Models.breakpointPhaseRequest
            case .response: return Strings.Models.breakpointPhaseResponse
            }
        }
    }
}

/// DNS Spoofing：主机模式 → IP
struct DNSSpoofRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String?
    var hostPattern: String = ""        // 支持 *.example.com
    var ip: String = ""

    func matches(host: String) -> Bool {
        ConnState.hostMatches(host: host, pattern: hostPattern)
    }
}

/// Reverse Proxy：本地监听端口 → 远端 host:port
struct ReverseProxyRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var name: String = Strings.Models.reverseProxyDefaultName
    var listenPort: UInt16 = 0          // 10000-65535
    var remoteHost: String = ""
    var remotePort: Int = 80
    var remoteScheme: String?
}

/// 外部代理（上游链路）
struct ExternalProxyConfig: Codable, Hashable {
    var enabled: Bool = false
    var mode: Mode = .http
    var host: String = "127.0.0.1"
    var port: Int = 8080
    var useAuth: Bool = false
    var username: String = ""
    var password: String = ""
    var bypassHosts: [String]?
    var pacURL: String?
    /// nil retains the historical bypass-list behavior when reading old backups.
    var routingMode: RoutingMode?
    var includedTargets: [String]?

    enum RoutingMode: String, Codable, CaseIterable {
        case all, bypass, inclusive
        var title: String { localizedTitle }
        var localizedTitle: String {
            switch self {
            case .all: return Strings.Models.externalRoutingAll
            case .bypass: return Strings.Models.externalRoutingBypass
            case .inclusive: return Strings.Models.externalRoutingInclusive
            }
        }
    }
    var effectiveRoutingMode: RoutingMode { routingMode ?? .bypass }

    enum Mode: String, Codable, CaseIterable {
        case http = "HTTP"
        case https = "HTTPS"
        case socks5 = "SOCKS5"
        case pac = "PAC"
        var localizedTitle: String {
            switch self {
            case .http: return Strings.Models.externalModeHttp
            case .https: return Strings.Models.externalModeHttps
            case .socks5: return Strings.Models.externalModeSocks5
            case .pac: return Strings.Models.externalModePac
            }
        }
    }
}

/// HTTP/2 明文上游 (h2c)
struct H2CUpstreamConfig: Codable, Hashable {
    var enabled: Bool = false
    var hosts: [String] = []            // wildcard 模式列表；空 + enabled = 对所有 http 上游启用

    func matches(host: String) -> Bool {
        guard enabled else { return false }
        if hosts.isEmpty { return true }
        return hosts.contains { URLRule.wildcardMatch($0, value: host) }
    }
}

// MARK: - JSON 持久化

enum RulesFileIO {
    static var dir: URL {
        let base = CertificateAuthority.applicationSupport
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func load<T: Codable>(_ file: String) -> T? {
        let url = dir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        if let backup = value as? RuleBackup, backup.version != RuleBackup.currentVersion { return nil }
        return value
    }

    @discardableResult
    static func save<T: Codable>(_ value: T, _ file: String) -> Bool {
        let url = dir.appendingPathComponent(file)
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

// MARK: - 线程安全盒

final class LockedBox<T> {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { self._value = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ v: T) {
        lock.lock(); _value = v; lock.unlock()
    }
}

// MARK: - 拦截配置中心（引擎线程读取快照；UI 线程写入）

final class InterceptionConfig: @unchecked Sendable {
    static let shared = InterceptionConfig()

    let rewrite = LockedBox<[RewriteRuleSet]>([])
    let breakpoints = LockedBox<[BreakpointRule]>([])
    let dnsSpoof = LockedBox<[DNSSpoofRule]>([])
    let reverse = LockedBox<[ReverseProxyRule]>([])
    let externalProxy = LockedBox<ExternalProxyConfig>(ExternalProxyConfig())
    let h2cUpstream = LockedBox<H2CUpstreamConfig>(H2CUpstreamConfig())

    private init() { loadAll() }

    func mappedIP(for host: String) -> String? {
        dnsSpoof.value.first {
            $0.enabled && RuleOrganizationStore.shared.ruleIsEnabled(tool: "dns", id: $0.id)
                && URLParser.isIPAddress($0.ip) && $0.matches(host: host)
        }?.ip
    }

    func loadAll() {
        let consolidated: RuleBackup? = RulesFileIO.load("rules.json")
        if let v = consolidated?.rewrite { rewrite.set(v) }
        if let v = consolidated?.breakpoints { breakpoints.set(v) }
        if let v = consolidated?.dns { dnsSpoof.set(v) }
        if let v = consolidated?.reverse { reverse.set(v) }
        if let v = consolidated?.external { externalProxy.set(v) }
        if let v = consolidated?.h2c ?? RulesFileIO.load("h2c.json") { h2cUpstream.set(v) }
    }

    func h2cEnabled(host: String) -> Bool {
        h2cUpstream.value.matches(host: host)
    }


}
