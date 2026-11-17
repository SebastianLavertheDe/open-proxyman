import Foundation

/// The XCTest target and CLT executable run the same cases.
package enum CoreCheckGroup: String, CaseIterable, Sendable {
    case httpMessages, rules, trafficStore, composeAndPersistence, settings, grpc, capture, contentCoding, deviceAutomation, sse, messagePack, wsInterception, certificates, bridge, charlesImport

    @MainActor
    package func run(_ report: @escaping (Bool, String, StaticString, UInt) -> Void) throws {
        let assertions = CoreAssertions(report: report)
        switch self {
        case .httpMessages: try checkHTTPMessages(assertions)
        case .rules: try checkRules(assertions)
        case .trafficStore: try checkTrafficStore(assertions)
        case .composeAndPersistence: try checkComposeAndPersistence(assertions)
        case .settings: checkSettings(assertions)
        case .grpc: try checkGRPC(assertions)
        case .capture: checkCapture(assertions)
        case .contentCoding: checkContentCoding(assertions)
        case .deviceAutomation: checkDeviceAutomation(assertions)
        case .sse: checkSSE(assertions)
        case .messagePack: checkMessagePack(assertions)
        case .wsInterception: checkWSInterception(assertions)
        case .certificates: try checkCertificates(assertions)
        case .bridge: try checkBridge(assertions)
        case .charlesImport: try checkCharlesImport(assertions)
        }
    }
}

struct CoreAssertions {
    let report: (Bool, String, StaticString, UInt) -> Void

    func expect(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        report(condition, message, file, line)
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let matches = actual == expected
        report(matches, matches ? message : "\(message): expected \(expected), got \(actual)", file, line)
    }

    func rejects<T, E: Error>(_ operation: @autoclosure () throws -> T, with expected: E.Type, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try operation()
            report(false, "\(message): expected \(expected)", file, line)
        } catch {
            report(error is E, error is E ? message : "\(message): unexpected error \(error)", file, line)
        }
    }
}

func makeCheckDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-unit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
