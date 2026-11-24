import Foundation
import ProxyMirrorFoundation
import XCTest

final class JSONHighlightPlanTests: XCTestCase {
    func testUTF16SpansKeepUnicodeAndEscapedStringsIntact() throws {
        let text = #"{"😀":"汉\"字","number":-1.2e+3,"flag":true,"nothing":null}"#
        let plan = try XCTUnwrap(JSONHighlightPlan.make(text))
        XCTAssertFalse(plan.limited)
        let source = text as NSString
        let tokens = plan.spans.map { (source.substring(with: NSRange(location: $0.offset, length: $0.length)), $0.kind) }
        XCTAssertTrue(tokens.contains { $0.0 == #""😀""# && $0.1 == .key })
        XCTAssertTrue(tokens.contains { $0.0 == #""汉\"字""# && $0.1 == .string })
        XCTAssertTrue(tokens.contains { $0.0 == "-1.2e+3" && $0.1 == .number })
        XCTAssertTrue(tokens.contains { $0.0 == "true" && $0.1 == .constant })
        XCTAssertTrue(tokens.contains { $0.0 == "null" && $0.1 == .constant })
        var end = 0
        for span in plan.spans {
            XCTAssertGreaterThanOrEqual(span.offset, end)
            XCTAssertGreaterThan(span.length, 0)
            XCTAssertLessThanOrEqual(span.offset + span.length, source.length)
            end = span.offset + span.length
        }
    }

    func testDenseJSONUsesBoundedRunsInsteadOfConstructingEveryAttributedToken() throws {
        let text = "[" + Array(repeating: "1", count: 32_000).joined(separator: ",") + "]"
        let started = ProcessInfo.processInfo.systemUptime
        let plan = try XCTUnwrap(JSONHighlightPlan.make(text))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertTrue(plan.limited)
        XCTAssertTrue(plan.spans.isEmpty, "A run-limited document falls back to one plain text storage")
        XCTAssertLessThan(elapsed, 2, "Dense token planning must not repeat AttributedString concatenations")
        print("JSON highlight: \(text.utf8.count) bytes, \(plan.spans.count) spans, \(elapsed)s")
        let oversized = String(repeating: "😀", count: JSONHighlightPlan.maximumInputBytes / 4 + 1)
        XCTAssertTrue(try XCTUnwrap(JSONHighlightPlan.make(oversized)).limited)
    }

    func testCancellationIsObservedInsideEscapesNumbersAndKeyWhitespace() {
        for text in ["\"" + String(repeating: "\\n", count: 40_000) + "\"",
                     String(repeating: "1", count: 80_000),
                     "\"key\"" + String(repeating: " ", count: 80_000) + ":1"] {
            let cancellation = CancelAfter(3)
            XCTAssertNil(JSONHighlightPlan.make(text, cancelled: cancellation.check))
            XCTAssertEqual(cancellation.checks, 3, "Cancellation is checked by work count even when escapes advance two UTF-16 units")
        }
        XCTAssertNil(JSONHighlightPlan.make("{}", cancelled: { true }))
    }

    func testWriterStopsOnConsumerBudgetAndKeepsJSONScalarTypes() throws {
        var lines: [String] = []
        let finished = try BoundedJSONWriter.write(["a": [1, 2], "z": String(repeating: "x", count: 100_000)], append: {
            lines.append($0); return lines.count < 2
        })
        XCTAssertFalse(finished)
        XCTAssertEqual(lines.count, 2)
        let original: [String: Any] = ["emoji": "😀\n\t\u{0001}\\\"", "true": true, "zero": 0, "null": NSNull()]
        lines.removeAll()
        XCTAssertTrue(try BoundedJSONWriter.write(original, append: { lines.append($0); return true }))
        let encoded = Data(lines.joined(separator: "\n").utf8)
        let result = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
        XCTAssertEqual(result, original as NSDictionary)
    }

    func testWriterCancellationAndSingleLineLimitAreBounded() {
        let cancellation = CancelAfter(4)
        XCTAssertThrowsError(try BoundedJSONWriter.write([String(repeating: "\\", count: 80_000)], append: { _ in true },
                                                         cancelled: cancellation.check)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try BoundedJSONWriter.write([String(repeating: "x", count: 1000)], maximumLineBytes: 64,
                                                         append: { _ in true })) {
            XCTAssertEqual($0 as? BoundedJSONWriter.Failure, .lineLimit)
        }
    }

    func testPrettyExpansionStopsBeforeAllocatingTheFullIndentedDocument() async throws {
        let renderer = JSONDocumentRenderer()
        let text = String(repeating: "[", count: 128)
            + "[" + Array(repeating: "0", count: 32_000).joined(separator: ",") + "]"
            + String(repeating: "]", count: 128)
        let rendered = await renderer.render(Data(text.utf8), pretty: true)
        let result = try XCTUnwrap(rendered)
        XCTAssertEqual(result.text, text, "Over-budget pretty output preserves the bounded original text")
        XCTAssertNil(result.highlights)
        XCTAssertLessThanOrEqual(result.text.utf8.count, JSONDocumentRenderer.maximumRenderBytes)
    }

    func testRendererBoundsOutputAndKeepsSmallJSONHighlighted() async throws {
        let renderer = JSONDocumentRenderer()
        let renderedSmall = await renderer.render(Data(#"{"z":false,"a":"😀"}"#.utf8), pretty: true)
        let small = try XCTUnwrap(renderedSmall)
        XCTAssertFalse(try XCTUnwrap(small.highlights).limited)
        XCTAssertLessThan(try XCTUnwrap(small.text.range(of: "\"a\"" )).lowerBound,
                          try XCTUnwrap(small.text.range(of: "\"z\"" )).lowerBound)
        let renderedLarge = await renderer.render(Data(repeating: 97, count: JSONDocumentRenderer.maximumRenderBytes + 1), pretty: true)
        let large = try XCTUnwrap(renderedLarge)
        XCTAssertEqual(large.text.utf8.count, JSONDocumentRenderer.maximumRenderBytes)
        XCTAssertTrue(large.truncated)
        XCTAssertNil(large.highlights)
        let invalidUTF8 = await renderer.render(Data(repeating: 255, count: JSONDocumentRenderer.maximumRenderBytes), pretty: false)
        XCTAssertLessThanOrEqual(try XCTUnwrap(invalidUTF8).text.utf8.count, JSONDocumentRenderer.maximumRenderBytes,
                                 "Replacement characters must also fit the output byte budget")
        XCTAssertTrue(try XCTUnwrap(invalidUTF8).truncated)
    }

    func testCancelledRenderQueueLeavesTheLatestDocumentRunnable() async throws {
        let renderer = JSONDocumentRenderer()
        let text = "[" + Array(repeating: "1", count: 32_000).joined(separator: ",") + "]"
        let jobs = (0..<16).map { _ in Task.detached { await renderer.render(Data(text.utf8), pretty: true) } }
        for job in jobs { job.cancel() }
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        for job in jobs { _ = await job.value }
        let renderedLatest = await renderer.render(Data(#"{"latest":1}"#.utf8), pretty: true)
        let latest = try XCTUnwrap(renderedLatest)
        XCTAssertTrue(latest.text.contains("latest"))
        let elapsed = ProcessInfo.processInfo.systemUptime - cancelledAt
        XCTAssertLessThan(elapsed, 2, "Cancelled render work must not accumulate behind memory-pressure replacements")
        print("JSON highlight: cancelled 16 renders and completed latest in \(elapsed)s")
    }
}

private final class CancelAfter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    init(_ limit: Int) { self.limit = limit }
    var checks: Int { lock.withLock { count } }
    func check() -> Bool { lock.withLock { count += 1; return count >= limit } }
}
