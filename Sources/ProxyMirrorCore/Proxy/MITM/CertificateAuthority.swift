import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL
import Darwin
import Security

/// CA 证书管理：首次启动生成 CA（P-256），按域名动态签发叶子证书并缓存 NIOSSLContext。
/// CA 私钥与证书持久化在 AppSupport（自用工具，文件权限 600）。
final class CertificateAuthority: @unchecked Sendable {
    static let shared = CertificateAuthority()

    private let storageDirectory: URL?
    private let queue = DispatchQueue(label: "proxymirror.ca")
    private var caPrivateKey: Certificate.PrivateKey?
    private var caCertificate: X509.Certificate?
    private var caPEMText: String?
    private var caTLSCertificate: NIOSSLCertificate?
    private var cachedTrustProbe: TrustProbe?
    private var leafContexts: [String: NIOSSLContext] = [:]
    private var leafOrder: [String] = []
    private var leafGeneration: UInt64 = 0
    private let cacheLock = NSLock()
    private let maxCache = 512

    /// G7：按域名自定义服务端证书链（叶子在前），由 RulesStore/AppState 注入
    struct CustomChain: @unchecked Sendable {
        let certificates: [NIOSSLCertificate]
        let privateKey: NIOSSLPrivateKey
    }

    struct TrustProbe: Equatable, Sendable {
        let hostname: String
        let leafDER: Data
        let authorityDER: Data
        let notBefore: Date
        let expiresAt: Date
    }

    private let customProvider = LockedBox<(@Sendable (String) -> CustomChain?)?>(nil)

    func setCustomCertificateProvider(_ provider: (@Sendable (String) -> CustomChain?)?) {
        customProvider.set(provider)
        invalidateLeafContexts()
    }

