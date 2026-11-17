import Foundation
import Combine
import NIOCore
import NIOSSL

/// 规则模型（Map Local / Map Remote / Block / Allow / SSL Proxying 通用）
struct ProxyRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var enabled = true
    /// 匹配模式：支持 * 通配符，对完整 URL 匹配；空串=匹配所有
    var pattern: String
    /// Map Local: 本地文件路径；Map Remote: 目标 URL 前缀（https://host[:port]/base）
    var target: String = ""
    var comment: String = ""
    var responseStatus: Int?
    var responseHeaders: HTTPHeaders?
    var urlRegex: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.enabled == rhs.enabled && lhs.pattern == rhs.pattern
            && lhs.target == rhs.target && lhs.comment == rhs.comment
            && lhs.responseStatus == rhs.responseStatus && lhs.responseHeaders?.rawBytes == rhs.responseHeaders?.rawBytes
            && lhs.urlRegex == rhs.urlRegex
    }
}

/// G7：按域名自定义服务端证书（MITM 命中域名时直接使用指定证书链而非动态签发）
struct CustomCertificateRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    /// 通配：*.example.com / example.com
    var hostPattern: String = ""
    /// PEM 证书链文件（叶子在前，含中间证书）
    var certificatePath: String = ""
    /// PEM 私钥文件
    var privateKeyPath: String = ""

    func matches(host: String) -> Bool {
        guard enabled, !hostPattern.isEmpty else { return false }
        return ConnState.hostMatches(host: host, pattern: hostPattern)
    }
}

/// 解析 + 缓存自定义证书链（按文件路径对缓存；规则编辑时整体失效）
final class CustomCertificateStore: @unchecked Sendable {
    static let shared = CustomCertificateStore()
    private let lock = NSLock()
    private var cache: [String: CertificateAuthority.CustomChain] = [:]

    func invalidate() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    func chain(forHost host: String) -> CertificateAuthority.CustomChain? {
        let snapshot = RulesStore.shared.snapshot()
        guard let rule = snapshot.customCertificates.first(where: { $0.matches(host: host) }) else { return nil }
        let key = rule.certificatePath + "|" + rule.privateKeyPath
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let chain = Self.load(rule: rule) else { return nil }
        cache[key] = chain
        return chain
    }

    static func splitCertificates(_ pem: String) -> [NIOSSLCertificate] {
        var result: [NIOSSLCertificate] = []
        var pending = Substring(pem)
        while let start = pending.range(of: "-----BEGIN CERTIFICATE-----") {
            guard let end = pending[start.upperBound...].range(of: "-----END CERTIFICATE-----") else { break }
            let block = String(pending[start.lowerBound..<end.upperBound])
            if let certificate = try? NIOSSLCertificate(bytes: Array(block.utf8), format: .pem) {
                result.append(certificate)
            }
            pending = pending[end.upperBound...]
        }
        return result
    }

    static func load(rule: CustomCertificateRule) -> CertificateAuthority.CustomChain? {
        guard let certPEM = try? String(contentsOfFile: rule.certificatePath, encoding: .utf8),
              let keyPEM = try? String(contentsOfFile: rule.privateKeyPath, encoding: .utf8) else { return nil }
        let certificates = splitCertificates(certPEM)
        guard let key = try? NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem),
              !certificates.isEmpty else { return nil }
        return CertificateAuthority.CustomChain(certificates: certificates, privateKey: key)
    }
}

struct SSLApplicationRule: Codable, Identifiable, Equatable {
    enum Action: String, Codable, CaseIterable {
        case decrypt, passthrough

        var title: String { self == .decrypt ? "解密" : "透传" }
    }

    var enabled = true
    var bundleID: String
    var name = ""
    var action: Action = .decrypt
    var id: String { Self.normalize(bundleID) }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleID.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }
    }
}

/// Map Remote 改写结果
struct MapRemoteTarget {
    var scheme: String
    var host: String
    var port: Int
    var pathPrefix: String
    var query: String?

