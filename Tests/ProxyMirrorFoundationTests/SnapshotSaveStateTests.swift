import XCTest
@testable import ProxyMirrorFoundation

final class SnapshotSaveStateTests: XCTestCase {
    func testFailedLatestSnapshotIsRetainedForAnExplicitRetry() {
        var state = SnapshotSaveState<String>()
        XCTAssertFalse(state.hasChanges)
        state.enqueue("unsaved edit")
        XCTAssertEqual(state.beginWrite(), "unsaved edit")
        XCTAssertNil(state.beginWrite(), "Writes cannot overlap")
        XCTAssertEqual(state.completeWrite(succeeded: false), .failed)
        XCTAssertTrue(state.hasChanges)
        XCTAssertFalse(state.isWriting, "A failure does not spin in an automatic retry loop")
        XCTAssertEqual(state.beginWrite(), "unsaved edit", "Quit can retry the failed snapshot")
        XCTAssertEqual(state.completeWrite(succeeded: true), .clean)
        XCTAssertFalse(state.hasChanges)
    }

    func testNewerEditsSupersedeAnOlderFailedWrite() {
        var state = SnapshotSaveState<Int>()
        state.enqueue(1)
        XCTAssertEqual(state.beginWrite(), 1)
        state.enqueue(2)
        state.enqueue(3)
        XCTAssertEqual(state.completeWrite(succeeded: false), .newerSnapshot)
        XCTAssertEqual(state.beginWrite(), 3)
        XCTAssertEqual(state.completeWrite(succeeded: true), .clean)
        XCTAssertFalse(state.hasChanges)
    }

    func testEditDuringQuitRetryMustAlsoBePersisted() {
        var state = SnapshotSaveState<Int>()
        state.enqueue(1)
        _ = state.beginWrite()
        _ = state.completeWrite(succeeded: false)
        XCTAssertEqual(state.beginWrite(), 1)
        state.enqueue(2)
        XCTAssertEqual(state.completeWrite(succeeded: true), .newerSnapshot)
        XCTAssertTrue(state.hasChanges, "An older successful retry cannot declare the latest edit saved")
        XCTAssertEqual(state.beginWrite(), 2)
        XCTAssertEqual(state.completeWrite(succeeded: false), .failed)
        XCTAssertEqual(state.beginWrite(), 2)
        XCTAssertEqual(state.completeWrite(succeeded: true), .clean)
    }
}
