import AppKit
import Foundation
import Crypto
import ProxyMirrorSystemProxy
import Security
import UniformTypeIdentifiers
import X509

final class SystemProxyController {
    static let shared = SystemProxyController()
    private let queue = DispatchQueue(label: "ProxyMirror.SystemProxy")
    private var session: (id: UUID, connection: NSXPCConnection)?

    private init() {}

    var hasInstalledService: Bool { FileManager.default.fileExists(atPath: SystemProxyService.plist.path) }

    struct ServiceStatus: Sendable {
        let installed: Bool
        let healthy: Bool
        let identifier: String
        let version: String
        let statusText: String
    }

    /// Read-only diagnostics; this never installs a service or requests administrator rights.
    func serviceStatus() -> ServiceStatus {
        let identifier = SystemProxyService.name
        guard hasInstalledService else {
            return ServiceStatus(installed: false, healthy: false, identifier: identifier,
                                 version: Strings.Errors.systemProxyNotInstalled, statusText: Strings.Errors.systemProxyTheSystemProxyHelperIsNotInstalled)
        }
        do {
            _ = try SystemProxyService.codeHash(at: SystemProxyService.executable, identifier: identifier)
            let versionResult = try CertInstaller.runCommand(SystemProxyService.executable.path, ["--version"])
            let version = versionResult.status == 0 ? versionResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : Strings.Errors.systemProxyLegacyVersionNoVersionInformation
            let loaded = try CertInstaller.runCommand("/bin/launchctl", ["print", "system/\(identifier)"])
            let appHash = try SystemProxyService.codeHash(at: Bundle.main.bundleURL, identifier: SystemProxyService.appIdentifier)
            let compatible = SystemProxyService.installedArguments() == SystemProxyService.daemonArguments(uid: geteuid(), appHash: appHash)
                && version == SystemProxyService.version
            let healthy = loaded.status == 0 && compatible
            let text = !compatible ? Strings.Errors.systemProxyInstalledAuthorizationIsRequiredForThisApplicationVersion
                : healthy ? Strings.Errors.systemProxyInstalledLaunchdServiceLoadedAndCodeSignatureVerified : Strings.Errors.systemProxyInstalledButTheLaunchdServiceIsNotLoaded
            return ServiceStatus(installed: true, healthy: healthy, identifier: identifier,
                                 version: version.isEmpty ? Strings.Errors.systemProxyUnknown : version,
                                 statusText: text)
        } catch {
            return ServiceStatus(installed: true, healthy: false, identifier: identifier,
                                 version: Strings.Errors.systemProxyUnknown, statusText: Strings.Errors.systemProxyProxyHelperCheckFailed(LocalizedErrorPresentation.message(for: error)))
        }
    }

