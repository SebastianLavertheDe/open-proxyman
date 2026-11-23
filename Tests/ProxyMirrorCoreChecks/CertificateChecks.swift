import Foundation
import Crypto
import X509
import NIOSSL
@testable import ProxyMirrorCore

/// G7：自定义根 CA 导入 + 按域名自定义服务端证书链
@MainActor
func checkCertificates(_ test: CoreAssertions) throws {
    try checkCertificateFormats(test)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pm-cert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let authority = CertificateAuthority(storageDirectory: dir)
    try authority.ensureCA()
    let originalPEM = try authority.caPEM()

    // 构造第二把自签 CA
    let key = P256.Signing.PrivateKey()
    let subject = try DistinguishedName {
        CommonName("Imported CA")
        OrganizationName("G7Check")
    }
    let secondCert = try Certificate(
        version: .v3,
        serialNumber: Certificate.SerialNumber(bytes: (0..<16).map { _ in UInt8.random(in: 0...255) }),
        publicKey: Certificate.PublicKey(key.publicKey),
        notValidBefore: Date().addingTimeInterval(-3600),
        notValidAfter: Date().addingTimeInterval(365 * 86_400),
        issuer: subject, subject: subject,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
        },
        issuerPrivateKey: Certificate.PrivateKey(key)
    )
    let secondPEM = try secondCert.serializeAsPEM().pemString

    // 1) 私钥不匹配 → 报错且 CA 不变
    do {
        try authority.importRootCA(certificatePEM: secondPEM,
                                   privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
        test.expect(false, "钥匙不匹配应报错")
    } catch {
        test.expect(true, "钥匙不匹配报错")
    }
    test.equal((try? authority.caPEM()) ?? "", originalPEM, "失败导入不改变现有 CA")

    // 2) 正常导入替换 CA
    try authority.importRootCA(certificatePEM: secondPEM, privateKeyPEM: key.pemRepresentation)
    test.equal((try? authority.caPEM()) ?? "", secondPEM, "导入后 CA 替换为外部证书")
    test.expect(authority.leafContext(forHost: "imported.test") != nil, "导入 CA 后叶子上下文可用")

    // 3) 非 CA 证书导入报错：签一个叶子
    let leafKey = P256.Signing.PrivateKey()
    let leafCert = try Certificate(
        version: .v3,
        serialNumber: Certificate.SerialNumber(bytes: (0..<16).map { _ in UInt8.random(in: 0...255) }),
        publicKey: Certificate.PublicKey(leafKey.publicKey),
        notValidBefore: Date().addingTimeInterval(-600),
        notValidAfter: Date().addingTimeInterval(398 * 86_400),
        issuer: secondCert.subject,
        subject: try DistinguishedName { CommonName("leaf.test") },
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([.dnsName("leaf.test")])
        },
        issuerPrivateKey: Certificate.PrivateKey(key)
    )
    let leafPEM = try leafCert.serializeAsPEM().pemString
    do {
        try authority.importRootCA(certificatePEM: leafPEM,
                                   privateKeyPEM: leafKey.pemRepresentation)
        test.expect(false, "非 CA 证书应报错")
    } catch {
        test.expect(true, "非 CA 证书导入报错")
    }

    // 4) 域名规则匹配
    let wildcard = CustomCertificateRule(hostPattern: "*.example.com")
    test.expect(wildcard.matches(host: "api.example.com"), "通配命中子域")
    test.expect(!wildcard.matches(host: "example.com"), "通配 *. 不匹配裸域")
    test.expect(!CustomCertificateRule(enabled: false, hostPattern: "*").matches(host: "x.test"),
                "禁用规则不命中")

    // 5) 自定义链 provider：命中走导入链，未命中走动态签发
    let chainPath = dir.appendingPathComponent("chain.pem")
    let keyPath = dir.appendingPathComponent("leaf-key.pem")
    try Data((leafPEM + "\n" + secondPEM).utf8).write(to: chainPath)
    try Data(leafKey.pemRepresentation.utf8).write(to: keyPath)
    let chainRule = CustomCertificateRule(hostPattern: "override.test",
                                          certificatePath: chainPath.path, privateKeyPath: keyPath.path)
    authority.setCustomCertificateProvider { host in
        guard chainRule.matches(host: host) else { return nil }
        return CustomCertificateStore.load(rule: chainRule)
    }
    test.expect(authority.leafContext(forHost: "override.test") != nil, "命中域名返回自定义链上下文")
    test.expect(authority.leafContext(forHost: "other.test") != nil, "未命中域名走动态签发")

    // PEM 链拆分
    test.equal(CustomCertificateStore.splitCertificates(leafPEM + "\n" + secondPEM).count, 2,
               "拆分 PEM 证书链")
    authority.setCustomCertificateProvider(nil)

    try checkCertificateRuleUpdates(test, directory: dir.appendingPathComponent("rule-updates"),
                                    certificatePEM: leafPEM, privateKeyPEM: leafKey.pemRepresentation)

    let alternateKeys = [
        Certificate.PrivateKey(P384.Signing.PrivateKey()),
        Certificate.PrivateKey(P521.Signing.PrivateKey()),
        Certificate.PrivateKey(Curve25519.Signing.PrivateKey()),
    ]
    for (index, alternate) in alternateKeys.enumerated() {
        let cert = try Certificate(
            version: .v3, serialNumber: .init(bytes: [UInt8(index + 1)]), publicKey: alternate.publicKey,
            notValidBefore: Date().addingTimeInterval(-3600), notValidAfter: Date().addingTimeInterval(86_400),
            issuer: subject, subject: subject,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: alternate
        )
        let certPEM = try cert.serializeAsPEM().pemString
        let keyPEM = try alternate.serializeAsPEM().pemString
        try authority.importRootCA(certificatePEM: certPEM, privateKeyPEM: keyPEM)
        let reloaded = CertificateAuthority(storageDirectory: dir)
        test.equal(try reloaded.caPEM(), certPEM, "重新打开保留根 CA（\(cert.signatureAlgorithm)）")
        test.expect(reloaded.leafContext(forHost: "reloaded.test") != nil,
                    "使用导入根私钥签发叶子（\(cert.signatureAlgorithm)）")
        let attrs = try FileManager.default.attributesOfItem(atPath: reloaded.caKeyPath.path)
        test.equal(attrs[.posixPermissions] as? Int, 0o600, "导入根私钥文件权限")
    }
    test.expect(FileManager.default.fileExists(atPath: chainPath.path), "切换根 CA 时保留其他文件")
    let previous = try authority.caPEM()
    try authority.resetCA()
    let reset = CertificateAuthority(storageDirectory: dir)
    let resetPEM = try reset.caPEM()
    test.expect(resetPEM != previous && reset.leafContext(forHost: "reset.test") != nil,
                "重置生成新证书及可用密钥，并可重新打开")
}