    func requestTarget(path: String, query originalQuery: String) -> String {
        let prefix = pathPrefix == "/" ? "" : pathPrefix
        let joined = prefix.hasSuffix("/") && path.hasPrefix("/") ? String(prefix.dropLast()) + path : prefix + path
        let query = query ?? originalQuery
        return joined + (query.isEmpty ? "" : "?" + query)
    }
}

struct PreparedMapLocalResponse: Sendable {
    let body: MapLocalFile?
    let contentLength: Int
    let contentType: String
    let status: Int
    let headers: HTTPHeaders
}

/// 供引擎线程使用的不可变快照
struct RulesSnapshot {
    var mapLocal: [ProxyRule] = []
    var mapRemote: [ProxyRule] = []
    var blockList: [ProxyRule] = []
    var allowList: [ProxyRule] = []
    var sslProxyingList: [ProxyRule] = []
    var sslApplications: [SSLApplicationRule] = []
    var customCertificates: [CustomCertificateRule] = []
    var noCaching = false

    /// 测试/工具用：直接构造快照（绕开共享 store）
    static func snapshotForTesting(customCertificates: [CustomCertificateRule]) -> RulesSnapshot {
        var snapshot = RulesSnapshot()
        snapshot.customCertificates = customCertificates
        return snapshot
    }

    static func matches(pattern: String, url: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        if pattern == "*" { return true }
        if pattern.contains("*") {
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
            var cursor = url.startIndex
            for (i, part) in parts.enumerated() {
                let p = String(part)
                if p.isEmpty { continue }
                if i == 0 {
                    guard url.hasPrefix(p) else { return false }
                    cursor = url.index(cursor, offsetBy: p.count)
                } else if i == parts.count - 1 {
                    guard url.hasSuffix(p), url.index(url.endIndex, offsetBy: -p.count) >= cursor else { return false }
                } else {
                    guard let range = url.range(of: p, range: cursor..<url.endIndex) else { return false }
                    cursor = range.upperBound
                }
            }
            return true
        }
        return url.hasPrefix(pattern) || url.contains(pattern)
    }

