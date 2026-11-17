import Foundation
import Crypto
import X509
@testable import ProxyMirrorCore

/// G7：自定义根 CA 导入 + 按域名自定义服务端证书链
@MainActor
func checkCertificates(_ test: CoreAssertions) throws {
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
