import Foundation
import Crypto
import X509
import NIOCore
import NIOEmbedded
import NIOSSL

@main enum Checks {
    static func main() throws {
        let key = P256.Signing.PrivateKey()
        let subject = try DistinguishedName { CommonName("leaf.test") }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let certificate = try Certificate(version: .v3, serialNumber: .init(bytes: [1]),
            publicKey: Certificate.PublicKey(key.publicKey), notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(3600), issuer: subject, subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256, extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(digitalSignature: true, keyCertSign: true))
                SubjectAlternativeNames([.dnsName("leaf.test")])
            }, issuerPrivateKey: Certificate.PrivateKey(key))
        let pem = try certificate.serializeAsPEM().pemString
        let peer = try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem)
        let summary = try TLSConnectionMetadata.certificateDetails(peer)
        precondition(summary.subject.contains("leaf.test"))
        precondition(summary.subjectAlternativeNames.contains { $0.contains("leaf.test") })
        precondition(summary.validFrom == certificate.notValidBefore)
        precondition(summary.validUntil == certificate.notValidAfter)
        precondition(summary.publicKey == "P256.PublicKey")
        let observedDER = try Data(peer.toDERBytes())
        precondition(summary.der == observedDER)
        let publicMaterial = try PublicCertificateData(Data((key.pemRepresentation + "\n" + pem).utf8))
        precondition(publicMaterial.leafDER == observedDER)
        precondition(!String(decoding: publicMaterial.chainPEM, as: UTF8.self).contains("PRIVATE KEY"))
        let publicDER = try PublicCertificateData(observedDER)
        precondition(publicDER.leafDER == observedDER)
        let reparsed = try NIOSSLCertificate.fromPEMBytes(Array(publicMaterial.chainPEM))
        precondition(reparsed.count == 1)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)
        let serverContext = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: [.certificate(peer)], privateKey: .privateKey(privateKey)))
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([peer])
        let clientContext = try NIOSSLContext(configuration: clientConfig)
        let loop = EmbeddedEventLoop()
        let server = EmbeddedChannel(loop: loop)
        let client = EmbeddedChannel(loop: loop)
        try server.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverContext))
        try client.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: clientContext, serverHostname: "leaf.test"))
        let connected = client.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 443))
        var connectionResult: Result<Void, Error>?
        connected.whenComplete { connectionResult = $0 }
        server.pipeline.fireChannelActive()
        for _ in 0..<100 {
            loop.run()
            var progressed = false
            while let bytes = try client.readOutbound(as: IOData.self) {
                _ = try server.writeInbound(bytes)
                progressed = true
            }
            while let bytes = try server.readOutbound(as: IOData.self) {
                _ = try client.writeInbound(bytes)
                progressed = true
            }
            if !progressed { break }
        }
        precondition(connectionResult != nil, "Verified TLS handshake must finish while transferring the records")
        try connectionResult?.get()
        var captured = ProxyConnectionDetails()
        TLSConnectionMetadata.captureUpstream(on: client, into: &captured)
        precondition(captured.tlsVersion == "TLS 1.3" || captured.tlsVersion == "TLS 1.2")
        precondition(captured.serverCertificate?.der == summary.der)
        precondition(TLSConnectionMetadata.clientVersion(on: server) == captured.tlsVersion)
        print("TLS metadata: public-only PEM/DER, certificate metadata and verified in-memory handshake passed")
        // Tear down the fixture transport directly; TLS close_notify itself is
        // outside this check and would need another record-transfer round.
        try client.pipeline.syncOperations.context(handlerType: NIOSSLClientHandler.self).close(promise: nil)
        try server.pipeline.syncOperations.context(handlerType: NIOSSLServerHandler.self).close(promise: nil)
        _ = try? client.finish(acceptAlreadyClosed: true)
        _ = try? server.finish(acceptAlreadyClosed: true)
    }
}