    func enable(port: UInt16, onDisconnect: @escaping () -> Void, completion: @escaping (Bool, String) -> Void) {
        run(completion: completion) {
            guard self.session == nil else { throw SystemProxyOperationError(OperationIssue.systemProxyTheSystemProxyIsEnabledRestoreTheOriginal) }
            let helper = try Self.bundledHelper()
            let appHash = try SystemProxyService.codeHash(at: Bundle.main.bundleURL,
                                                         identifier: SystemProxyService.appIdentifier)
            let helperHash = try SystemProxyService.codeHash(at: helper, identifier: SystemProxyService.name)
            let uid = geteuid()
            let installedHash = try? SystemProxyService.codeHash(at: SystemProxyService.executable,
                                                                 identifier: SystemProxyService.name)
            if installedHash != helperHash ||
                SystemProxyService.installedArguments() != SystemProxyService.daemonArguments(uid: uid, appHash: appHash) {
                try SystemProxyAuthorization.run(.install(uid: uid, appHash: appHash), helper: helper, hash: helperHash)
            }

            let connection = NSXPCConnection(machServiceName: SystemProxyService.name, options: .privileged)
            connection.remoteObjectInterface = SystemProxyService.interface()
            connection.setCodeSigningRequirement(
                SystemProxyService.requirement(identifier: SystemProxyService.name, hash: helperHash))
            let id = UUID()
            connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
            connection.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard self.session?.id == id else { return }
                    self.session = nil
                    DispatchQueue.main.async(execute: onDisconnect)
                }
            }
            connection.resume()
            do {
                if let hosts = SystemProxyBypass.savedHosts {
                    try Self.request(on: connection) { $0.enableWithBypass(Int(port), hosts: hosts, reply: $1) }
                } else {
                    try Self.request(on: connection) { $0.enable(Int(port), reply: $1) }
                }
                self.session = (id, connection)
            } catch {
                connection.invalidate()
                throw error
            }
        }
    }

    func disable(restorePrevious: Bool = true, completion: @escaping (Bool, String) -> Void) {
        run(completion: completion) {
            guard let connection = self.session?.connection else { return }
            try Self.request(on: connection) { service, reply in
                if restorePrevious { service.restore(reply: reply) }
                else { service.disableOwned(reply: reply) }
            }
            self.session = nil
            connection.invalidate()
        }
    }

    func updateBypass(_ hosts: [String]?, completion: @escaping (Bool, String) -> Void) {
        run(completion: completion) {
            guard let connection = self.session?.connection else { throw SystemProxyOperationError(OperationIssue.systemProxyEnableTheSystemProxyFirst) }
            if let hosts, let issue = SystemProxyBypassList.validationFailure(hosts) { throw issue }
            try Self.request(on: connection) { $0.updateBypass(hosts, reply: $1) }
        }
    }

    func uninstall(completion: @escaping (Bool, String) -> Void) {
        run(completion: completion) {
            guard self.session == nil else { throw SystemProxyOperationError(OperationIssue.systemProxyRestoreTheSystemProxyBeforeRemovingItsAuthorization) }
            let helper = try Self.bundledHelper()
            let hash = try SystemProxyService.codeHash(at: helper, identifier: SystemProxyService.name)
            try SystemProxyAuthorization.run(.uninstall, helper: helper, hash: hash)
        }
    }

    private func run(completion: @escaping (Bool, String) -> Void, operation: @escaping () throws -> Void) {
        queue.async {
            let result: (Bool, String)
            do { try operation(); result = (true, "") }
            catch { result = (false, LocalizedErrorPresentation.message(for: error)) }
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
    }

    private static func request(on connection: NSXPCConnection,
                                send: (SystemProxyServiceProtocol, @escaping (String?) -> Void) -> Void) throws {
        let reply = Reply()
        let object = connection.remoteObjectProxyWithErrorHandler { _ in
            reply.finish(SystemProxyError(.loadFailed).wireValue)
        }
        guard let service = object as? SystemProxyServiceProtocol else {
            throw SystemProxyOperationError(OperationIssue.systemProxyTheSystemProxyServiceInterfaceIsUnavailable)
        }
        send(service, reply.finish)
        try reply.wait()
    }

    private final class Reply {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var finished = false
        private var message: String?

        func finish(_ message: String?) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            self.message = message
            semaphore.signal()
        }

        func wait() throws {
            guard semaphore.wait(timeout: .now() + .seconds(8)) == .success else {
                throw SystemProxyOperationError(OperationIssue.systemProxyTheSystemProxyServiceDidNotRespondTry)
            }
            lock.lock()
            defer { lock.unlock() }
            if let message { throw SystemProxyError.fromWire(message) }
        }
    }

    private static func bundledHelper() throws -> URL {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            throw SystemProxyOperationError(OperationIssue.systemProxyTheSystemProxyServiceIsMissingUseA)
        }
        let helper = directory.appendingPathComponent(SystemProxyService.helperName)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw SystemProxyOperationError(OperationIssue.systemProxyTheSystemProxyServiceIsMissingUseA)
        }
        return helper
    }
}

/// CA 证书安装
enum CertInstaller {
    struct CommandResult {
        let status: Int32
        let output: String

        func requireSuccess() throws {
            guard status == 0 else {
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SystemProxyOperationError(detail.isEmpty ? OperationIssue.systemProxyTheCertificateCommandFailedExitCode(Int(status)) : .technical(detail))
            }
        }
    }

    typealias CommandRunner = (String, [String]) throws -> CommandResult
    typealias CertificateFinder = (String) throws -> [String]

    struct KeychainCertificates {
        let path: String
        let fingerprints: [String]
    }