    func firstEnabled(_ list: [ProxyRule], url: String) -> ProxyRule? {
        list.first { rule in
            guard rule.enabled else { return false }
            guard let pattern = rule.urlRegex else { return Self.matches(pattern: rule.pattern, url: url) }
            return URLRule.regexCache(pattern)?.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
    }

    /// Map Local 命中 → 返回本地文件内容与 Content-Type
    func mapLocalResponse(for url: String) -> (data: Data, contentType: String, status: Int, headers: HTTPHeaders)? {
        guard let rule = firstEnabled(mapLocal, url: url), !rule.target.isEmpty,
              let file = Self.localFile(target: rule.target, requestURL: url),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let response = Self.mapLocalMetadata(rule, file: file)
        return (data, response.contentType, response.status, response.headers)
    }

    func prepareMapLocalResponse(for url: String, includeBody: Bool, on loop: EventLoop)
        -> EventLoopFuture<PreparedMapLocalResponse?>? {
        guard let rule = firstEnabled(mapLocal, url: url), !rule.target.isEmpty else { return nil }
        guard MapLocalFileWorker.preparationSlots.wait(timeout: .now()) == .success else {
            return loop.makeFailedFuture(MapLocalFileWorker.Busy())
        }
        return MapLocalFileWorker.pool.runIfActive(eventLoop: loop) { () -> PreparedMapLocalResponse? in
            guard let file = Self.localFile(target: rule.target, requestURL: url) else { return nil }
            let response = Self.mapLocalMetadata(rule, file: file)
            let sendBody = includeBody && ![204, 205, 304].contains(response.status)
            guard let opened = try MapLocalFile.open(file, includeBody: sendBody) else { return nil }
            return PreparedMapLocalResponse(body: opened.body, contentLength: opened.length,
                                            contentType: response.contentType, status: response.status,
                                            headers: response.headers)
        }.always { _ in MapLocalFileWorker.preparationSlots.signal() }
    }

    private static func mapLocalMetadata(_ rule: ProxyRule, file: URL)
        -> (contentType: String, status: Int, headers: HTTPHeaders) {
        let ext = file.pathExtension.lowercased()
        let type: String
        switch ext {
        case "html", "htm": type = "text/html"
        case "json": type = "application/json"
        case "xml": type = "application/xml"
        case "txt": type = "text/plain"
        case "css": type = "text/css"
        case "js": type = "application/javascript"
        case "png": type = "image/png"
        case "jpg", "jpeg": type = "image/jpeg"
        case "gif": type = "image/gif"
        case "pdf": type = "application/pdf"
        default: type = "application/octet-stream"
        }
        var headers = rule.responseHeaders ?? HTTPHeaders()
        for name in ["Content-Length", "Transfer-Encoding", "Connection", "Trailer"] { headers.remove(name: name) }
        let status = rule.responseStatus.flatMap { (200...599).contains($0) ? $0 : nil } ?? 200
        return (headers.value(of: "Content-Type") ?? type, status, headers)
    }

    private static func localFile(target: String, requestURL: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) else { return nil }
        let root = URL(fileURLWithPath: target).resolvingSymlinksInPath()
        if !isDirectory.boolValue { return root }
        guard let path = URLComponents(string: requestURL)?.percentEncodedPath else { return nil }
        var file = root
        for encoded in path.split(separator: "/") {
            guard let component = encoded.removingPercentEncoding, !component.contains("/"),
                  component != ".", component != "..", !component.contains("\0") else { return nil }
            file.appendPathComponent(component)
        }
        if path.hasSuffix("/") || path.isEmpty { file.appendPathComponent("index.html") }
        let resolved = file.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return resolved.path.hasPrefix(prefix) ? resolved : nil
    }

    /// Map Remote 命中 → 改写目标
    func mapRemoteTarget(for url: String) -> MapRemoteTarget? {
        guard let rule = firstEnabled(mapRemote, url: url), !rule.target.isEmpty else { return nil }
        guard let u = URLComponents(string: rule.target), let host = u.host,
              let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              u.user == nil, u.password == nil, u.fragment == nil else { return nil }
        let port = u.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        return MapRemoteTarget(scheme: scheme, host: URLParser.bareHost(host), port: port,
                               pathPrefix: u.percentEncodedPath, query: u.percentEncodedQuery)
    }

    func isBlocked(url: String) -> Bool {
        firstEnabled(blockList, url: url) != nil
    }

    func isAllowed(url: String) -> Bool {
        if !allowList.contains(where: \.enabled) { return true }
        return firstEnabled(allowList, url: url) != nil
    }

    var hasSSLApplicationRules: Bool { sslApplications.contains(where: \.enabled) }

    func shouldSSLProxy(host: String, application: String? = nil) -> Bool {
        if let application {
            let bundleID = SSLApplicationRule.normalize(application)
            if let rule = sslApplications.first(where: { $0.enabled && $0.id == bundleID }) {
                return rule.action == .decrypt
            }
        }
        if sslProxyingList.isEmpty { return true }
        return sslProxyingList.contains { rule in
            guard rule.enabled else { return false }
            let pattern = Self.sslHostPattern(rule.pattern)
            return pattern == "*" || ConnState.hostMatches(host: host, pattern: pattern)
        }
    }

    static func sslHostPattern(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URLComponents(string: value)?.host { return URLParser.bareHost(host).lowercased() }
        return URLParser.bareHost(value).lowercased()
    }
}

/// 规则存储：UI 编辑 + 引擎读取（线程安全快照），持久化到 AppSupport/rules.json
final class RulesStore: ObservableObject {
    static let shared = RulesStore()

