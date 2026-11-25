import Foundation
import XCTest
@testable import ProxyMirrorFoundation

final class SessionImportCompatibilityTests: XCTestCase {
    func testPrivatePackagesAndCaseInsensitiveExtensionsNeedConversion() {
        for name in ["capture.proxymanlog", "capture.proxymanlogv2", "capture.PROXYMANSESSION", "capture.proxymansessionv2"] {
            XCTAssertTrue(SessionImportCompatibility.needsProxymanConversion(URL(fileURLWithPath: name)))
        }
    }

    func testExistingSupportedFormatsContinueThroughTheirOwnImporters() {
        for name in ["capture.har", "capture.chls", "capture.chlz", "capture.chlsj", "capture.proxymirror", "proxymanlogv2.json"] {
            XCTAssertFalse(SessionImportCompatibility.needsProxymanConversion(URL(fileURLWithPath: name)))
        }
    }
}
