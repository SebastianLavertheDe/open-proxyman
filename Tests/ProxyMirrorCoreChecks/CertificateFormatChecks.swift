import Foundation
import Crypto
import X509
@testable import ProxyMirrorCore

@MainActor
func checkCertificateFormats(_ test: CoreAssertions) throws {
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authority = CertificateAuthority(storageDirectory: directory.appendingPathComponent("Authority", isDirectory: true))
    try authority.ensureCA()
    try checkSimulatorCertificateInstaller(test, certificate: authority.caCertPath)
    let password = "fixture-'$-密钥-123"
    let p12 = directory.appendingPathComponent("identity.p12")
    try CertificateFormats.export(authority: authority, format: .p12, password: password, to: p12)
    let identity = try CertificateFormats.load(certificate: p12, password: password)
    test.expect(identity.isCA && identity.privateKeyPEM != nil, "P12 round-trip preserves the CA identity and private key")
    test.equal(identity.certificatePEM.trimmingCharacters(in: .whitespacesAndNewlines),
               try authority.caPEM().trimmingCharacters(in: .whitespacesAndNewlines), "P12 round-trip preserves the certificate")
    try CertificateFormats.validate(identity, purpose: .rootCA)
    test.rejects(try CertificateFormats.load(certificate: p12, password: "incorrect"), with: CertificateFormats.FormatError.self,
                 "Incorrect P12 password is rejected")
    test.rejects(try CertificateFormats.validate(identity, purpose: .client, host: "api.example.test"), with: CertificateFormats.FormatError.self,
                 "A root CA cannot be imported as a client identity")
    let attributes = try FileManager.default.attributesOfItem(atPath: p12.path)
    test.equal((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "P12 export is private to the current user")

    let der = directory.appendingPathComponent("root.der")
    try CertificateFormats.export(authority: authority, format: .der, to: der)
    let derMaterial = try CertificateFormats.load(certificate: der)
    test.equal(derMaterial.fingerprint, identity.fingerprint, "DER and P12 inputs identify the same root certificate")
    test.expect(derMaterial.privateKeyPEM == nil, "DER certificate import does not invent a private key")
    test.rejects(try CertificateFormats.validate(derMaterial, purpose: .rootCA), with: CertificateFormats.FormatError.self,
                 "Root signing import requires an explicit matching private key")
    try CertificateFormats.validate(derMaterial, purpose: .upstreamCA)

    let key = directory.appendingPathComponent("encrypted-key.pem")
    try CertificateFormats.export(authority: authority, format: .privateKey, password: password, to: key)
    let encrypted = try String(contentsOf: key, encoding: .utf8)
    test.expect(encrypted.contains("BEGIN ENCRYPTED PRIVATE KEY"), "Exported private key is encrypted PKCS#8")
    let recovered = try CertificateFormats.load(certificate: authority.caCertPath, privateKey: key, password: password)
    test.equal(recovered.fingerprint, identity.fingerprint, "Encrypted PEM key imports with its matching CA")
    let denied = directory.appendingPathComponent("denied.p12")
    test.rejects(try CertificateFormats.export(authority: authority, format: .p12, to: denied), with: CertificateFormats.FormatError.self,
                 "Exporting a private identity requires a nonempty password")
    test.expect(!FileManager.default.fileExists(atPath: denied.path), "Rejected identity export creates no output file")

    let signer = P256.Signing.PrivateKey()
    let clientKey = P256.Signing.PrivateKey()
    let issuer = try DistinguishedName { CommonName("Formats Test CA") }
    let client = try Certificate(version: .v3,
        serialNumber: Certificate.SerialNumber(bytes: [1, 2, 3, 4]), publicKey: Certificate.PublicKey(clientKey.publicKey),
        notValidBefore: Date().addingTimeInterval(-600), notValidAfter: Date().addingTimeInterval(86_400),
        issuer: issuer, subject: try DistinguishedName { CommonName("Formats Test Client") },
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.clientAuth])
        }, issuerPrivateKey: Certificate.PrivateKey(signer))
    let clientPEM = directory.appendingPathComponent("client.pem")
    let clientKeyPEM = directory.appendingPathComponent("client-key.pem")
    try Data(try client.serializeAsPEM().pemString.utf8).write(to: clientPEM)
    try PrivateAppFile.write(Data(clientKey.pemRepresentation.utf8), to: clientKeyPEM)
    let material = try CertificateFormats.load(certificate: clientPEM, privateKey: clientKeyPEM)
    try CertificateFormats.validate(material, purpose: .client, host: "api.example.test")
    test.rejects(try CertificateFormats.validate(material, purpose: .server, host: "api.example.test"), with: CertificateFormats.FormatError.self,
                 "Client-only EKU cannot be used as a server identity")
    test.rejects(try CertificateFormats.validate(material, purpose: .upstreamCA), with: CertificateFormats.FormatError.self,
                 "A leaf cannot become an upstream root")
    let store = ClientTLSIdentities(directory: directory.appendingPathComponent("Clients", isDirectory: true))
    try store.install(host: "api.example.test", material: material)
    test.expect(store.identity(for: "api.example.test") != nil, "Imported mTLS material reaches the upstream identity selector")
    test.expect(ClientTLSIdentities(directory: directory.appendingPathComponent("Clients", isDirectory: true))
        .identity(for: "api.example.test") != nil, "Imported mTLS identity survives a storage reload")

    let server = try Certificate(version: .v3,
        serialNumber: Certificate.SerialNumber(bytes: [5, 6, 7, 8]), publicKey: Certificate.PublicKey(clientKey.publicKey),
        notValidBefore: Date().addingTimeInterval(-600), notValidAfter: Date().addingTimeInterval(86_400),
        issuer: issuer, subject: try DistinguishedName { CommonName("*.example.test") },
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([.dnsName("*.example.test")])
        }, issuerPrivateKey: Certificate.PrivateKey(signer))
    let serverPEM = directory.appendingPathComponent("server.pem")
    try Data(try server.serializeAsPEM().pemString.utf8).write(to: serverPEM)
    let serverMaterial = try CertificateFormats.load(certificate: serverPEM, privateKey: clientKeyPEM)
    try CertificateFormats.validate(serverMaterial, purpose: .server, host: "api.example.test")
    try CertificateFormats.validate(serverMaterial, purpose: .server, host: "*.example.test")
    test.rejects(try CertificateFormats.validate(serverMaterial, purpose: .server, host: "deep.api.example.test"),
                 with: CertificateFormats.FormatError.self, "Certificate wildcards cover a single label only")
    test.rejects(try CertificateFormats.validate(serverMaterial, purpose: .server, host: "example.test"),
                 with: CertificateFormats.FormatError.self, "Certificate wildcard does not cover its bare domain")
    test.rejects(try CertificateFormats.validate(serverMaterial, purpose: .server, host: "api.example.test",
                                               now: Date().addingTimeInterval(172_800)),
                 with: CertificateFormats.FormatError.self, "Expired server identities are rejected before installation")

    let incorrectIPCertificate = try Certificate(version: .v3,
        serialNumber: Certificate.SerialNumber(bytes: [9, 10, 11, 12]), publicKey: Certificate.PublicKey(clientKey.publicKey),
        notValidBefore: Date().addingTimeInterval(-600), notValidAfter: Date().addingTimeInterval(86_400),
        issuer: issuer, subject: try DistinguishedName { CommonName("127.0.0.1") },
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([.dnsName("127.0.0.1")])
        }, issuerPrivateKey: Certificate.PrivateKey(signer))
    let incorrectIPPEM = directory.appendingPathComponent("incorrect-ip-san.pem")
    try Data(try incorrectIPCertificate.serializeAsPEM().pemString.utf8).write(to: incorrectIPPEM)
    let incorrectIP = try CertificateFormats.load(certificate: incorrectIPPEM, privateKey: clientKeyPEM)
    test.rejects(try CertificateFormats.validate(incorrectIP, purpose: .server, host: "127.0.0.1"),
                 with: CertificateFormats.FormatError.self, "An IP literal requires an IP Address SAN, not a DNS Name SAN")

    let guides = CertificatePlatformGuides.frameworks + CertificatePlatformGuides.simulatorPlatforms + ["iOS", "Android", "Firefox"]
    for platform in guides {
        let guide = CertificatePlatformGuides.guide(for: platform, certificatePath: "/tmp/Fixture CA's.pem", port: 9191)
        test.expect(!guide.steps.isEmpty && !guide.links.isEmpty, "\(platform) has concrete guidance and primary documentation")
        test.expect(!guide.commands.contains("9090"), "\(platform) guide uses the configured port")
    }
    let node = CertificatePlatformGuides.guide(for: "NodeJS", certificatePath: "/tmp/Fixture CA's.pem", port: 9191)
    test.expect(node.commands.contains("'\\''"), "Guide shell examples quote apostrophes in the CA path")
}
