import Foundation
import XCTest
import ProxyMirrorFoundation

final class ProxyConnectionDetailsTests: XCTestCase {
    func testSessionWrittenBeforeTLSCaptureStillDecodes() throws {
        let json = Data(#"{"address":"203.0.113.7","dnsMilliseconds":3,"tcpMilliseconds":8,"alpn":"h2","reused":true,"downstreamStream":1,"upstreamStream":3}"#.utf8)
        let details = try JSONDecoder().decode(ProxyConnectionDetails.self, from: json)
        XCTAssertEqual(details.address, "203.0.113.7")
        XCTAssertEqual(details.alpn, "h2")
        XCTAssertEqual(details.downstreamStream, 1)
        XCTAssertTrue(details.reused)
        XCTAssertNil(details.tlsVersion)
        XCTAssertNil(details.clientTLSVersion)
        XCTAssertNil(details.serverCertificate)
    }

    func testTLSCaptureSurvivesPersistenceAndConnectionReuse() throws {
        let certificate = TLSCertificateDetails(der: Data([0, 128, 255]), subject: "CN=example.test",
            issuer: "CN=Fixture CA", validFrom: Date(timeIntervalSince1970: 100),
            validUntil: Date(timeIntervalSince1970: 200), subjectAlternativeNames: ["example.test"],
            publicKey: "P256.PublicKey", signatureAlgorithm: "ECDSA with SHA-256", fingerprintSHA256: "12:34")
        var details = ProxyConnectionDetails(address: "203.0.113.7", alpn: "h2", tlsVersion: "TLS 1.3",
            clientTLSVersion: "TLS 1.2", serverCertificate: certificate)
        details.reused = true
        details.upstreamStream = 5
        let roundTrip = try JSONDecoder().decode(ProxyConnectionDetails.self, from: JSONEncoder().encode(details))
        XCTAssertEqual(roundTrip, details)
        XCTAssertEqual(roundTrip.serverCertificate?.der, Data([0, 128, 255]))
        XCTAssertEqual(roundTrip.serverCertificate?.subjectAlternativeNames, ["example.test"])
    }

    func testPlainHTTPDoesNotInventCertificateOrTLSVersion() throws {
        let details = ProxyConnectionDetails(address: "203.0.113.9", tcpMilliseconds: 4)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(details)) as? [String: Any])
        XCTAssertNil(object["tlsVersion"])
        XCTAssertNil(object["clientTLSVersion"])
        XCTAssertNil(object["serverCertificate"])
    }
}
