import Foundation
import Crypto
import X509
import NIOCore
import NIOSSL

/// NIOSSL accessors must run on the owning connection's event loop after its handshake.
enum TLSConnectionMetadata {
    static func versionLabel(_ version: TLSVersion) -> String {
        switch version {
        case .tlsv1: return "TLS 1.0"
        case .tlsv11: return "TLS 1.1"
        case .tlsv12: return "TLS 1.2"
        case .tlsv13: return "TLS 1.3"
        }
    }

    static func clientVersion(on channel: Channel?) -> String? {
        guard let channel else { return nil }
        channel.eventLoop.assertInEventLoop()
        // HTTP/2 stream channels inherit the TLS connection from their parent.
        var candidate: Channel? = channel
        // A TCP channel's listener may belong to another loop. Never traverse
        // into that pipeline when this was an ordinary cleartext connection.
        while let current = candidate, current.eventLoop.inEventLoop {
            if let version = try? current.pipeline.syncOperations.nioSSL_tlsVersion() {
                return versionLabel(version)
            }
            candidate = current.parent
        }
        return nil
    }

    static func captureUpstream(on channel: Channel, into details: inout ProxyConnectionDetails) {
        channel.eventLoop.assertInEventLoop()
        details.tlsVersion = (try? channel.pipeline.syncOperations.nioSSL_tlsVersion()).map(versionLabel)
        if let peer = try? channel.pipeline.syncOperations.nioSSL_peerCertificate() {
            details.serverCertificate = try? certificateDetails(peer)
        }
    }

    static func certificateDetails(_ peer: NIOSSLCertificate) throws -> TLSCertificateDetails {
        let der = try peer.toDERBytes()
        let certificate = try Certificate(derEncoded: der)
        let alternatives = try certificate.extensions.subjectAlternativeNames
        return TLSCertificateDetails(
            der: Data(der), subject: certificate.subject.description, issuer: certificate.issuer.description,
            validFrom: certificate.notValidBefore, validUntil: certificate.notValidAfter,
            subjectAlternativeNames: alternatives.map { $0.map { String(describing: $0) } } ?? [],
            publicKey: certificate.publicKey.description,
            signatureAlgorithm: String(describing: certificate.signatureAlgorithm),
            fingerprintSHA256: SHA256.hash(data: Data(der)).map { String(format: "%02X", $0) }.joined(separator: ":")
        )
    }
}