    static var loginKeychainPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
    }

    /// 先读取合并输出再等待退出，避免管道写满时阻塞；启动失败由 run() 抛出。
    static func runCommand(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }


    /// G7：导入外部根 CA（先选证书 PEM，再选私钥 PEM）
    static func importRootCA() {
        let certPanel = NSOpenPanel()
        certPanel.message = Strings.Errors.systemProxySelectTheRootCaCertificatePem
        certPanel.allowedContentTypes = [UTType.data]
        certPanel.canChooseFiles = true
        guard certPanel.runModal() == .OK, let certURL = certPanel.url else { return }
        let keyPanel = NSOpenPanel()
        keyPanel.message = Strings.Errors.systemProxySelectTheMatchingPrivateKeyPemP256
        keyPanel.allowedContentTypes = [UTType.data]
        keyPanel.canChooseFiles = true
        guard keyPanel.runModal() == .OK, let keyURL = keyPanel.url else { return }
        let certPath = certURL.path
        let keyPath = keyURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let certPEM = try String(contentsOfFile: certPath, encoding: .utf8)
                let keyPEM = try String(contentsOfFile: keyPath, encoding: .utf8)
                try CertificateAuthority.shared.importRootCA(certificatePEM: certPEM, privateKeyPEM: keyPEM)
                DispatchQueue.main.async {
                    AppState.shared.caInstalled = false
                    AppState.shared.caBannerDismissed = false
                    UserDefaults.standard.set(false, forKey: "caBannerDismissed")
                    NotificationCenter.default.post(name: .proxyMirrorCertificatesChanged, object: nil)
                    AppState.shared.systemProxyMessage =
                        Strings.Errors.systemProxyTheCustomRootCaWasImportedReinstallAnd
                }
            } catch {
                DispatchQueue.main.async {
                    AppState.shared.systemProxyMessage = Strings.Errors.systemProxyUnableToImportTheRootCa(LocalizedErrorPresentation.message(for: error))
                }
            }
        }
    }

    struct CertificateStatus: Sendable {
        let installed: Bool
        let trusted: Bool
        let commonName: String
        let notBefore: Date?
        let notAfter: Date?
        let statusText: String
    }

    /// Compare the current authority's DER fingerprint, then evaluate SSL trust using macOS.
    /// A same-name certificate or a certificate merely imported without trust is insufficient.
    static func certificateStatus(authority: CertificateAuthority = .shared,
                                  installedCertificates: () throws -> [Data] = installedCertificateData,
                                  evaluateTrust: ((Data) -> Bool)? = nil,
                                  now: Date = Date()) -> CertificateStatus {
        var name = "CA"
        var before: Date?
        var after: Date?
        var installed = false
        do {
            let der = try authority.caDER()
            let certificate = try X509.Certificate(derEncoded: Array(der))
            before = certificate.notValidBefore
            after = certificate.notValidAfter
            if let reference = SecCertificateCreateWithData(nil, der as CFData) {
                var commonName: CFString?
                if SecCertificateCopyCommonName(reference, &commonName) == errSecSuccess {
                    name = commonName as String? ?? "CA"
                }
            }
            let fingerprint = SHA256.hash(data: der)
            installed = try installedCertificates().contains { SHA256.hash(data: $0) == fingerprint }
            let valid = certificate.notValidBefore <= now && now < certificate.notValidAfter
            let trusted: Bool
            if installed && valid {
                if let evaluateTrust { trusted = evaluateTrust(der) }
                else {
                    let probe = try authority.makeTrustProbe(now: now)
                    // A concurrent root replacement must not mix status from two authorities.
                    trusted = probe.authorityDER == der && certificateIsTrusted(probe)
                }
            } else { trusted = false }
            return CertificateStatus(installed: installed, trusted: trusted, commonName: name,
                                     notBefore: before, notAfter: after,
                                     statusText: trusted ? Strings.Errors.systemProxyTheCurrentCaIsInstalledAndTrustedFor : installed ? Strings.Errors.systemProxyTheCurrentCaIsInstalledButIsNot : Strings.Errors.systemProxyTheCurrentCaIsNotInstalled)
        } catch {
            return CertificateStatus(installed: installed, trusted: false, commonName: name,
                                     notBefore: before, notAfter: after,
                                     statusText: Strings.Errors.systemProxyUnableToCheckTheCurrentCa(LocalizedErrorPresentation.message(for: error)))
        }
    }

    static func isInstalled() -> Bool { certificateStatus().installed }

    private static func installedCertificateData() throws -> [Data] {
        func query(_ keychain: SecKeychain? = nil) throws -> [Data] {
            var query: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
            if let keychain { query[kSecMatchSearchList] = [keychain] }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return [] }
            try requireSecuritySuccess(status)
            guard let certificates = result as? [SecCertificate] else { throw SystemProxyOperationError(OperationIssue.systemProxyUnableToReadTheInstalledCertificateList) }
            return certificates.map { SecCertificateCopyData($0) as Data }
        }
        var certificates = try query()
        var system: SecKeychain?
        if SecKeychainOpen("/Library/Keychains/System.keychain", &system) == errSecSuccess, let system {
            certificates.append(contentsOf: try query(system))
        }
        return certificates
    }

    private static func certificateIsTrusted(_ probe: CertificateAuthority.TrustProbe) -> Bool {
        guard let leaf = SecCertificateCreateWithData(nil, probe.leafDER as CFData),
              let authority = SecCertificateCreateWithData(nil, probe.authorityDER as CFData) else { return false }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, probe.hostname as CFString)
        guard SecTrustCreateWithCertificates([leaf, authority] as CFArray, policy, &trust) == errSecSuccess,
              let trust else { return false }
        // Do not add the CA as an explicit anchor: only the user's actual macOS
        // SSL trust settings may authorize this otherwise self-signed chain.
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// 系统级信任安装（-d 写入系统信任存储；一次管理员授权；Chrome/所有应用直接生效）
    static func installSystemWide(completion: @escaping (Bool, String) -> Void) {
        do {
            let pem = try CertificateAuthority.shared.caPEM()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirrorCA.pem")
            try pem.write(to: tmp, atomically: true, encoding: .utf8)
            let script = "security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain \"\(tmp.path)\""
            DispatchQueue.global().async {
                let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let p = Process()
                p.launchPath = "/usr/bin/osascript"
                p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
                let errPipe = Pipe()
                p.standardError = errPipe
                p.launch()
                p.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    completion(p.terminationStatus == 0, errText)
                }
            }
        } catch {
            completion(false, "\(error)")
        }
    }

    /// 把 CA 加入登录钥匙串并设置用户级 SSL 信任（系统会弹一次确认框）
    static func installCAToLoginKeychain() -> Bool {
        do {
            let pem = try CertificateAuthority.shared.caPEM()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirrorCA.pem")
            try pem.write(to: tmp, atomically: true, encoding: .utf8)

            let p = Process()
            p.launchPath = "/usr/bin/security"
            p.arguments = ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k",
                           FileManager.default.homeDirectoryForCurrentUser
                               .appendingPathComponent("Library/Keychains/login.keychain-db").path,
                           tmp.path]
            p.launch()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            NSLog("[ProxyMirror] 安装证书失败: \(error)")
            return false
        }
    }

    /// 导出 CA 证书到用户选择的位置（pem/cer）
    static func exportCA(extension ext: String) {
        do {
            let pem = try CertificateAuthority.shared.caPEM()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "proxymirror-ca.\(ext)"
            panel.allowedContentTypes = ext == "pem" ? [.plainText] : [.data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let pem2 = try CertificateAuthority.shared.caPEM()
            if ext == "pem" {
                try pem2.write(to: url, atomically: true, encoding: .utf8)
            } else {
                let der = try CertificateAuthority.shared.caDER()
                try der.write(to: url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("[ProxyMirror] 导出证书失败: \(error)")
        }
    }

    /// 导入自定义证书到登录钥匙串（对齐 Proxyman 添加自定义证书）
    @MainActor
    static func importCustomCertificate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data,
                                     UTType(filenameExtension: "cer") ?? .data,
                                     UTType(filenameExtension: "p12") ?? .data]
        panel.message = Strings.Errors.systemProxySelectTheCertificateToImportPemCerOr
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppState.shared.systemProxyMessage = Strings.Errors.systemProxyImportingTheCustomCertificate
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                try importCertificate(at: url)
                message = Strings.Errors.systemProxyImportedIntoTheLoginKeychain(String(url.lastPathComponent))
            } catch {
                message = Strings.Errors.systemProxyUnableToImportTheCustomCertificate(LocalizedErrorPresentation.message(for: error))
            }
            DispatchQueue.main.async { AppState.shared.systemProxyMessage = message }
        }
    }

    static func importCertificate(at url: URL, run: CommandRunner = runCommand) throws {
        try run("/usr/bin/security", ["import", url.path, "-k", loginKeychainPath]).requireSuccess()
    }

    /// 重置：删除钥匙串中的 ProxyMirror CA + 删除本地 CA 文件，并重新生成
    static func resetAll(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try resetCertificates() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func resetCertificates(run: CommandRunner = runCommand,
                                  findCertificates: CertificateFinder = certificateFingerprints,
                                  resetCA: () throws -> Void = { try CertificateAuthority.shared.resetCA() }) throws {
        // 先完成全部查询，避免第二个钥匙串查询失败时已删除第一个钥匙串的证书。
        let keychains = try [loginKeychainPath, "/Library/Keychains/System.keychain"].map {
            KeychainCertificates(path: $0, fingerprints: try findCertificates($0))
        }
        if keychains.contains(where: { !$0.fingerprints.isEmpty }) {
            let escaped = resetScript(keychains: keychains)
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            try run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
                .requireSuccess()
        }
        try resetCA()
    }

    /// Security 的 -c 文本查找会匹配 CN 子串；直接读取 CN 后精确比较，保留相似名称的其他证书。
    static func certificateFingerprints(in path: String) throws -> [String] {
        var keychain: SecKeychain?
        try requireSecuritySuccess(SecKeychainOpen(path, &keychain))
        guard let keychain else { throw SystemProxyOperationError(OperationIssue.systemProxyUnableToOpenTheKeychain(String(path))) }
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchSearchList: [keychain],
            kSecMatchSubjectContains: "ProxyMirror CA",
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]
        var matches: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &matches)
        if status == errSecItemNotFound { return [] }
        try requireSecuritySuccess(status)
        guard let certificates = matches as? [SecCertificate] else {
            throw SystemProxyOperationError(OperationIssue.systemProxyUnableToReadKeychainCertificates(String(path)))
        }
        return try certificates.compactMap(resetFingerprint)
    }

    static func resetFingerprint(_ certificate: SecCertificate) throws -> String? {
        let der = SecCertificateCopyData(certificate) as Data
        let parsed = try X509.Certificate(derEncoded: Array(der))
        // CopyCommonName 对无 CN 也可能返回 errSecInternal，先区分无属性与真正解码失败。
        guard parsed.subject.contains(where: { $0.contains(where: { $0.type == .RDNAttributeType.commonName }) }) else {
            return nil
        }
        var commonName: CFString?
        let status = SecCertificateCopyCommonName(certificate, &commonName)
        try requireSecuritySuccess(status)
        guard commonName as String? == "ProxyMirror CA" else { return nil }
        return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    private static func requireSecuritySuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String?
            throw SystemProxyOperationError(message.map(OperationIssue.technical) ?? OperationIssue.systemProxyUnableToReadTheKeychainErrorCode(Int(status)))
        }
    }

    /// 仅按精确 CN 匹配后的指纹删除；任一删除失败立即停止，不能替换本地 CA。
    static func resetScript(keychains: [KeychainCertificates], securityPath: String = "/usr/bin/security") -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return keychains.flatMap { keychain in
            keychain.fingerprints.map { fingerprint in
                "\(quote(securityPath)) delete-certificate -t -Z \(quote(fingerprint)) \(quote(keychain.path)) || exit $?"
            }
        }.joined(separator: "\n")
    }

    static func revealCAFile() {
        do {
            let pem = try CertificateAuthority.shared.caPEM()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirrorCA.pem")
            try pem.write(to: tmp, atomically: true, encoding: .utf8)
            NSWorkspace.shared.selectFile(tmp.path, inFileViewerRootedAtPath: tmp.deletingLastPathComponent().path)
        } catch {
            NSLog("[ProxyMirror] 导出证书失败: \(error)")
        }
    }
}
