import Foundation
import ProxyMirrorFoundation
import XCTest

final class CorePoliciesTests: XCTestCase {
    func testHTTPFramingUsesOneBoundaryAndRejectsAmbiguity() throws {
        for fields in ["Content-Length: 1\r\nContent-Length: 2", "Content-Length: +1",
                       "Transfer-Encoding: chunked\r\nContent-Length: 0", "Transfer-Encoding: chunked, gzip"] {
            XCTAssertThrowsError(try RequestHeadParser.parse("POST / HTTP/1.1\r\nHost: fixture.test\r\n" + fields))
        }
        var request = try RequestHeadParser.parse("POST / HTTP/1.1\r\nContent-Length: 5, 05\r\nContent-Length: 5")
        XCTAssertEqual(request.headers.values(of: "Content-Length"), ["5"])
        XCTAssertEqual(try HTTPFraming.request(&request), .fixed(5))
        let wire = try sanitizedRequestHead(head: request, originFormTarget: "/", keepAlive: true)
        var parser = RequestHeadParser()
        XCTAssertEqual(try parser.feed(wire)?.headers.value(of: "Content-Length"), "5")
    }

    func testAbsoluteAuthorityOverridesHostAndPreservesIPv6() throws {
        let request = try RequestHeadParser.parse("GET https://[::1]:9443/x HTTP/1.1\r\nHost: other.test")
        XCTAssertEqual(request.headers.value(of: "Host"), "[::1]:9443")
        XCTAssertThrowsError(try RequestHeadParser.parse("GET http://user:secret@fixture.test/x HTTP/1.1"))
        var response = ResponseHeadParser()
        let head = try response.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 2,2\r\n\r\nokNEXT".utf8))
        XCTAssertEqual(head?.headers.value(of: "Content-Length"), "2")
        XCTAssertEqual(response.trailing, Array("okNEXT".utf8))
    }

    func testUploadAndSSEHaveDistinctProgressDeadlines() {
        var policy = HTTPTransferTimeoutPolicy(interval: 30, now: 0)
        policy.uploaded(at: 45)
        XCTAssertEqual(policy.deadline(requestPending: true, responseStarted: false, eventStream: false), 75)
        XCTAssertEqual(policy.deadline(requestPending: false, responseStarted: false, eventStream: false), 75)
        policy.downloaded(at: 60)
        XCTAssertEqual(policy.deadline(requestPending: false, responseStarted: true, eventStream: false), 90)
        XCTAssertNil(policy.deadline(requestPending: false, responseStarted: true, eventStream: true))
    }

    func testPendingSaveFlushesLatestStateAndRetainsFailedWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state")
        var current = "first", fail = false, commits = 0
        let save = PendingSave(commit: {
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try Data(current.utf8).write(to: file, options: .atomic)
            commits += 1
        }, reportFailure: { _ in XCTFail("An explicit flush must return its error") })
        save.schedule()
        current = "latest"
        save.schedule()
        try save.flush()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "latest")
        XCTAssertFalse(save.hasChanges)
        try save.flush()
        XCTAssertEqual(commits, 1)
        fail = true
        save.schedule()
        XCTAssertThrowsError(try save.flush())
        XCTAssertTrue(save.hasChanges)
        fail = false
        current = "retry"
        try save.flush()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "retry")
    }

    func testRegexBudgetStopsTheEngineAndQuarantinesOnlyExhaustion() throws {
        let ordinary = try BoundedTrafficRegex(pattern: "^hello$", options: [.caseInsensitive])
        XCTAssertEqual(ordinary.matchesAny(in: ["HELLO"]), true)
        XCTAssertEqual(ordinary.matchesAny(in: ["other"]), false)
        let regex = try BoundedTrafficRegex(pattern: "(a+)+$", maximumDuration: 0.004)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(regex.matchesAny(in: [String(repeating: "a", count: 48) + "!"]))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        XCTAssertNil(regex.matchesAny(in: ["a"]))
    }

    func testDeviceCommandsDrainBothOutputsAndStopAtDeadline() throws {
        let output = try DeviceCommandRunner.run("/bin/sh", ["-c", "head -c 262144 /dev/zero >&2; printf done"], timeout: 3)
        XCTAssertEqual(output.stdout, "done")
        XCTAssertEqual(output.stderr.utf8.count, 262144)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try DeviceCommandRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 60"], timeout: 0.05)) { error in
            XCTAssertEqual(error as? DeviceCommandRunner.Failure, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        let cancellation = DeviceCommandRunner.Cancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try DeviceCommandRunner.run("/bin/sh", ["-c", "exit 0"], cancellation: cancellation)) { error in
            XCTAssertEqual(error as? DeviceCommandRunner.Failure, .cancelled)
        }
    }
}
