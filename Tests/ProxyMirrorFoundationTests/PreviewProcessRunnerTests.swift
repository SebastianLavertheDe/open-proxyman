import Foundation
import XCTest
import ProxyMirrorFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class PreviewProcessRunnerTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pm-preview-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func worker(_ directory: URL, name: String = UUID().uuidString, source: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + source).write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }; Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func testInputAndOutputUseTheProductionRunner() throws {
        let worker = try worker(directory(), source: "cat\n")
        let input = Data("{\"preview\":\"内容\"}".utf8)
        XCTAssertEqual(try PreviewProcessRunner.run(executable: worker, input: input), input)
    }

    func testTimeoutAndOutputLimitStopWorkersAndReleaseSlots() throws {
        let directory = try directory()
        let hung = try worker(directory, source: "trap '' TERM\nwhile :; do sleep 1; done\n")
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PreviewProcessRunner.run(executable: hung, input: Data(), timeout: 0.05)) {
            guard case PreviewProcessRunner.Failure.timedOut = $0 else { return XCTFail("wrong failure: \($0)") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let flood = try worker(directory, source: "while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done\n")
        XCTAssertThrowsError(try PreviewProcessRunner.run(executable: flood, input: Data(), outputLimit: 1024)) {
            guard case PreviewProcessRunner.Failure.outputLimit = $0 else { return XCTFail("wrong failure: \($0)") }
        }
        let success = try worker(directory, source: "printf 'latest'\n")
        XCTAssertEqual(try PreviewProcessRunner.run(executable: success, input: Data()), Data("latest".utf8))
    }

    func testCancelledRunningAndWaitingPreviewsLeaveLatestRequestRunnable() throws {
        let directory = try directory()
        let cancellations = [WorkCancellation(), WorkCancellation()]
        let finished = expectation(description: "cancelled running previews"); finished.expectedFulfillmentCount = 2
        for index in 0..<2 {
            let pidFile = directory.appendingPathComponent("pid-\(index)")
            let executable = try worker(directory, source: "trap '' TERM\nprintf '%s' $$ > '\(pidFile.path)'\nwhile :; do sleep 1; done\n")
            let cancellation = cancellations[index]
            DispatchQueue.global().async {
                do {
                    _ = try PreviewProcessRunner.run(executable: executable, input: Data(), timeout: 5, cancellation: cancellation)
                    XCTFail("cancelled worker returned output")
                } catch { XCTAssertTrue(error is CancellationError, "unexpected running-worker failure: \(error)") }
                finished.fulfill()
            }
        }
        XCTAssertTrue(eventually { (0..<2).allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid-\($0)").path) } })
        let success = try worker(directory, source: "printf 'latest'\n")
        let waiting = WorkCancellation()
        let cancelledWaiter = expectation(description: "waiting preview cancellation")
        DispatchQueue.global().async {
            do {
                _ = try PreviewProcessRunner.run(executable: success, input: Data(), cancellation: waiting)
                XCTFail("cancelled waiting worker ran")
            } catch { XCTAssertTrue(error is CancellationError) }
            cancelledWaiter.fulfill()
        }
        waiting.cancel()
        wait(for: [cancelledWaiter], timeout: 0.5)
        cancellations.forEach { $0.cancel() }
        wait(for: [finished], timeout: 2)
        for index in 0..<2 {
            let pid = Int32(try String(contentsOf: directory.appendingPathComponent("pid-\(index)")))!
            var status: Int32 = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD, "runner must reap its process before returning its slot")
        }
        XCTAssertEqual(try PreviewProcessRunner.run(executable: success, input: Data()), Data("latest".utf8))
    }
}
