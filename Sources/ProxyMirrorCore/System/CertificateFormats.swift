import Foundation
import Darwin
import Crypto
import X509
import NIOSSL

/// File conversion and purpose validation; loading a file never installs or trusts it.
enum CertificateFormats {
    enum Purpose: String, CaseIterable, Identifiable, Sendable {
        case rootCA, upstreamCA, client, server
        var localizedTitle: String {
            switch self {
            case .rootCA: return Strings.Errors.certificatePurposeRoot
            case .upstreamCA: return Strings.Errors.certificatePurposeUpstream
            case .client: return Strings.Errors.certificatePurposeClient
            case .server: return Strings.Errors.certificatePurposeServer
            }
        }
        var id: String { rawValue }
        var needsKey: Bool { self != .upstreamCA }
    }

    enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
        case pem, der, privateKey, p12
        var localizedTitle: String {
            switch self {
            case .pem: return Strings.Errors.certificateExportPem
            case .der: return Strings.Errors.certificateExportDer
            case .privateKey: return Strings.Errors.certificateExportKey
            case .p12: return Strings.Errors.certificateExportP12
            }
        }
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

    struct FormatError: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ message: String) { operationIssue = .technical(message) }
        var message: String { operationIssue.diagnostic }
        var text: String { operationIssue.diagnostic }
        var errorDescription: String? { operationIssue.diagnostic }
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
                    throw FormatError(OperationIssue.certificateFormatsTheCertificateDoesNotMatchThePrivateKey)
                }
                let leaf = certificates.remove(at: index)
                certificates.insert(leaf, at: 0)
            }
            guard let leaf = certificates.first else { throw FormatError(OperationIssue.certificateFormatsNoUsableCertificateWasFound) }
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
        guard let leaf = chain.first else { throw FormatError(OperationIssue.certificateFormatsTheCertificateChainIsEmpty) }
        for certificate in chain {
            guard certificate.notValidBefore <= now, certificate.notValidAfter > now else {
                throw FormatError(OperationIssue.certificateFormatsTheCertificateChainContainsACertificateThatIs)
            }
        }
        if purpose.needsKey {
            guard let privateKey = material.privateKeyPEM else { throw FormatError(OperationIssue.certificateFormatsThisPurposeRequiresAMatchingPrivateKeySelect) }
            let key = try Certificate.PrivateKey(pemEncoded: privateKey)
            guard key.publicKey == leaf.publicKey else { throw FormatError(OperationIssue.certificateFormatsTheFirstCertificateInTheChainDoesNot) }
        }
        switch purpose {
        case .rootCA, .upstreamCA:
            for certificate in purpose == .rootCA ? [leaf] : chain {
                guard case .isCertificateAuthority? = try certificate.extensions.basicConstraints else {
                    throw FormatError(OperationIssue.certificateFormatsACaCertificateMustDeclareCaBasicConstraints)
                }
                if let usage = try certificate.extensions.keyUsage, !usage.keyCertSign {
                    throw FormatError(OperationIssue.certificateFormatsTheCaCertificateKeyUsageDoesNotPermit)
                }
            }
        case .client, .server:
            if try isCertificateAuthority(leaf) {
                throw FormatError(OperationIssue.certificateFormatsMtlsAndServerIdentitiesRequireALeafCertificate)
            }
            if let usage = try leaf.extensions.extendedKeyUsage,
               !usage.contains(purpose == .client ? .clientAuth : .serverAuth), !usage.contains(.any) {
                throw FormatError(purpose == .client ? OperationIssue.certificateFormatsTheCertificateExtendedKeyUsageDoesNotPermit : OperationIssue.certificateFormatsTheCertificateExtendedKeyUsageDoesNotPermit2)
            }
            if let usage = try leaf.extensions.keyUsage,
               !(usage.digitalSignature || (purpose == .server && (usage.keyEncipherment || usage.keyAgreement))) {
                throw FormatError(OperationIssue.certificateFormatsTheCertificateKeyUsageDoesNotSupportThe)
            }
            guard ClientTLSIdentities.hostPattern(host) != nil else { throw FormatError(OperationIssue.certificateFormatsEnterAValidTargetHostOrExampleCom) }
            if purpose == .server { try validateServerHost(leaf, host: host) }
        }
    }

    static func export(authority: CertificateAuthority = .shared, format: ExportFormat, password: String = "", to target: URL) throws {
        try validatePassword(password)
        if format.needsPassword, password.isEmpty { throw FormatError(OperationIssue.certificateFormatsSetANonemptyPasswordForThePrivateKey) }
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
                throw FormatError(OperationIssue.certificateFormatsTheRootCaChangedDuringExportExportIt)
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
            guard !parsed.isEmpty, parsed.count == count, count <= 64 else { throw FormatError(OperationIssue.certificateFormatsThePemCertificateChainIsInvalidOrContains) }
            return try parsed.map { try Certificate(derEncoded: $0.toDERBytes()) }
        }
        do {
            return [try Certificate(derEncoded: NIOSSLCertificate(bytes: Array(data), format: .der).toDERBytes())]
        } catch { throw FormatError(OperationIssue.certificateFormatsSelectAValidPemOrDerCerCertificate) }
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
            throw FormatError(OperationIssue.certificateFormatsTheServerCertificateHasNoSubjectAlternativeName)
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
        guard matches else { throw FormatError(OperationIssue.certificateFormatsTheCertificateSanDoesNotMatchTheServer) }
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
            throw FormatError(OperationIssue.certificateFormatsSelectARegularFileBetween1ByteAnd)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let next = try handle.read(upToCount: 64 * 1024), !next.isEmpty {
            guard data.count + next.count <= fileLimit else { throw FormatError(OperationIssue.certificateFormatsTheFileExceeds8Mib) }
            data.append(next)
        }
        guard !data.isEmpty else { throw FormatError(OperationIssue.certificateFormatsTheFileIsEmpty) }
        return data
    }

    private static func validatePassword(_ password: String) throws {
        guard password.utf8.count <= 4096, !password.contains("\0"), !password.contains("\n"), !password.contains("\r") else {
            throw FormatError(OperationIssue.certificateFormatsThePasswordCannotContainANewlineOrNul)
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
            throw FormatError(OperationIssue.certificateFormatsCertificateFormatConversionTimedOut)
        }
        guard process.terminationStatus == 0 else {
            throw FormatError(OperationIssue.certificateFormatsCertificateConversionFailedCheckThePasswordFileFormat)
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
