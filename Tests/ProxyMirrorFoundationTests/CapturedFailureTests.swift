import Foundation
import XCTest
@testable import ProxyMirrorFoundation

final class CapturedFailureTests: XCTestCase {
    func testIdentityAndForeignDiagnosticsRoundTripWithoutPresentationText() throws {
        let failure = CapturedFailure(code: "network_upstream_connection_failed", arguments: ["curl: 原文 100% %@"],
                                      diagnostic: "Unable to connect to the upstream: curl: 原文 100% %@")
        let bytes = try JSONEncoder().encode(failure)
        XCTAssertEqual(try JSONDecoder().decode(CapturedFailure.self, from: bytes), failure)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["code", "arguments", "diagnostic"])
        XCTAssertEqual(failure.localizedDescription, failure.diagnostic)
    }

    func testUnknownFutureFailureIdentityIsPreserved() throws {
        let source = #"{"code":"future_failure","arguments":["原始参数"],"diagnostic":"foreign failure: 原文"}"#
        let failure = try JSONDecoder().decode(CapturedFailure.self, from: Data(source.utf8))
        XCTAssertEqual(failure.code, "future_failure")
        XCTAssertEqual(failure.arguments, ["原始参数"])
        XCTAssertEqual(failure.diagnostic, "foreign failure: 原文")
        XCTAssertEqual(try JSONDecoder().decode(CapturedFailure.self, from: JSONEncoder().encode(failure)), failure)
    }
}
