import Darwin
import Foundation
import NIOSSL
import X509

struct ClientTLSIdentity: Sendable {
    let id: UUID
    let certificateChain: [NIOSSLCertificate]
    let privateKey: NIOSSLPrivateKey
    let validFrom: Date
    let expiry: Date
}

final class ClientTLSIdentities: @unchecked Sendable {
    struct Summary: Identifiable {
        let id: UUID
        let host: String
        let subject: String
        let expiry: Date
    }

    private struct Stored: Codable {
        let id: UUID
        let host: String
        let certificate: Data
        let key: Data
    }

    private struct Entry {
        let stored: Stored
        let summary: Summary
        let identity: ClientTLSIdentity
    }

    static let shared = ClientTLSIdentities(directory: CertificateAuthority.applicationSupport
        .appendingPathComponent("ClientIdentities", isDirectory: true))

    private let directory: URL
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var storedError: String?

    var loadError: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
    private static let maxRecords = 32
    private static let maxStoreBytes = 16 * 1024 * 1024

    init(directory: URL) {
        self.directory = directory
        let path = directory.appendingPathComponent("identities.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            guard (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheIdentityFilePermissionsMustBe0600)
            }
            let bytes = try Self.read(path, upTo: Self.maxStoreBytes)
            let stored = try JSONDecoder().decode([Stored].self, from: bytes)
            guard stored.count <= Self.maxRecords else { throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheClientIdentityCountExceedsTheLimit) }
            entries = try stored.map(Self.parse)
        } catch {
            storedError = Strings.Errors.clientTlsidentitiesUnableToReadUpstreamClientIdentities(String(error.localizedDescription))
        }
    }

    var summaries: [Summary] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.summary).sorted { $0.host < $1.host }
    }

    func identity(for host: String) -> ClientTLSIdentity? {
        guard let host = ExternalProxyHost(host) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let exact = entries.first(where: { $0.stored.host == host.name }) {
            return exact.identity
        }
        guard host.isDNS else { return nil }
        return entries.filter { entry in
            let pattern = entry.stored.host
            return pattern.hasPrefix("*.") && host.name.hasSuffix(String(pattern.dropFirst()))
        }.max { $0.stored.host.count < $1.stored.host.count }?.identity
    }

    func install(host: String, certificate: URL, privateKey: URL) throws {
        try install(host: host, certificate: Self.read(certificate, upTo: 256 * 1024),
                    key: Self.read(privateKey, upTo: 128 * 1024))
    }

    func install(host: String, p12: URL, password: String) throws {
        let material = try CertificateFormats.load(certificate: p12, password: password)
        try CertificateFormats.validate(material, purpose: .client, host: host)
        try install(host: host, material: material)
    }

    func install(host: String, material: CertificateFormats.Material) throws {
        try CertificateFormats.validate(material, purpose: .client, host: host)
        guard let key = material.privateKeyPEM else { throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheClientIdentityIsMissingItsPrivateKey) }
        try install(host: host, certificate: Data(material.certificatePEM.utf8), key: Data(key.utf8))
    }

    private func install(host: String, certificate: Data, key: Data) throws {
        guard let host = Self.hostPattern(host) else {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesEnterAHostnameIpAddressOrExampleCom)
        }
        guard certificate.count <= 256 * 1024, key.count <= 128 * 1024 else {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheCertificateChainOrPrivateKeyExceedsThe)
        }
        let entry = try Self.parse(Stored(id: UUID(), host: host, certificate: certificate, key: key))
        let now = Date()
        guard entry.identity.validFrom <= now, entry.identity.expiry > now else {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheClientCertificateIsNotYetValidOr)
        }
        lock.lock()
        defer { lock.unlock() }
        let replacement = entries.filter { $0.stored.host != host } + [entry]
        guard replacement.count <= Self.maxRecords else {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesAMaximumOfClientIdentitiesCanBeSaved(Int(Self.maxRecords)))
        }
        try save(replacement)
        entries = replacement
        storedError = nil
    }

    func remove(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let remaining = entries.filter { $0.stored.id != id }
        try save(remaining)
        entries = remaining
    }

    static func hostPattern(_ input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("*.") {
            guard let host = ExternalProxyHost(String(input.dropFirst(2))), host.isDNS else { return nil }
            return "*." + host.name
        }
        return ExternalProxyHost(input)?.name
    }

    private static func parse(_ value: Stored) throws -> Entry {
        guard hostPattern(value.host) == value.host else { throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheClientIdentityHostIsInvalid) }
        let chain: [NIOSSLCertificate]
        let key: NIOSSLPrivateKey
        let cert: Certificate
        let comparableKey: Certificate.PrivateKey
        do {
            chain = try NIOSSLCertificate.fromPEMBytes(Array(value.certificate))
            guard let leaf = chain.first else { throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheCertificateChainIsEmpty) }
            cert = try Certificate(derEncoded: leaf.toDERBytes())
            key = try NIOSSLPrivateKey(bytes: Array(value.key), format: .pem)
            comparableKey = try Certificate.PrivateKey(pemEncoded: String(decoding: value.key, as: UTF8.self))
        } catch {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesUnableToParseTheClientCertificateOrPrivate)
        }
        guard cert.publicKey == comparableKey.publicKey else {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheFirstCertificateInTheChainDoesNot)
        }
        if try CertificateFormats.isCertificateAuthority(cert) {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesAClientIdentityMustUseALeafCertificate)
        }
        if let usage = try cert.extensions.extendedKeyUsage, !usage.contains(.clientAuth), !usage.contains(.any) {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheCertificateExtendedKeyUsageDoesNotPermit)
        }
        if let usage = try cert.extensions.keyUsage, !usage.digitalSignature {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheClientCertificateKeyUsageDoesNotPermit)
        }
        let identity = ClientTLSIdentity(id: value.id, certificateChain: chain, privateKey: key,
                                         validFrom: cert.notValidBefore, expiry: cert.notValidAfter)
        let summary = Summary(id: value.id, host: value.host, subject: cert.subject.description, expiry: cert.notValidAfter)
        return Entry(stored: value, summary: summary, identity: identity)
    }

    private static func read(_ url: URL, upTo limit: Int) throws -> Data {
        let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attrs.isRegularFile == true, let size = attrs.fileSize, (1...limit).contains(size) else {
            throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheFileIsEmptyTooLargeOrNot)
        }
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var bytes = Data()
        while let next = try stream.read(upToCount: 64 * 1024), !next.isEmpty {
            guard bytes.count + next.count <= limit else { throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheFileExceedsTheSizeLimit) }
            bytes.append(next)
        }
        return bytes
    }

    private func save(_ entries: [Entry]) throws {
        let manager = FileManager.default
        let privatePermissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: privatePermissions)
        try manager.setAttributes(privatePermissions, ofItemAtPath: directory.path)
        let target = directory.appendingPathComponent("identities.json")
        if entries.isEmpty {
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            return
        }
        let data = try JSONEncoder().encode(entries.map(\.stored))
        guard data.count <= Self.maxStoreBytes else { throw ClientTLSIdentityError(OperationIssue.clientTlsidentitiesTheClientIdentityFileIsTooLarge) }
        try PrivateAppFile.write(data, to: target)
    }
}

enum PrivateAppFile {
    static func write(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".private-\(UUID().uuidString)")
        let manager = FileManager.default
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        guard rename(temporary.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

struct ClientTLSIdentityError: LocalizedError, OperationIssueProviding {
    let operationIssue: OperationIssue
    init(_ issue: OperationIssue) { operationIssue = issue }
    init(_ message: String) { operationIssue = .technical(message) }
    var message: String { operationIssue.diagnostic }
    var text: String { operationIssue.diagnostic }
    var errorDescription: String? { operationIssue.diagnostic }
}
