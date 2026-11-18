import Foundation
import Crypto
import Security
import X509
@testable import ProxyMirrorCore

func checkCertInstaller(_ test: CoreAssertions) throws {
    enum FixtureError: Error { case launch, reset, query }

    let certificate = URL(fileURLWithPath: "/tmp/selected certificate's file.p12")
    var imported = false
    try CertInstaller.importCertificate(at: certificate) { executable, arguments in
        test.equal(executable, "/usr/bin/security", "证书导入使用 security")
        test.equal(arguments, ["import", certificate.path, "-k", CertInstaller.loginKeychainPath],
                   "所选文件是 import 输入，-k 显式指定登录钥匙串，路径不经过 shell")
        imported = true
        return .init(status: 0, output: "1 identity imported.")
    }
    test.expect(imported, "自定义证书执行导入")
    do {
        try CertInstaller.importCertificate(at: certificate) { _, _ in
            .init(status: 1, output: "invalid certificate")
        }
        test.expect(false, "导入退出失败必须报错")
    } catch {
        test.expect(error.localizedDescription.contains("invalid certificate"), "导入失败保留命令诊断")
    }
    test.rejects(try CertInstaller.importCertificate(at: certificate, run: { _, _ in throw FixtureError.launch }),
                 with: FixtureError.self, "导入进程启动失败传给调用者")

    // 使用真实 DER，不能用钥匙串 label 或名称子串来决定删除范围。
    func fixtureCertificate(commonName: String?) throws -> SecCertificate {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let subject = try DistinguishedName {
            OrganizationName("Certificate reset checks")
            if let commonName { CommonName(commonName) }
        }
        let certificate = try Certificate(
            version: .v3, serialNumber: .init(bytes: [1]), publicKey: key.publicKey,
            notValidBefore: Date().addingTimeInterval(-600), notValidAfter: Date().addingTimeInterval(86_400),
            issuer: subject, subject: subject,
            extensions: try Certificate.Extensions { Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil)) },
            issuerPrivateKey: key
        )
        let pem = try certificate.serializeAsPEM().pemString
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), let result = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
    let exact = try fixtureCertificate(commonName: "ProxyMirror CA")
    test.expect(try CertInstaller.resetFingerprint(exact) != nil, "精确 CN 的证书纳入重置")
    test.equal(try CertInstaller.resetFingerprint(fixtureCertificate(commonName: "ProxyMirror CA Lab")), nil,
               "重置保留 CN 相似的用户证书")
    test.equal(try CertInstaller.resetFingerprint(fixtureCertificate(commonName: nil)), nil,
               "没有 CN 的合法证书正常跳过")

    let matchingCertificates: CertInstaller.CertificateFinder = { _ in ["AAAA"] }
    for (status, message) in [(Int32(1), "User canceled. (-128)"), (Int32(23), "keychain deletion failed")] {
        var reset = false
        do {
            try CertInstaller.resetCertificates(run: { executable, arguments in
                test.equal(executable, "/usr/bin/osascript", "重置通过管理员授权命令删除钥匙串证书")
                test.equal(arguments.first, "-e", "管理员命令使用 AppleScript")
                return .init(status: status, output: message)
            }, findCertificates: matchingCertificates, resetCA: { reset = true })
            test.expect(false, "取消授权或删除失败不能报告重置成功")
        } catch {
            test.expect(error.localizedDescription.contains(message), "重置失败保留授权/钥匙串诊断")
        }
        test.expect(!reset, "取消授权或删除失败不会替换本地 CA")
    }
    var resetAfterLaunchFailure = false
    test.rejects(try CertInstaller.resetCertificates(run: { _, _ in throw FixtureError.launch },
                                                     findCertificates: matchingCertificates,
                                                     resetCA: { resetAfterLaunchFailure = true }),
                 with: FixtureError.self, "重置进程启动失败传给调用者")
    test.expect(!resetAfterLaunchFailure, "启动失败不会替换本地 CA")
    var events: [String] = []
    try CertInstaller.resetCertificates(run: { _, _ in
        events.append("delete")
        return .init(status: 0, output: "")
    }, findCertificates: { _ in events.append("find"); return ["AAAA"] }, resetCA: { events.append("reset") })
    test.equal(events, ["find", "find", "delete", "reset"], "查询及删除全部成功后才重置本地 CA")
    test.rejects(try CertInstaller.resetCertificates(run: { _, _ in .init(status: 0, output: "") },
                                                     findCertificates: matchingCertificates,
                                                     resetCA: { throw FixtureError.reset }),
                 with: FixtureError.self, "本地 CA 重置失败必须传回弹窗")

    for failedKeychain in [CertInstaller.loginKeychainPath, "/Library/Keychains/System.keychain"] {
        var deleted = false
        var reset = false
        test.rejects(try CertInstaller.resetCertificates(run: { _, _ in
            deleted = true
            return .init(status: 0, output: "")
        }, findCertificates: { path in
            if path == failedKeychain { throw FixtureError.query }
            return ["AAAA"]
        }, resetCA: { reset = true }), with: FixtureError.self, "钥匙串查询失败必须报错")
        test.expect(!deleted && !reset, "任一钥匙串查询失败不删除证书、不替换本地 CA")
    }
    var resetWithoutCertificates = false
    try CertInstaller.resetCertificates(run: { _, _ in
        test.expect(false, "无证书时不需要管理员删除")
        return .init(status: 0, output: "")
    }, findCertificates: { _ in [] }, resetCA: { resetWithoutCertificates = true })
    test.expect(resetWithoutCertificates, "没有匹配证书时仍可重置本地 CA")

    // 直接执行生产删除脚本，替身 security 证明多证书按指纹删除、失败不可继续。
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let security = directory.appendingPathComponent("security fixture's command")
    let mode = directory.appendingPathComponent("mode")
    let log = directory.appendingPathComponent("deletions")
    let login = directory.appendingPathComponent("user's login keychain-db").path
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    try """
        #!/bin/sh
        mode=$(/bin/cat \(quote(mode.path)))
        if [ "$1" = delete-certificate ] && [ "$2" = -t ] && [ "$3" = -Z ]; then
            printf '%s\\n' "$4" >> \(quote(log.path))
            if [ "$mode" = delete-failure ]; then echo 'deletion denied' >&2; exit 33; fi
        else
            exit 99
        fi
        """.write(to: security, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: security.path)

    for (scenario, expectedStatus, expectedDeletions) in [
        ("empty", Int32(0), ""),
        ("populated", Int32(0), "AAAA\nBBBB\nCCCC\n"),
        ("delete-failure", Int32(33), "AAAA\n"),
    ] {
        try scenario.write(to: mode, atomically: true, encoding: .utf8)
        try "".write(to: log, atomically: true, encoding: .utf8)
        let keychains = scenario == "empty" ? [] : [
            CertInstaller.KeychainCertificates(path: login, fingerprints: ["AAAA", "BBBB"]),
            CertInstaller.KeychainCertificates(path: "/Library/Keychains/System.keychain", fingerprints: ["CCCC"]),
        ]
        let script = CertInstaller.resetScript(keychains: keychains, securityPath: security.path)
        let result = try CertInstaller.runCommand("/bin/sh", ["-c", script])
        test.equal(result.status, expectedStatus, "重置脚本退出状态：\(scenario)")
        test.equal(try String(contentsOf: log, encoding: .utf8), expectedDeletions,
                   "重置脚本按指纹删除并在失败时停止：\(scenario)")
    }
    test.rejects(try CertInstaller.runCommand(directory.appendingPathComponent("missing-command").path, []),
                 with: CocoaError.self, "实际进程启动失败以 Swift 错误返回")
}
