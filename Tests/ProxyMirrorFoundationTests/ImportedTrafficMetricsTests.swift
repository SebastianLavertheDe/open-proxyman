import Foundation
import ProxyMirrorFoundation
import XCTest

final class ImportedTrafficMetricsTests: XCTestCase {
    func testHARUnknownAndUnderreportedCountsPreserveCapturedBytes() throws {
        let metrics = try ImportedTrafficMetrics.har(requestBytes: -1, responseBytes: 2,
            capturedRequest: 4, capturedResponse: 8, milliseconds: 125)
        XCTAssertEqual(metrics.requestBytes, 4)
        XCTAssertEqual(metrics.responseBytes, 8)
        XCTAssertEqual(metrics.durationSeconds, 0.125)
        XCTAssertEqual(try ImportedTrafficMetrics.har(requestBytes: nil, responseBytes: nil,
            capturedRequest: 0, capturedResponse: 0, milliseconds: -1).durationSeconds, 0)
    }

    func testImportRejectsOverflowAndNegativeCountsWithoutAllocatingBodies() {
        XCTAssertThrowsError(try ImportedTrafficMetrics.har(requestBytes: Int.max, responseBytes: Int.max,
            capturedRequest: 0, capturedResponse: 0, milliseconds: 0))
        XCTAssertThrowsError(try ImportedTrafficMetrics.har(requestBytes: -2, responseBytes: 0,
            capturedRequest: 0, capturedResponse: 0, milliseconds: 0))
        XCTAssertThrowsError(try ImportedTrafficMetrics(requestBytes: -1, responseBytes: 0, durationSeconds: 0))
        XCTAssertThrowsError(try ImportedTrafficMetrics(requestBytes: Int.max, responseBytes: 0,
            capturedResponse: 1, durationSeconds: 0))
        XCTAssertNoThrow(try ImportedTrafficMetrics(requestBytes: Int.max, responseBytes: 0, durationSeconds: 0))
    }

    func testDurationCannotOverflowDisplayMilliseconds() throws {
        for value in [Double.infinity, -.infinity, .nan, -1, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try ImportedTrafficMetrics(requestBytes: 0, responseBytes: 0, durationSeconds: value))
        }
        let maximum = ImportedTrafficMetrics.maximumDurationSeconds
        let metrics = try ImportedTrafficMetrics(requestBytes: 0, responseBytes: 0, durationSeconds: maximum)
        XCTAssertGreaterThanOrEqual(Int((metrics.durationSeconds * 1000).rounded()), 0)
        XCTAssertThrowsError(try ImportedTrafficMetrics.har(requestBytes: 0, responseBytes: 0,
            capturedRequest: 0, capturedResponse: 0, milliseconds: Double.greatestFiniteMagnitude))
    }

    func testDefensiveTotalSaturatesAndNormalizesInvalidNegativeCounters() {
        XCTAssertEqual(ImportedTrafficMetrics.saturatingTotal(Int.max, Int.max), Int.max)
        XCTAssertEqual(ImportedTrafficMetrics.saturatingTotal(Int.max, 1), Int.max)
        XCTAssertEqual(ImportedTrafficMetrics.saturatingTotal(-1, 10), 10)
        XCTAssertEqual(ImportedTrafficMetrics.saturatingTotal(4, 8), 12)
    }
}
