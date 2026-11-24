import Foundation
import ProxyMirrorFoundation
import XCTest

final class BoundedDiffDocumentTests: XCTestCase {
    private let messages = BoundedDiffDocument.Messages(unavailable: "unavailable", bodyLimited: "body limit",
                                                      linesLimited: "line limit", outputLimited: "byte limit")

    func testBinaryFormattingStopsAtTheLineBudget() throws {
        let input = BoundedDiffDocument.Input(includesBody: true, body: Data(repeating: 255, count: 262_144))
        let lines = try BoundedDiffDocument.lines(input, sortJSON: false, sortHeaders: false, messages: messages)
        XCTAssertEqual(lines.count, 1201)
        XCTAssertEqual(lines.first, "00000000  " + Array(repeating: "ff", count: 16).joined(separator: " "))
        XCTAssertEqual(lines[1199].prefix(8), "00004af0")
        XCTAssertEqual(lines.last, "line limit")
        XCTAssertLessThan(lines.joined(separator: "\n").utf8.count, 80_000)
    }

    func testJSONAndHeaderOrderingPreserveComparisonSemantics() throws {
        let input = BoundedDiffDocument.Input(startLine: "HTTP/2 200", headers: [.init("Z", "last"), .init("A", "first")],
            includesBody: true, body: Data(#"{"z":2,"a":1}"#.utf8))
        let lines = try BoundedDiffDocument.lines(input, sortJSON: true, sortHeaders: true, messages: messages)
        XCTAssertEqual(Array(lines.prefix(4)), ["HTTP/2 200", "A: first", "Z: last", ""])
        XCTAssertLessThan(lines.firstIndex(where: { $0.contains("\"a\"") })!, lines.firstIndex(where: { $0.contains("\"z\"") })!)
        let unavailable = try BoundedDiffDocument.lines(.init(includesBody: true), sortJSON: false, sortHeaders: false, messages: messages)
        XCTAssertEqual(unavailable, ["unavailable"])
    }

    func testLongHeaderOutputHasAByteBudgetAndValidUnicode() throws {
        let input = BoundedDiffDocument.Input(headers: [.init("X", String(repeating: "界", count: 400_000))], includesBody: false)
        let lines = try BoundedDiffDocument.lines(input, sortJSON: false, sortHeaders: false, messages: messages)
        XCTAssertEqual(lines.last, "byte limit")
        XCTAssertFalse(lines[0].contains("\u{FFFD}"))
        XCTAssertLessThanOrEqual(lines[0].utf8.count, BoundedDiffDocument.outputLimit)
    }

    func testCancelledFormattingDoesNotReturnPartialDocuments() async {
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let messages = messages
        let worker = Task.detached {
            entered.signal(); resume.wait()
            return try BoundedDiffDocument.lines(.init(includesBody: true, body: Data(repeating: 255, count: 262_144)),
                                                 sortJSON: false, sortHeaders: false, messages: messages)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        worker.cancel(); resume.signal()
        switch await worker.result {
        case .success: XCTFail("Cancelled formatting returned a document")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }
}