    @Published var mapLocal: [ProxyRule] = [] { didSet { scheduleSave() } }
    @Published var mapRemote: [ProxyRule] = [] { didSet { scheduleSave() } }
    @Published var blockList: [ProxyRule] = [] { didSet { scheduleSave() } }
    @Published var allowList: [ProxyRule] = [] { didSet { scheduleSave() } }
    @Published var sslProxyingList: [ProxyRule] = [] { didSet { scheduleSave() } }
    @Published var sslApplications: [SSLApplicationRule] = [] { didSet { scheduleSave() } }
    @Published var customCertificates: [CustomCertificateRule] = [] {
        didSet {
            CustomCertificateStore.shared.invalidate()
            scheduleSave()
        }
    }
    @Published var noCaching = false { didSet { scheduleSave() } }

    private let lock = NSLock()
    private var snapshotCache: RulesSnapshot = RulesSnapshot()
    private var saveTimer: Timer?
    private var applyingBackup = false

    static var rulesPath: URL {
        CertificateAuthority.applicationSupport.appendingPathComponent("rules.json")
    }

    private init() {
        load()
        rebuildSnapshot()
        NSLog("[ProxyMirror][Rules] 载入: mapLocal=%d mapRemote=%d block=%d allow=%d ssl=%d noCaching=%@",
              mapLocal.count, mapRemote.count, blockList.count, allowList.count,
              sslProxyingList.count, noCaching ? "Y" : "N")
    }

    func snapshot() -> RulesSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotCache
    }

    func rebuildSnapshot() {
        let s = RulesSnapshot(
            mapLocal: mapLocal, mapRemote: mapRemote,
            blockList: blockList, allowList: allowList,
            sslProxyingList: sslProxyingList, sslApplications: sslApplications,
            customCertificates: customCertificates, noCaching: noCaching)
        lock.lock()
        snapshotCache = s
        lock.unlock()
    }

    private func scheduleSave() {
        guard !applyingBackup else { return }
        rebuildSnapshot()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.rulesPath),
              let dto = try? JSONDecoder().decode(RuleBackup.self, from: data) else { return }
        apply(dto)
    }

    private func apply(_ dto: RuleBackup) {
        applyingBackup = true
        mapLocal = dto.mapLocal ?? []
        mapRemote = dto.mapRemote ?? []
        blockList = dto.blockList ?? []
        allowList = dto.allowList ?? []
        sslProxyingList = dto.sslProxyingList ?? []
        sslApplications = dto.sslApplications ?? []
        customCertificates = dto.customCertificates ?? []
        noCaching = dto.noCaching ?? false
        applyingBackup = false
        rebuildSnapshot()
    }

    func save() {
        do { try persist(backup()) }
        catch { NSLog("[ProxyMirror][Rules] 保存失败: %@", error.localizedDescription) }
    }

    func backup() -> RuleBackup {
        RuleBackup(mapLocal: mapLocal, mapRemote: mapRemote, blockList: blockList,
                   allowList: allowList, sslProxyingList: sslProxyingList, sslApplications: sslApplications,
                   customCertificates: customCertificates,
                   noCaching: noCaching,
                   dns: InterceptionConfig.shared.dnsSpoof.value, breakpoints: InterceptionConfig.shared.breakpoints.value,
                   rewrite: InterceptionConfig.shared.rewrite.value,
                   latency: LatencyConditions.snapshot())
    }

    func install(_ backup: RuleBackup) throws {
        var rules = backup
        rules.settings = nil
        try persist(rules)
        saveTimer?.invalidate()
        apply(rules)
        if let dns = rules.dns { InterceptionConfig.shared.dnsSpoof.set(dns) }
        if let breakpoints = rules.breakpoints { InterceptionConfig.shared.breakpoints.set(breakpoints) }
        if let rewrite = rules.rewrite { InterceptionConfig.shared.rewrite.set(rewrite) }
        if let latency = rules.latency { LatencyConditions.updateSnapshot(latency) }
    }

    private func persist(_ dto: RuleBackup) throws {
        let url = Self.rulesPath
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(dto).write(to: url, options: .atomic)
    }
}
