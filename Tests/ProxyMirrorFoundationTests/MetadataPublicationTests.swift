import Foundation
import ProxyMirrorFoundation
import XCTest

final class MetadataPublicationTests: XCTestCase {
    private final class Value {
        var events: [String] = []
        var observed = false
        func change(_ event: String) {
            if observed { XCTAssertTrue(Thread.isMainThread, "Published metadata must be committed on main") }
            events.append(event)
        }
    }

    func testDraftThenPublishedUpdatesStayOrderedAndMoveToMain() {
        let completed = expectation(description: "all published updates applied")
        let value = Value()
        let publication = MetadataPublication(value)
        DispatchQueue.global().async {
            publication.update { $0.change("draft") }
            publication.publish {
                XCTAssertTrue(Thread.isMainThread)
                $0.observed = true
                $0.change("publish")
            }
            for event in ["sni-rejection", "local-response", "websocket-completion", "sse-completion", "cancelled"] {
                publication.update { $0.change(event) }
            }
            publication.publish { _ in XCTFail("A transaction cannot be published twice") }
            publication.update { _ in completed.fulfill() }
        }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(value.events, ["draft", "publish", "sni-rejection", "local-response", "websocket-completion", "sse-completion", "cancelled"])
    }

    func testMainThreadPublicationKeepsSynchronousEmbeddedHandlers() {
        XCTAssertTrue(Thread.isMainThread)
        let value = Value()
        let publication = MetadataPublication(value)
        publication.publish { $0.observed = true; $0.change("publish") }
        publication.update { $0.change("update") }
        XCTAssertEqual(value.events, ["publish", "update"])
    }
}
