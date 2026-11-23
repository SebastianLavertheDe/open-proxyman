import Foundation
import Darwin
import Crypto
import X509
import NIOSSL

/// File conversion and purpose validation; loading a file never installs or trusts it.
enum CertificateFormats {
    enum Purpose: String, CaseIterable, Identifiable, Sendable {
        case rootCA = "抓包根 CA", upstreamCA = "上游 CA 信任链", client = "上游 mTLS 身份", server = "按域名服务端身份"
        var id: String { rawValue }
        var needsKey: Bool { self != .upstreamCA }
    }

    enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
        case pem = "CA 证书 PEM", der = "CA 证书 DER", privateKey = "加密私钥 PEM", p12 = "CA 与私钥 PKCS#12"
        var id: String { rawValue }
        var needsPassword: Bool { self == .privateKey || self == .p12 }
        var fileExtension: String {
            switch self { case .pem: return "pem"; case .der: return "der"; case .privateKey: return "key.pem"; case .p12: return "p12" }
        }
    }

    struct Material: Sendable {
        let certificatePEM: String
        let privateKeyPEM: String?
        let subject: String
        let issuer: String
        let expiry: Date
        let fingerprint: String
        let certificateCount: Int
        let isCA: Bool
    }

    struct FormatError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let fileLimit = 8 * 1024 * 1024

    static func load(certificate: URL, privateKey: URL? = nil, password: String = "") throws -> Material {
        try validatePassword(password)
        return try withWorkspace { directory in
            let input = directory.appendingPathComponent("input")
            let inputData = try read(certificate)
            try PrivateAppFile.write(inputData, to: input)
            let certificateData: Data
            var keyData: Data?
            if ["p12", "pfx"].contains(certificate.pathExtension.lowercased()) {
                let certs = directory.appendingPathComponent("certificates.pem")
                let keys = directory.appendingPathComponent("keys.pem")
                try openssl(["pkcs12", "-in", input.path, "-nokeys", "-out", certs.path], password: password,
                            passwordOption: "-passin", directory: directory)
                try openssl(["pkcs12", "-in", input.path, "-nocerts", "-nodes", "-out", keys.path], password: password,
                            passwordOption: "-passin", directory: directory)
                certificateData = try read(certs)
                if let extracted = try? read(keys), String(decoding: extracted, as: UTF8.self).contains("PRIVATE KEY-----") {
                    keyData = try normalizeKey(keys, password: "", directory: directory)
                }
            } else {
                certificateData = inputData
                if let privateKey {
                    let keyInput = directory.appendingPathComponent("key-input")
                    try PrivateAppFile.write(try read(privateKey), to: keyInput)
                    keyData = try normalizeKey(keyInput, password: password, directory: directory,
                                               der: privateKey.pathExtension.lowercased() == "der")
                } else if String(decoding: inputData, as: UTF8.self).contains("PRIVATE KEY-----") {
                    keyData = try normalizeKey(input, password: password, directory: directory)
                }
            }
            var certificates = try parseCertificates(certificateData)
            let keyText = keyData.map { String(decoding: $0, as: UTF8.self) }
            if let keyText {
                let key = try Certificate.PrivateKey(pemEncoded: keyText)
                guard let index = certificates.firstIndex(where: { $0.publicKey == key.publicKey }) else {
                    throw FormatError("证书与私钥不匹配。")
                }
                let leaf = certificates.remove(at: index)
                certificates.insert(leaf, at: 0)
            }
            guard let leaf = certificates.first else { throw FormatError("没有可用证书。") }
            let pem = try certificates.map { try $0.serializeAsPEM().pemString }.joined(separator: "\n")
            let der = try NIOSSLCertificate(bytes: Array(try leaf.serializeAsPEM().pemString.utf8), format: .pem).toDERBytes()
            let ca = try isCertificateAuthority(leaf)
            return Material(certificatePEM: pem, privateKeyPEM: keyText, subject: leaf.subject.description,
                            issuer: leaf.issuer.description, expiry: leaf.notValidAfter,
                            fingerprint: SHA256.hash(data: Data(der)).map { String(format: "%02X", $0) }.joined(separator: ":"),
                            certificateCount: certificates.count, isCA: ca)
        }
    }

    static func validate(_ material: Material, purpose: Purpose, host: String = "", now: Date = Date()) throws {
        let chain = try parseCertificates(Data(material.certificatePEM.utf8))
        guard let leaf = chain.first else { throw FormatError("证书链为空。") }
        for certificate in chain {
            guard certificate.notValidBefore <= now, certificate.notValidAfter > now else {
                throw FormatError("证书链中存在尚未生效或已过期的证书。")
            }
        }
        if purpose.needsKey {
            guard let privateKey = material.privateKeyPEM else { throw FormatError("此用途需要匹配的私钥；请选择私钥或带身份的 P12 文件。") }
            let key = try Certificate.PrivateKey(pemEncoded: privateKey)
            guard key.publicKey == leaf.publicKey else { throw FormatError("证书链首张证书与私钥不匹配。") }
        }
        switch purpose {
        case .rootCA, .upstreamCA:
            for certificate in purpose == .rootCA ? [leaf] : chain {
                guard case .isCertificateAuthority? = try certificate.extensions.basicConstraints else {
                    throw FormatError("CA 用途要求证书声明 CA 基本约束，不能导入普通服务端/客户端证书。")
                }
                if let usage = try certificate.extensions.keyUsage, !usage.keyCertSign {
                    throw FormatError("CA 证书的 Key Usage 不允许签发证书。")
                }
            }
        case .client, .server:
            if try isCertificateAuthority(leaf) {
                throw FormatError("mTLS/服务端身份需要叶子证书，不能使用 CA 私钥。")
            }
            if let usage = try leaf.extensions.extendedKeyUsage,
               !usage.contains(purpose == .client ? .clientAuth : .serverAuth), !usage.contains(.any) {
                throw FormatError(purpose == .client ? "此证书的扩展用途不允许 TLS 客户端认证。" : "此证书的扩展用途不允许 TLS 服务端认证。")
            }
            if let usage = try leaf.extensions.keyUsage,
               !(usage.digitalSignature || (purpose == .server && (usage.keyEncipherment || usage.keyAgreement))) {
                throw FormatError("证书的 Key Usage 不支持所选 TLS 身份用途。")
            }
            guard ClientTLSIdentities.hostPattern(host) != nil else { throw FormatError("请填写有效目标主机或 *.example.com。") }
            if purpose == .server { try validateServerHost(leaf, host: host) }
        }
    }

    static func export(authority: CertificateAuthority = .shared, format: ExportFormat, password: String = "", to target: URL) throws {
        try validatePassword(password)
        if format.needsPassword, password.isEmpty { throw FormatError("请为私钥或 P12 设置非空口令。") }
        try authority.ensureCA()
        if format == .pem {
            try PrivateAppFile.write(Data(try authority.caPEM().utf8), to: target)
            return
        }
        if format == .der {
            try PrivateAppFile.write(try authority.caDER(), to: target)
            return
        }
        try withWorkspace { directory in
            let certificate = directory.appendingPathComponent("certificate.pem")
            let key = directory.appendingPathComponent("key.pem")
            let output = directory.appendingPathComponent("export")
            try PrivateAppFile.write(Data(try authority.caPEM().utf8), to: certificate)
            let keyData = try read(authority.caKeyPath)
            let publicKey = try Certificate.PrivateKey(pemEncoded: String(decoding: keyData, as: UTF8.self)).publicKey
            guard try parseCertificates(Data(contentsOf: certificate)).first?.publicKey == publicKey else {
                throw FormatError("根 CA 在导出期间发生变化，请重新导出。")
            }
            try PrivateAppFile.write(keyData, to: key)
            let arguments: [String]
            if format == .p12 {
                arguments = ["pkcs12", "-export", "-in", certificate.path, "-inkey", key.path,
                             "-name", "ProxyMirror CA", "-out", output.path]
            } else {
                arguments = ["pkey", "-in", key.path, "-aes-256-cbc", "-out", output.path]
            }
            try openssl(arguments, password: password, passwordOption: "-passout", directory: directory)
            try PrivateAppFile.write(try read(output), to: target)
        }
    }

    static func parseCertificates(_ data: Data) throws -> [Certificate] {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            let parsed = CustomCertificateStore.splitCertificates(text)
            let count = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
            guard !parsed.isEmpty, parsed.count == count, count <= 64 else { throw FormatError("PEM 证书链无效或超过 64 张。") }
            return try parsed.map { try Certificate(derEncoded: $0.toDERBytes()) }
        }
        do {
            return [try Certificate(derEncoded: NIOSSLCertificate(bytes: Array(data), format: .der).toDERBytes())]
        } catch { throw FormatError("请选择有效 PEM、DER/CER 证书，或带 .p12/.pfx 扩展名的 PKCS#12 文件。") }
    }

    static func isCertificateAuthority(_ certificate: Certificate) throws -> Bool {
        let constraints = try certificate.extensions.basicConstraints
        switch constraints {
        case .some(.isCertificateAuthority(maxPathLength: _)): return true
        default: return false
        }
    }

    private static func validateServerHost(_ certificate: Certificate, host input: String) throws {
        guard let host = ClientTLSIdentities.hostPattern(input), let names = try certificate.extensions.subjectAlternativeNames else {
            throw FormatError("服务端证书缺少 Subject Alternative Name；请使用包含目标主机的证书。")
        }
        let literalAddress = ipBytes(host)
        let matches = names.contains { name in
            switch name {
            case .dnsName(let value):
                guard literalAddress == nil else { return false }
                let pattern = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if host.hasPrefix("*.") { return pattern == host }
                if pattern == host { return true }
                guard pattern.hasPrefix("*."), host.hasSuffix(String(pattern.dropFirst())) else { return false }
                let label = host.dropLast(pattern.count - 1)
                return !label.isEmpty && !label.contains(".")
            case .ipAddress(let address): return literalAddress == Array(address.bytes)
            default: return false
            }
        }
        guard matches else { throw FormatError("证书 SAN 与服务端域名规则不匹配；通配证书只能覆盖一个子域层级。") }
    }

    private static func ipBytes(_ host: String) -> [UInt8]? {
        var v4 = [UInt8](repeating: 0, count: 4)
        if host.withCString({ address in v4.withUnsafeMutableBytes { inet_pton(AF_INET, address, $0.baseAddress) } }) == 1 { return v4 }
        var v6 = [UInt8](repeating: 0, count: 16)
        if host.withCString({ address in v6.withUnsafeMutableBytes { inet_pton(AF_INET6, address, $0.baseAddress) } }) == 1 { return v6 }
        return nil
    }

    private static func normalizeKey(_ input: URL, password: String, directory: URL, der: Bool = false) throws -> Data {
        let output = directory.appendingPathComponent("normalized-key.pem")
        var arguments = ["pkey", "-in", input.path, "-out", output.path]
        if der { arguments += ["-inform", "DER"] }
        try openssl(arguments, password: password, passwordOption: "-passin", directory: directory)
        return try read(output)
    }

    static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, (1...fileLimit).contains(size) else {
            throw FormatError("文件应为 1 byte 到 8 MiB 的普通文件。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let next = try handle.read(upToCount: 64 * 1024), !next.isEmpty {
            guard data.count + next.count <= fileLimit else { throw FormatError("文件超过 8 MiB。") }
            data.append(next)
        }
        guard !data.isEmpty else { throw FormatError("文件为空。") }
        return data
    }

    private static func validatePassword(_ password: String) throws {
        guard password.utf8.count <= 4096, !password.contains("\0"), !password.contains("\n"), !password.contains("\r") else {
            throw FormatError("口令不可包含换行或 NUL，且不能超过 4096 字节。")
        }
    }

    private static func withWorkspace<T>(_ operation: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Cert-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        return try operation(directory)
    }

    private static func openssl(_ arguments: [String], password: String, passwordOption: String, directory: URL) throws {
        let process = Process()
        let environmentKey = "PM_CERT_PASSWORD_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if let option = arguments.firstIndex(of: "-out"), arguments.indices.contains(option + 1) {
            try PrivateAppFile.write(Data(), to: URL(fileURLWithPath: arguments[option + 1]))
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments + [passwordOption, "env:" + environmentKey]
        // Never inherit OPENSSL_CONF, loaders, or the app's unrelated secrets into the conversion helper.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", environmentKey: password]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw FormatError("证书格式转换超时。")
        }
        guard process.terminationStatus == 0 else {
            throw FormatError("证书转换失败：请检查口令、文件格式及系统 OpenSSL 支持的算法。旧版 P12 的 RC2 等算法可能不受支持。")
        }
        // Helpers create new output files inside a private directory. Tighten their modes before reading them.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}

extension Notification.Name {
    static let proxyMirrorCertificatesChanged = Notification.Name("ProxyMirror.CertificatesChanged")
}
