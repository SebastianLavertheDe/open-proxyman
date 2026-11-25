import Foundation
import Crypto
import X509
import NIOSSL
@testable import ProxyMirrorCore

@MainActor
func checkTLSMetadata(_ test: CoreAssertions, leafPEM: String, certificate: Certificate) throws {
    test.equal(TLSConnectionMetadata.versionLabel(.tlsv12), "TLS 1.2", "TLS 1.2 is labeled without enum implementation details")
    test.equal(TLSConnectionMetadata.versionLabel(.tlsv13), "TLS 1.3", "TLS 1.3 is labeled without enum implementation details")
    let peer = try NIOSSLCertificate(bytes: Array(leafPEM.utf8), format: .pem)
    let details = try TLSConnectionMetadata.certificateDetails(peer)
    test.equal(details.der, try Data(peer.toDERBytes()), "Certificate summary preserves the exact observed DER")
    test.equal(details.subject, certificate.subject.description, "Certificate summary decodes the leaf subject")
    test.equal(details.issuer, certificate.issuer.description, "Certificate summary decodes the issuer")
    test.equal(details.validFrom, certificate.notValidBefore, "Certificate summary preserves validity start")
    test.equal(details.validUntil, certificate.notValidAfter, "Certificate summary preserves validity end")
    test.expect(details.subjectAlternativeNames.contains { $0.contains("leaf.test") }, "Certificate summary includes SAN names")
    test.equal(details.publicKey, "P256.PublicKey", "Certificate summary exposes the public key algorithm")
    test.expect(!details.signatureAlgorithm.isEmpty, "Certificate summary exposes the signature algorithm")
    test.equal(details.fingerprintSHA256.split(separator: ":").count, 32, "Certificate fingerprint is SHA-256")

    let tx = Transaction()
    tx.connectionDetails = ProxyConnectionDetails(tlsVersion: "TLS 1.3", clientTLSVersion: "TLS 1.2", serverCertificate: details)
    let record = SessionRecord(tx)
    let restored = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record)).transaction()
    test.equal(restored.connectionDetails, tx.connectionDetails, "Native session round-trip preserves both TLS versions and the observed certificate")
}
