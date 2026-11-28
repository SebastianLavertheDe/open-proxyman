import Foundation
import NIOSSL
import X509

/// Preview/export may receive a combined identity PEM; emit certificate blocks only.
struct PublicCertificateData: Sendable {
    let leafDER: Data
    let chainPEM: Data

    init(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let certificates: [NIOSSLCertificate]
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            certificates = try NIOSSLCertificate.fromPEMBytes(Array(data))
            let count = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
            guard certificates.count == count else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            certificates = [try NIOSSLCertificate(bytes: Array(data), format: .der)]
        }
        guard let leaf = certificates.first, certificates.count <= 64 else { throw CocoaError(.fileReadCorruptFile) }
        leafDER = try Data(leaf.toDERBytes())
        let pem = try certificates.map {
            try Certificate(derEncoded: $0.toDERBytes()).serializeAsPEM().pemString
        }.joined(separator: "\n")
        chainPEM = Data(pem.utf8)
    }
}
