import XCTest
@testable import ProxyMirrorFoundation

final class TrafficColumnOrderTests: XCTestCase {
    func testReorderingVisibleColumnsPreservesHiddenSlots() {
        XCTAssertEqual(TrafficColumnOrder.merging(visibleOrder: ["scheme", "url"], previousOrder: ["url", "client", "scheme"]),
                       ["scheme", "client", "url"])
    }

    func testNewColumnsAppendWithoutLosingHiddenOrCustomFields() {
        XCTAssertEqual(TrafficColumnOrder.merging(visibleOrder: ["contentType", "url", "new"], previousOrder: ["url", "custom-id", "contentType"]),
                       ["contentType", "custom-id", "url", "new"])
    }

    func testMalformedDuplicateOrdersRemainUnique() {
        XCTAssertEqual(TrafficColumnOrder.merging(visibleOrder: ["url", "url", "scheme"], previousOrder: ["url", "hidden", "url"]),
                       ["url", "hidden", "scheme"])
    }
}
