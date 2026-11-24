import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import ProxyMirrorCoreChecks

final class ProxyMirrorCoreTests: XCTestCase {
    func testHTTPMessages() throws { try runWithMainRunLoop(.httpMessages) }
    func testRules() throws { try runWithMainRunLoop(.rules) }
    func testTrafficStore() throws { try runWithMainRunLoop(.trafficStore) }
    func testComposeAndPersistence() throws { try runWithMainRunLoop(.composeAndPersistence) }
    func testTrafficMenu() throws { try runWithMainRunLoop(.trafficMenu) }
    func testSettings() throws { try runWithMainRunLoop(.settings) }
    func testGRPC() throws { try runWithMainRunLoop(.grpc) }
    func testCapture() throws { try runWithMainRunLoop(.capture) }

    func testContentCoding() throws { try runWithMainRunLoop(.contentCoding) }
    func testDeviceAutomation() throws { try runWithMainRunLoop(.deviceAutomation) }
    func testSSE() throws { try runWithMainRunLoop(.sse) }
    func testMessagePack() throws { try runWithMainRunLoop(.messagePack) }
    func testWSInterception() throws { try runWithMainRunLoop(.wsInterception) }
    func testCertificates() throws { try runWithMainRunLoop(.certificates) }
    func testCharlesImport() throws { try runWithMainRunLoop(.charlesImport) }

    // Each group owns a process main thread and a real main RunLoop. Running
    // these synchronous native checks inside XCTest's MainActor can starve
    // callbacks, and an unbounded pipe read hides which case stopped making progress.
    private func runWithMainRunLoop(_ group: CoreCheckGroup) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-xctest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("worker.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let writer = try FileHandle(forWritingTo: log)
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? writer.close(); try? reader.close() }
        let process = Process()
        let tests = Bundle(for: Self.self).bundleURL
        let fallback = tests.deletingLastPathComponent().appendingPathComponent("ProxyMirrorSelfTest")
        process.executableURL = ProcessInfo.processInfo.environment["PM_SELFTEST_BIN"].map(URL.init(fileURLWithPath:)) ?? fallback
        process.arguments = ["--core-unit", group.rawValue]
        var environment = ProcessInfo.processInfo.environment
        environment["PM_SUPPORT_DIR"] = directory.appendingPathComponent("support").path
        process.environment = environment
        process.standardOutput = writer
        process.standardError = writer
        let configured = environment["PM_CORE_GROUP_TIMEOUT"].flatMap(TimeInterval.init) ?? 300
        let timeout = configured.isFinite ? max(1, min(900, configured)) : 300
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        func drain() {
            let next = reader.readDataToEndOfFile() // regular file: never waits for writer EOF
            output.append(next)
            FileHandle.standardError.write(next)
        }
        FileHandle.standardError.write(Data("CORE GROUP START \(group.rawValue)\n".utf8))
        try process.run()
        while process.isRunning && Date() < deadline {
            drain()
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            drain()
            XCTFail("Core group \(group.rawValue) exceeded \(timeout)s. Last worker output:\n" + String(decoding: output.suffix(32_768), as: UTF8.self))
            return
        }
        process.waitUntilExit()
        drain()
        FileHandle.standardError.write(Data("CORE GROUP END \(group.rawValue) status=\(process.terminationStatus)\n".utf8))
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output.suffix(32_768), as: UTF8.self))
    }
}
