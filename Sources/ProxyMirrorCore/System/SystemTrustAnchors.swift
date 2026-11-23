import Foundation
import NIOCore
import Security
import NIOSSL

/// 从系统锚点加载根证书，供 NIOSSL 上游 TLS 验证使用
/// （swift-nio-ssl 的 `.default` 在 macOS 上无法读取 Keychain，需显式导入）
enum SystemTrustAnchors {
    static func load() -> [NIOSSLCertificate] {
        var anchorsRef: CFArray?
        guard SecTrustCopyAnchorCertificates(&anchorsRef) == errSecSuccess,
              let anchors = anchorsRef as? [SecCertificate] else {
            NSLog("[ProxyMirror] 无法读取系统锚点证书")
            return []
        }
        var out: [NIOSSLCertificate] = []
        out.reserveCapacity(anchors.count)
        for sec in anchors {
            let data = SecCertificateCopyData(sec) as Data
            if let cert = try? NIOSSLCertificate(bytes: [UInt8](data), format: .der) {
                out.append(cert)
            }
        }
        NSLog("[ProxyMirror] 已加载 %d 个系统根证书", out.count)
        return out
    }
}

enum UpstreamTrust {
    static var customRoots: URL { CertificateAuthority.applicationSupport.appendingPathComponent("UpstreamRoots.pem") }

    private static let preparation = DispatchQueue(label: "ProxyMirror.UpstreamTLS", qos: .userInitiated,
                                                   attributes: .concurrent)
    private static let system = SystemTrustAnchors.load()
    private static let defaultContext = Result { try build(extra: []) }
    private static let storedCustomCertificates = Result<[NIOSSLCertificate], Error> {
        guard FileManager.default.fileExists(atPath: customRoots.path) else { return [] }
        return try NIOSSLCertificate.fromPEMFile(customRoots.path)
    }
    private static let active = LockedBox<Result<NIOSSLContext, Error>>({
        do {
            let certs = try storedCustomCertificates.get()
            guard !certs.isEmpty else { return defaultContext }
            return .success(try build(extra: certs))
        } catch {
            NSLog("[ProxyMirror] 无法读取自定义上游 CA：%@", error.localizedDescription)
            return defaultContext
        }
    }())

    private static let http2 = LockedBox<NIOSSLContext?>(nil)
    private static let configurationLock = NSLock()
    private static var customCertificates: [NIOSSLCertificate]?
    private struct IdentityCacheKey: Hashable {
        let id: UUID
        let http2: Bool
    }
    private static var identityContexts: [IdentityCacheKey: NIOSSLContext] = [:]

    static func prewarm() {
        preparation.async {
            _ = ClientTLSIdentities.shared
            _ = try? context()
            _ = try? context(enableHTTP2: true)
        }
    }

    static func context(on loop: EventLoop, enableHTTP2: Bool = false, host: String? = nil)
        -> EventLoopFuture<NIOSSLContext> {
        let promise = loop.makePromise(of: NIOSSLContext.self)
        preparation.async {
            promise.completeWith(Result { try context(enableHTTP2: enableHTTP2, host: host) })
        }
        return promise.futureResult
    }

    private static func context(enableHTTP2: Bool = false, host: String? = nil) throws -> NIOSSLContext {
        let identity = host.flatMap { ClientTLSIdentities.shared.identity(for: $0) }
        guard enableHTTP2 || identity != nil else { return try active.value.get() }
        if identity == nil, let context = http2.value { return context }
        configurationLock.lock()
        defer { configurationLock.unlock() }
        if let identity {
            let now = Date()
            guard identity.validFrom <= now, identity.expiry > now else {
                throw ClientTLSIdentityError(OperationIssue.systemTrustAnchorsTheClientCertificateConfiguredForTheTargetHost)
            }
            let key = IdentityCacheKey(id: identity.id, http2: enableHTTP2)
            if let context = identityContexts[key] { return context }
            let context = try build(extra: extraCertificates(), enableHTTP2: enableHTTP2, identity: identity)
            if identityContexts.count >= 64 { identityContexts.removeAll() }
            identityContexts[key] = context
            return context
        }
        if let context = http2.value { return context }
        let context = try build(extra: extraCertificates(), enableHTTP2: true)
        http2.set(context)
        return context
    }

    static func clearClientIdentityContexts() {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        identityContexts.removeAll()
    }

    private static func extraCertificates() -> [NIOSSLCertificate] {
        customCertificates ?? ((try? storedCustomCertificates.get()) ?? [])
    }

    static func install(_ data: Data) throws {
        let roots = try NIOSSLCertificate.fromPEMBytes(Array(data))
        guard !roots.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let context = try build(extra: roots)
        let http2Context = try build(extra: roots, enableHTTP2: true)
        configurationLock.lock()
        defer { configurationLock.unlock() }
        let url = customRoots
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        active.set(.success(context))
        customCertificates = roots
        http2.set(http2Context)
        identityContexts.removeAll()
    }

    static func reset() throws {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        if FileManager.default.fileExists(atPath: customRoots.path) {
            try FileManager.default.removeItem(at: customRoots)
        }
        active.set(defaultContext)
        customCertificates = []
        http2.set(nil)
        identityContexts.removeAll()
    }

    private static func build(extra: [NIOSSLCertificate], enableHTTP2: Bool = false,
                              identity: ClientTLSIdentity? = nil) throws -> NIOSSLContext {
        var config = TLSConfiguration.makeClientConfiguration()
        config.minimumTLSVersion = .tlsv12
        config.certificateVerification = .fullVerification
        config.applicationProtocols = enableHTTP2 ? ["h2", "http/1.1"] : ["http/1.1"]
        config.keyLogCallback = TLSKeyLog.callback
        if let identity {
            config.certificateChain = identity.certificateChain.map { .certificate($0) }
            config.privateKey = .privateKey(identity.privateKey)
        }
        let anchors = system + extra
        if !anchors.isEmpty { config.trustRoots = .certificates(anchors) }
        return try NIOSSLContext(configuration: config)
    }
}
