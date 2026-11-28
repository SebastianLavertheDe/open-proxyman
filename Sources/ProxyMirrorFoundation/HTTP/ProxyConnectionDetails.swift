import Foundation

/// Captured connection metadata is optional so older session files remain readable.
package struct ProxyConnectionDetails: Codable, Equatable, Sendable {
    package var address: String?
    package var dnsMilliseconds: Double?
    package var tcpMilliseconds: Double?
    package var tlsMilliseconds: Double?
    package var alpn: String?
    package var externalProxy: String?
    package var reused = false
    package var downstreamStream: Int?
    package var upstreamStream: Int?
    package var tlsVersion: String?
    package var clientTLSVersion: String?
    package var serverCertificate: TLSCertificateDetails?

    package init(address: String? = nil, dnsMilliseconds: Double? = nil,
                 tcpMilliseconds: Double? = nil, tlsMilliseconds: Double? = nil,
                 alpn: String? = nil, externalProxy: String? = nil, reused: Bool = false,
                 downstreamStream: Int? = nil, upstreamStream: Int? = nil,
                 tlsVersion: String? = nil, clientTLSVersion: String? = nil,
                 serverCertificate: TLSCertificateDetails? = nil) {
        self.address = address
        self.dnsMilliseconds = dnsMilliseconds
        self.tcpMilliseconds = tcpMilliseconds
        self.tlsMilliseconds = tlsMilliseconds
        self.alpn = alpn
        self.externalProxy = externalProxy
        self.reused = reused
        self.downstreamStream = downstreamStream
        self.upstreamStream = upstreamStream
        self.tlsVersion = tlsVersion
        self.clientTLSVersion = clientTLSVersion
        self.serverCertificate = serverCertificate
    }
}

/// Only the observed leaf certificate is stored. This is not a reconstructed chain.
package struct TLSCertificateDetails: Codable, Equatable, Sendable {
    package let der: Data
    package let subject: String
    package let issuer: String
    package let validFrom: Date
    package let validUntil: Date
    package let subjectAlternativeNames: [String]
    package let publicKey: String
    package let signatureAlgorithm: String
    package let fingerprintSHA256: String

    package init(der: Data, subject: String, issuer: String, validFrom: Date, validUntil: Date,
                 subjectAlternativeNames: [String], publicKey: String, signatureAlgorithm: String,
                 fingerprintSHA256: String) {
        self.der = der
        self.subject = subject
        self.issuer = issuer
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.subjectAlternativeNames = subjectAlternativeNames
        self.publicKey = publicKey
        self.signatureAlgorithm = signatureAlgorithm
        self.fingerprintSHA256 = fingerprintSHA256
    }
}
