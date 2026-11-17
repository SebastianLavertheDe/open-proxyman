import Foundation
import XCTest
@_spi(Transport) @testable import ProxyMirrorBridgeKit

final class BridgeWireTests: XCTestCase {
    func testRoundTripAndAuthentication() throws {
        let pairing = BridgeWire.Pairing()
        let client = try BridgeWire.Pairing(code: pairing.code)
        XCTAssertEqual(client.name, pairing.name)
        let url = try XCTUnwrap(URL(string: "https://fixture.test:8443/path?q=1"))
        let header = BridgeWire.Header(app: "fixture.app", device: "Fixture",
                                       url: url, method: "POST", startedAt: Date(), duration: 0.125,
                                       status: 201, error: nil, requestHeaders: [], responseHeaders: [],
                                       requestBytes: 3, responseBytes: 12, requestStreamed: false,
                                       requestLength: 3, responseLength: 2)
        let capture = BridgeWire.Capture(header: header, request: Data([0, 1, 255]), response: Data([8, 9]))
        let frame = try BridgeWire.encode(capture, pairing: client)
        XCTAssertEqual(BridgeWire.length(frame.prefix(4)), frame.count - 4)
        let encrypted = Data(frame.dropFirst(4))
        let decoded = try BridgeWire.decode(encrypted, pairing: pairing)
        XCTAssertEqual(decoded.header.url, url)
        XCTAssertEqual(decoded.header.responseBytes, 12)
        XCTAssertEqual(decoded.request, capture.request)
        XCTAssertEqual(decoded.response, capture.response)
        XCTAssertThrowsError(try BridgeWire.decode(encrypted, pairing: .init()))
        XCTAssertThrowsError(try BridgeWire.decode(Data(encrypted.dropLast()), pairing: pairing))
        XCTAssertThrowsError(try BridgeWire.Pairing(code: "invalid"))
        var corrupted = encrypted
        corrupted[corrupted.count - 1] ^= 1
        XCTAssertThrowsError(try BridgeWire.decode(corrupted, pairing: pairing))
    }
}