    /// 不等待 CA 工作队列：provider 可能正在等待 RulesStore.shared 完成初始化。
    /// 代数也会使正在构建的旧证书上下文失效，避免清空后又被写回缓存。
    func invalidateLeafContexts() {
        cacheLock.lock()
        leafGeneration &+= 1
        leafContexts.removeAll()
        leafOrder.removeAll()
        cacheLock.unlock()
    }

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
    }

    static var applicationSupport: URL {
        if let path = ProcessInfo.processInfo.environment["PM_SUPPORT_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProxyMirror", isDirectory: true)
    }
    static var supportDir: URL { applicationSupport.appendingPathComponent("CA", isDirectory: true) }

    private var directory: URL { storageDirectory ?? Self.supportDir }
    var caCertPath: URL { directory.appendingPathComponent("ca-cert.pem") }
    var caKeyPath: URL { directory.appendingPathComponent("ca-key.pem") }

    /// 首次调用加载或生成 CA，后续调用复用已解析的证书。
    func ensureCA() throws {
        try queue.sync { try loadOrCreateCA() }
    }

    private func loadOrCreateCA() throws {
        if caCertificate != nil { return }
        if let certPEM = try? String(contentsOf: caCertPath, encoding: .utf8),
           let keyPEM = try? String(contentsOf: caKeyPath, encoding: .utf8),
           let key = try? Certificate.PrivateKey(pemEncoded: keyPEM),
           let cert = try? X509.Certificate(pemEncoded: certPEM),
           key.publicKey == cert.publicKey {
            let tls = try NIOSSLCertificate(bytes: Array(certPEM.utf8), format: .pem)
            storeCA(certificate: cert, key: key, pem: certPEM, tls: tls)
            return
        }
        try generateCA()
    }

    private func generateCA() throws {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let now = Date()
        let subject = try DistinguishedName {
            CommonName("ProxyMirror CA")
            OrganizationName("ProxyMirror")
            CountryName("CN")
        }
        let serialBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(bytes: serialBytes),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86_400),
            issuer: subject,
            subject: subject,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: key
        )
        try replaceCA(certificate: cert, key: key)
        NSLog("[ProxyMirror] CA 已生成: \(caCertPath.path)")
    }

    /// 导入外部根 CA：验证有效期、签发用途及公私钥匹配后，原子替换当前证书和私钥。
    /// 导入后客户端需重新信任新 CA（菜单重新安装即可）。
    func importRootCA(certificatePEM: String, privateKeyPEM: String) throws {
        try queue.sync {
            let cert = try X509.Certificate(pemEncoded: certificatePEM)
            guard let key = try? Certificate.PrivateKey(pemEncoded: privateKeyPEM) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "无法读取 PEM 私钥"])
            }
            try CertificateFormats.validateRootCA(cert, privateKey: key)
            try replaceCA(certificate: cert, key: key)
            NSLog("[ProxyMirror] 已导入自定义根 CA: \(cert.subject)")
        }
    }

    private func replaceCA(certificate: X509.Certificate, key: Certificate.PrivateKey) throws {
        let certPEM = try certificate.serializeAsPEM().pemString
        let keyPEM = try key.serializeAsPEM().pemString
        let tls = try NIOSSLCertificate(bytes: Array(certPEM.utf8), format: .pem)
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".ProxyMirror-CA-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staged) }

        let certificateName = caCertPath.lastPathComponent
        let privateKeyName = caKeyPath.lastPathComponent
        let hadAuthority = fm.fileExists(atPath: directory.path)
        if hadAuthority {
            for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where item.lastPathComponent != certificateName && item.lastPathComponent != privateKeyName {
                try fm.copyItem(at: item, to: staged.appendingPathComponent(item.lastPathComponent))
            }
        }
        let stagedKey = staged.appendingPathComponent(privateKeyName)
        try certPEM.write(to: staged.appendingPathComponent(certificateName), atomically: true, encoding: .utf8)
        try keyPEM.write(to: stagedKey, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedKey.path)

        // Switch the pair together so a failed import or interrupted process cannot leave mixed credentials.
        let flags = UInt32(hadAuthority ? RENAME_SWAP : RENAME_EXCL)
        let result = staged.withUnsafeFileSystemRepresentation { source in
            directory.withUnsafeFileSystemRepresentation { destination in
                renamex_np(source, destination, flags)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        storeCA(certificate: certificate, key: key, pem: certPEM, tls: tls)
    }

    private func storeCA(certificate: X509.Certificate, key: Certificate.PrivateKey, pem: String, tls: NIOSSLCertificate) {
        caPrivateKey = key
        caCertificate = certificate
        caPEMText = pem
        caTLSCertificate = tls
        cachedTrustProbe = nil
        invalidateLeafContexts()
    }

    func resetCA() throws {
        try queue.sync { try generateCA() }
    }

    /// 供安装命令使用的 CA PEM
    func caPEM() throws -> String {
        try queue.sync {
            try loadOrCreateCA()
            guard let caPEMText else { throw CocoaError(.fileReadCorruptFile) }
            return caPEMText
        }
    }

    /// CA 证书 DER
    func caDER() throws -> Data {
        try queue.sync {
            try loadOrCreateCA()
            guard let caTLSCertificate else { throw CocoaError(.fileReadCorruptFile) }
            return Data(try caTLSCertificate.toDERBytes())
        }
    }

    var caExpiry: Date? {
        queue.sync {
            try? loadOrCreateCA()
            return caCertificate?.notValidAfter
        }
    }

    var caNotBefore: Date? {
        queue.sync {
            try? loadOrCreateCA()
            return caCertificate?.notValidBefore
        }
    }

    var caCommonName: String? {
        guard let der = try? caDER(), let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    var caFingerprintSHA256: String? {
        guard let der = try? caDER() else { return nil }
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// An actual TLS server leaf is required for SSL trust evaluation: a CA is not
    /// itself a valid server leaf. Never consult custom host-certificate rules here.
    func makeTrustProbe(now: Date = Date()) throws -> TrustProbe {
        try queue.sync {
            try loadOrCreateCA()
            if let cachedTrustProbe, cachedTrustProbe.expiresAt > now.addingTimeInterval(60),
               cachedTrustProbe.notBefore <= now {
                return cachedTrustProbe
            }
            guard let caCertificate, let caPrivateKey, let caTLSCertificate else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let hostname = "trust-check.proxymirror.invalid"
            let key = P256.Signing.PrivateKey()
            let beginning = max(now.addingTimeInterval(-300), caCertificate.notValidBefore)
            let expiry = min(now.addingTimeInterval(3600), caCertificate.notValidAfter)
            guard beginning < expiry else { throw CocoaError(.fileReadCorruptFile) }
            let leaf = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(bytes: (0..<16).map { _ in UInt8.random(in: 0...255) }),
                publicKey: Certificate.PublicKey(key.publicKey),
                notValidBefore: beginning,
                notValidAfter: expiry,
                issuer: caCertificate.subject,
                subject: try DistinguishedName { CommonName(hostname) },
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true))
                    try ExtendedKeyUsage([.serverAuth])
                    try SubjectAlternativeNames([.dnsName(hostname)])
                },
                issuerPrivateKey: caPrivateKey
            )
            let probe = TrustProbe(hostname: hostname,
                                   leafDER: Data(try leaf.serializeAsPEM().derBytes),
                                   authorityDER: Data(try caTLSCertificate.toDERBytes()),
                                   notBefore: beginning, expiresAt: expiry)
            cachedTrustProbe = probe
            return probe
        }
    }

    // MARK: - 动态叶子证书（给 nio 的 TLS ServerContext）

    func leafContext(forHost host: String, enableHTTP2: Bool = false) -> NIOSSLContext? {
        let key = enableHTTP2 ? host + "|h2" : host
        if let cached = cachedLeaf(key) { return cached }
        return queue.sync { loadLeaf(key: key, host: host, enableHTTP2: enableHTTP2) }
    }

    func leafContext(forHost host: String, enableHTTP2: Bool, completion: @escaping @Sendable (NIOSSLContext?) -> Void) {
        let key = enableHTTP2 ? host + "|h2" : host
        if let cached = cachedLeaf(key) {
            completion(cached)
            return
        }
        queue.async { completion(self.loadLeaf(key: key, host: host, enableHTTP2: enableHTTP2)) }
    }

    private func cachedLeaf(_ key: String) -> NIOSSLContext? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return leafContexts[key]
    }

    private func loadLeaf(key: String, host: String, enableHTTP2: Bool) -> NIOSSLContext? {
        while true {
            cacheLock.lock()
            if let cached = leafContexts[key] {
                cacheLock.unlock()
                return cached
            }
            let generation = leafGeneration
            cacheLock.unlock()

            let result = buildLeafContext(forHost: host, enableHTTP2: enableHTTP2)
            cacheLock.lock()
            guard generation == leafGeneration else {
                cacheLock.unlock()
                continue
            }
            if let result {
                if leafOrder.count == maxCache { leafContexts.removeValue(forKey: leafOrder.removeFirst()) }
                leafOrder.append(key)
                leafContexts[key] = result
            }
            cacheLock.unlock()
            return result
        }
    }

    private func buildLeafContext(forHost host: String, enableHTTP2: Bool) -> NIOSSLContext? {
        do {
            try loadOrCreateCA()
            if let provider = customProvider.value, let custom = provider(host) {
                var customConfig = TLSConfiguration.makeServerConfiguration(
                    certificateChain: custom.certificates.map { .certificate($0) },
                    privateKey: .privateKey(custom.privateKey)
                )
                customConfig.minimumTLSVersion = .tlsv12
                customConfig.maximumTLSVersion = .tlsv13
                customConfig.applicationProtocols = enableHTTP2 ? ["h2", "http/1.1"] : ["http/1.1"]
                customConfig.keyLogCallback = TLSKeyLog.callback
                return try NIOSSLContext(configuration: customConfig)
            }
            guard let caCert = caCertificate, let caKey = caPrivateKey, let caTLSCertificate else { return nil }

            let key = P256.Signing.PrivateKey()
            let now = Date()
            let serialBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }

            let sans: [GeneralName]
            if URLParser.isIPAddress(host) {
                sans = [.ipAddress(ASN1OctetString(contentBytes: ipBytes(host)[...]))]
            } else {
                sans = [.dnsName(host)]
            }

            let leaf = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(bytes: serialBytes),
                publicKey: Certificate.PublicKey(key.publicKey),
                notValidBefore: now.addingTimeInterval(-86_400),
                notValidAfter: now.addingTimeInterval(398 * 86_400),   // Chrome 398 天上限
                issuer: caCert.subject,
                subject: try DistinguishedName { CommonName(host) },
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true))
                    try ExtendedKeyUsage([.serverAuth])
                    try SubjectAlternativeNames(sans)
                },
                issuerPrivateKey: caKey
            )

            let certificate = try NIOSSLCertificate(bytes: leaf.serializeAsPEM().derBytes, format: .der)
            let priv = try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)
            var config = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(certificate), .certificate(caTLSCertificate)],
                privateKey: .privateKey(priv)
            )
            config.minimumTLSVersion = .tlsv12
            config.applicationProtocols = enableHTTP2 ? ["h2", "http/1.1"] : ["http/1.1"]
            config.keyLogCallback = TLSKeyLog.callback
            config.maximumTLSVersion = .tlsv13
            return try NIOSSLContext(configuration: config)
        } catch {
            NSLog("[ProxyMirror] 生成叶子证书失败 \(host): \(error)")
            return nil
        }
    }

    private func ipBytes(_ host: String) -> [UInt8] {
        var v4 = in_addr()
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return [127, 0, 0, 1]
    }
}