@MainActor
private func checkCertificateRuleUpdates(_ test: CoreAssertions, directory: URL,
                                         certificatePEM: String, privateKeyPEM: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let authority = CertificateAuthority(storageDirectory: directory.appendingPathComponent("CA"))
    try authority.ensureCA()
    let certificates = CustomCertificateStore()
    let rulesPath = directory.appendingPathComponent("rules.json")
    let rules = RulesStore(storageURL: rulesPath, certificateStore: certificates, certificateAuthority: authority)
    let certificatePath = directory.appendingPathComponent("server.pem")
    let keyPath = directory.appendingPathComponent("server-key.pem")
    try certificatePEM.write(to: certificatePath, atomically: true, encoding: .utf8)
    try privateKeyPEM.write(to: keyPath, atomically: true, encoding: .utf8)
    let rule = CustomCertificateRule(hostPattern: "override.test", certificatePath: certificatePath.path,
                                     privateKeyPath: keyPath.path)
    let selected = LockedBox<[Data?]>([])
    authority.setCustomCertificateProvider { host in
        let chain = certificates.chain(forHost: host, rules: rules)
        selected.set(selected.value + [chain.flatMap { try? Data($0.certificates[0].toDERBytes()) }])
        return chain
    }
    defer { authority.setCustomCertificateProvider(nil) }

    typealias Contexts = (http1: NIOSSLContext?, http2: NIOSSLContext?)
    func contexts() -> Contexts {
        (authority.leafContext(forHost: "override.test"),
         authority.leafContext(forHost: "override.test", enableHTTP2: true))
    }
    func expectReload(_ previous: Contexts, certificate: Data?, _ message: String) -> Contexts {
        let calls = selected.value.count
        let next = contexts()
        test.expect(next.http1 != nil && next.http2 != nil && next.http1 !== previous.http1
                    && next.http2 !== previous.http2, "\(message)：HTTP/1 和 HTTP/2 均替换上下文")
        test.equal(selected.value.count, calls + 2, "\(message)：两种 ALPN 均重新查询 provider")
        test.equal(Array(selected.value.suffix(2)), [certificate, certificate],
                   "\(message)：provider 读取当前规则对应的证书 DER")
        let warm = contexts()
        test.expect(next.http1 === warm.http1 && next.http2 === warm.http2,
                    "\(message)：新上下文正常缓存")
        return next
    }

    var current = contexts()
    let firstDER = try Data(NIOSSLCertificate(bytes: Array(certificatePEM.utf8), format: .pem).toDERBytes())
    rules.customCertificates = [rule]
    current = expectReload(current, certificate: firstDER, "添加域名证书")

    // 路径保持不变但 PEM 内容变化，重新应用同一规则也必须清掉解析缓存。
    let replacementKey = P256.Signing.PrivateKey()
    let subject = try DistinguishedName { CommonName("override.test") }
    let replacement = try Certificate(
        version: .v3, serialNumber: .init(bytes: [2]), publicKey: Certificate.PublicKey(replacementKey.publicKey),
        notValidBefore: Date().addingTimeInterval(-600), notValidAfter: Date().addingTimeInterval(86_400),
        issuer: subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([.dnsName("override.test")])
        }, issuerPrivateKey: Certificate.PrivateKey(replacementKey))
    let replacementPEM = try replacement.serializeAsPEM().pemString
    let replacementDER = try Data(NIOSSLCertificate(bytes: Array(replacementPEM.utf8), format: .pem).toDERBytes())
    try replacementPEM.write(to: certificatePath, atomically: true, encoding: .utf8)
    try replacementKey.pemRepresentation.write(to: keyPath, atomically: true, encoding: .utf8)
    rules.customCertificates = [rule]
    current = expectReload(current, certificate: replacementDER, "修改同路径证书")
    rules.customCertificates[0].enabled = false
    current = expectReload(current, certificate: nil, "禁用后恢复动态签发")
    rules.customCertificates[0].enabled = true
    current = expectReload(current, certificate: replacementDER, "重新启用证书")
    rules.customCertificates.removeAll()
    current = expectReload(current, certificate: nil, "删除后恢复动态签发")
    try rules.install(RuleBackup(customCertificates: [rule]))
    current = expectReload(current, certificate: replacementDER, "导入备份证书规则")
    try rules.install(RuleBackup(customCertificates: []))
    _ = expectReload(current, certificate: nil, "导入备份删除证书规则")
    test.expect(FileManager.default.fileExists(atPath: rulesPath.path), "规则备份仅写临时测试目录")

    // 在 provider 已读到旧规则、尚未完成构建时禁用规则，旧结果不能再填回缓存。
    for http2 in [false, true] {
        rules.customCertificates = [rule]
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let calls = LockedBox(0)
        let lastSelection = LockedBox<Data?>(nil)
        let completed = LockedBox<NIOSSLContext?>(nil)
        authority.setCustomCertificateProvider { host in
            let chain = certificates.chain(forHost: host, rules: rules)
            calls.set(calls.value + 1)
            lastSelection.set(chain.flatMap { try? Data($0.certificates[0].toDERBytes()) })
            if calls.value == 1 {
                started.signal()
                _ = finish.wait(timeout: .now() + .seconds(5))
            }
            return chain
        }
        authority.leafContext(forHost: "override.test", enableHTTP2: http2) { context in
            completed.set(context)
            delivered.signal()
        }
        let inFlight = started.wait(timeout: .now() + .seconds(5)) == .success
        rules.customCertificates[0].enabled = false
        finish.signal()
        let finished = delivered.wait(timeout: .now() + .seconds(5)) == .success
        test.expect(inFlight && finished && calls.value == 2 && lastSelection.value == nil,
                    "并发失效丢弃旧构建并重新读取禁用规则（HTTP/2=\(http2)）")
        let cached = authority.leafContext(forHost: "override.test", enableHTTP2: http2)
        test.expect(completed.value != nil && cached === completed.value && calls.value == 2,
                    "并发失效后只缓存重新动态签发的上下文（HTTP/2=\(http2)）")
    }
}
