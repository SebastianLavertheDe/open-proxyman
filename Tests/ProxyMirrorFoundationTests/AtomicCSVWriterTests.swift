import Foundation
import XCTest
import ProxyMirrorFoundation

final class AtomicCSVWriterTests: XCTestCase {
    private let style = AtomicCSVWriter.DateStyle(uses24HourClock: true, includesDate: true,
        timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pm-csv-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func row(_ url: String = "https://example.test/a,\"b\"\n中文") -> CSVExportRecord {
        CSVExportRecord(method: "GET", status: 200, url: url, contentType: "application/json", size: 12,
                        duration: 0.125, startedAt: Date(timeIntervalSince1970: 0))
    }

    func testQuotesUnicodeAndChunksAreWrittenAsAnAtomicPrivateFile() throws {
        let directory = try directory(), destination = directory.appendingPathComponent("flows.csv")
        try Data("old export".utf8).write(to: destination)
        let large = String(repeating: "边界,\"\n", count: 20_000)
        try AtomicCSVWriter.write([row(), row(large)], to: destination, dateStyle: style)
        let text = try String(contentsOf: destination, encoding: .utf8)
        let header = "\"Method\",\"Status\",\"URL\",\"Content Type\",\"Size\",\"Duration(ms)\",\"Start Time\"\n"
        func expected(_ url: String) -> String {
            "\"GET\",\"200\",\"\(url.replacingOccurrences(of: "\"", with: "\"\""))\",\"application/json\",\"12\",\"125\",\"1970-01-01 00:00:00.000 +00:00\"\n"
        }
        XCTAssertEqual(text, header + expected(row().url) + expected(large))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["flows.csv"])
    }

    func testCancellationBeforeCommitPreservesExistingTargetAndCleansTemporaryFile() throws {
        let directory = try directory(), destination = directory.appendingPathComponent("flows.csv")
        let original = Data("preserve this existing export".utf8)
        try original.write(to: destination)
        let cancellation = WorkCancellation()
        let rows = Array(repeating: row(), count: 5_000)
        XCTAssertThrowsError(try AtomicCSVWriter.write(rows, to: destination, dateStyle: style, cancellation: cancellation) { completed in
            if completed >= 256 { cancellation.cancel() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["flows.csv"])
    }

    func testCancellationAtFinalProgressCannotCommitAndWriteFailuresPropagate() throws {
        let directory = try directory(), destination = directory.appendingPathComponent("flows.csv")
        let cancellation = WorkCancellation()
        XCTAssertThrowsError(try AtomicCSVWriter.write([row()], to: destination, dateStyle: style, cancellation: cancellation) { completed in
            if completed == 1 { cancellation.cancel() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertThrowsError(try AtomicCSVWriter.write([row()], to: directory.appendingPathComponent("missing/flows.csv"), dateStyle: style))
        XCTAssertThrowsError(try AtomicCSVWriter.write([row()], to: directory, dateStyle: style))
    }

    func testBackgroundWriterReportsProgressForLargeSnapshot() throws {
        let destination = try directory().appendingPathComponent("flows.csv")
        let finished = expectation(description: "background CSV")
        let rows = Array(repeating: row("https://example.test/"), count: 10_000)
        let style = style
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var completed = 0
                try AtomicCSVWriter.write(rows, to: destination, dateStyle: style) { value in
                    XCTAssertFalse(Thread.isMainThread)
                    XCTAssertGreaterThanOrEqual(value, completed); completed = value
                }
                XCTAssertEqual(completed, rows.count)
            } catch { XCTFail("background write failed: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }
}
