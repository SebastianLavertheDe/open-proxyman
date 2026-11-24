import Foundation

/// The XCTest target and CLT executable run the same cases.
package enum CoreCheckGroup: String, CaseIterable, Sendable {
    case httpMessages, rules, trafficStore, composeAndPersistence, trafficMenu, settings, grpc, capture, contentCoding, deviceAutomation, sse, messagePack, wsInterception, certificates, bridge, charlesImport

    @MainActor
    package func run(_ report: @escaping (Bool, String, StaticString, UInt) -> Void) throws {
        let assertions = CoreAssertions(report: report)
        switch self {
        case .httpMessages: try assertions.run("checkHTTPMessages") { try checkHTTPMessages(assertions) }
        case .rules:
            try assertions.run("checkRules") { try checkRules(assertions) }
            try assertions.run("checkPendingSaves") { try checkPendingSaves(assertions) }
            try assertions.run("checkCustomCertificateBackup") { try checkCustomCertificateBackup(assertions) }
            try assertions.run("checkTunnelRuleEnforcement") { try checkTunnelRuleEnforcement(assertions) }
            try assertions.run("checkWorkbench") { try checkWorkbench(assertions) }
        case .trafficStore:
            try assertions.run("checkTrafficStore") { try checkTrafficStore(assertions) }
            try assertions.run("checkDerivedColumns") { try checkDerivedColumns(assertions) }
        case .composeAndPersistence:
            try assertions.run("checkComposeAndPersistence") { try checkComposeAndPersistence(assertions) }
            try assertions.run("checkExportInteractions") { try checkExportInteractions(assertions) }
            try assertions.run("checkDomainLogImport") { try checkDomainLogImport(assertions) }
        case .trafficMenu: try assertions.run("checkTrafficMenu") { try checkTrafficMenu(assertions) }
        case .settings:
            try assertions.run("checkSettings") { checkSettings(assertions) }
            try assertions.run("checkLocalization") { try checkLocalization(assertions) }
            try assertions.run("checkLocalizationStorage") { try checkLocalizationStorage(assertions) }
            try assertions.run("checkLocalizationModelStorage") { try checkLocalizationModelStorage(assertions) }
            try assertions.run("checkToolLocalization") { checkToolLocalization(assertions) }
            try assertions.run("checkPresentationSettings") { try checkPresentationSettings(assertions) }
            try assertions.run("checkSettingsRuntime") { try checkSettingsRuntime(assertions) }
            try assertions.run("checkUpdateConfiguration") { try checkUpdateConfiguration(assertions) }
            try assertions.run("checkReleaseUpdates") { try checkReleaseUpdates(assertions) }
            try assertions.run("checkDiagnosticHeaders") { try checkDiagnosticHeaders(assertions) }
            try assertions.run("checkMemoryPressure") { try checkMemoryPressure(assertions) }
            try assertions.run("checkPresentationBackup") { try checkPresentationBackup(assertions) }
        case .grpc: try assertions.run("checkGRPC") { try checkGRPC(assertions) }
        case .capture: try assertions.run("checkCapture") { checkCapture(assertions) }
        case .contentCoding:
            try assertions.run("checkContentCoding") { checkContentCoding(assertions) }
            try assertions.run("checkInspectionBodies") { checkInspectionBodies(assertions) }
            try assertions.run("checkDetailInspection") { checkDetailInspection(assertions) }
        case .deviceAutomation:
            try assertions.run("checkDeviceAutomation") { checkDeviceAutomation(assertions) }
            try assertions.run("checkProtocolAutomation") { try checkProtocolAutomation(assertions) }
        case .sse:
            try assertions.run("checkSSE") { checkSSE(assertions) }
            try assertions.run("checkSSEInspection") { try checkSSEInspection(assertions) }
        case .messagePack: try assertions.run("checkMessagePack") { checkMessagePack(assertions) }
        case .wsInterception:
            try assertions.run("checkWSInterception") { try checkWSInterception(assertions) }
            try assertions.run("checkWSCompressedInterception") { checkWSCompressedInterception(assertions) }
        case .certificates:
            try assertions.run("checkCertificates") { try checkCertificates(assertions) }
            try assertions.run("checkCertInstaller") { try checkCertInstaller(assertions) }
        case .bridge: try assertions.run("checkBridge") { try checkBridge(assertions) }
        case .charlesImport: try assertions.run("checkCharlesImport") { try checkCharlesImport(assertions) }
        }
    }
}

struct CoreAssertions {
    let report: (Bool, String, StaticString, UInt) -> Void

    @MainActor
    func run(_ name: String, _ operation: () throws -> Void) throws {
        let started = Date()
        let configured = ProcessInfo.processInfo.environment["PM_CORE_CASE_TIMEOUT"].flatMap(TimeInterval.init) ?? 90
        let timeout = configured.isFinite ? max(1, min(600, configured)) : 90
        func progress(_ text: String) {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
        progress("CORE CASE START \(name)")
        let deadline = DispatchWorkItem {
            FileHandle.standardError.write(Data("CORE CASE TIMEOUT \(name) after \(timeout)s\n".utf8))
            // These checks run in an isolated worker. A stuck native callback
            // must fail that worker instead of hanging the entire XCTest job.
            exit(124)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        do {
            try operation()
            progress("CORE CASE END \(name) (\(String(format: "%.3f", Date().timeIntervalSince(started)))s)")
        } catch {
            progress("CORE CASE ERROR \(name): \(error)")
            throw error
        }
    }

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
