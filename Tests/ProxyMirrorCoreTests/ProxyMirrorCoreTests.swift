import Foundation
import XCTest
import ProxyMirrorCoreChecks

final class ProxyMirrorCoreTests: XCTestCase {
    func testHTTPMessages() throws { try runWithMainRunLoop(.httpMessages) }
    func testRules() async throws { try await run(.rules) }
    func testTrafficStore() throws { try runWithMainRunLoop(.trafficStore) }
    func testComposeAndPersistence() async throws { try await run(.composeAndPersistence) }
    func testSettings() async throws { try await run(.settings) }
    func testGRPC() async throws { try await run(.grpc) }
    func testCapture() async throws { try await run(.capture) }

    func testContentCoding() async throws { try await run(.contentCoding) }
    func testDeviceAutomation() async throws { try await run(.deviceAutomation) }
    func testSSE() async throws { try await run(.sse) }
    func testMessagePack() async throws { try await run(.messagePack) }
    func testWSInterception() throws { try runWithMainRunLoop(.wsInterception) }
    func testCertificates() async throws { try await run(.certificates) }
    func testCharlesImport() async throws { try await run(.charlesImport) }

    // The capture tests pump a main RunLoop and the worker lives beside SelfTest.
    private func runWithMainRunLoop(_ group: CoreCheckGroup) throws {
        let tests = Bundle(for: Self.self).bundleURL
        let process = Process()
        process.executableURL = tests.deletingLastPathComponent().appendingPathComponent("ProxyMirrorSelfTest")
        process.arguments = ["--core-unit", group.rawValue]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }

    @MainActor
    private func run(_ group: CoreCheckGroup) throws {
        try group.run { condition, message, file, line in
            XCTAssertTrue(condition, message, file: file, line: line)
        }
    }
}
