import Foundation
import Darwin

/// Explicit simulator operations only: enumerate existing devices and add the
/// current CA to a selected, already booted device. Never boots or deletes a device.
enum SimulatorCertificateInstaller {
    struct Device: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let runtime: String
        let state: String
        var isBooted: Bool { state.caseInsensitiveCompare("Booted") == .orderedSame }
        var localizedState: String {
            switch state.lowercased() {
            case "booted": return Strings.Errors.simulatorStateBooted
            case "shutdown": return Strings.Errors.simulatorStateShutdown
            case "booting": return Strings.Errors.simulatorStateBooting
            case "shutting down": return Strings.Errors.simulatorStateStopping
            default: return state
            }
        }
        var runtimeName: String {
            let identifier = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            let parts = identifier.split(separator: "-")
            guard let platform = parts.first else { return runtime }
            let display = platform == "xrOS" ? "visionOS" : String(platform)
            return display + (parts.count > 1 ? " " + parts.dropFirst().joined(separator: ".") : "")
        }
        func matches(platform: String) -> Bool {
            if platform == "all" || platform == "Xcode Preview (SwiftUI)" { return true }
            let prefix = runtimeName.split(separator: " ").first.map(String.init) ?? runtimeName
            return prefix.caseInsensitiveCompare(platform) == .orderedSame
        }
    }

    struct Command: Sendable, Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: String
    }
    typealias Runner = @Sendable (Command) throws -> Output

    struct Failure: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ message: String) { operationIssue = .technical(message) }
        var message: String { operationIssue.diagnostic }
        var text: String { operationIssue.diagnostic }
        var errorDescription: String? { operationIssue.diagnostic }
    }

    private struct Listing: Decodable {
        let devices: [String: [Record]]
        struct Record: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
        }
    }

    static func validateDeviceSet(_ deviceSet: URL) throws {
        let directory = try deviceSet.resourceValues(forKeys: [.isDirectoryKey])
        let metadata = deviceSet.appendingPathComponent("device_set.plist")
        guard directory.isDirectory == true,
              (try? metadata.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw Failure(OperationIssue.simulatorCertificateInstallerSelectAnExistingSimulatorDeviceSetDirectoryContaining)
        }
    }

    static func parseDevices(_ data: Data) throws -> [Device] {
        guard data.count <= 4 * 1024 * 1024 else { throw Failure(OperationIssue.simulatorCertificateInstallerTheSimctlDeviceListExceeds4Mib) }
        let listing: Listing
        do { listing = try JSONDecoder().decode(Listing.self, from: data) }
        catch { throw Failure(OperationIssue.simulatorCertificateInstallerUnableToParseTheSimctlDeviceListCheck) }
        guard listing.devices.values.reduce(0, { $0 + $1.count }) <= 1000 else { throw Failure(OperationIssue.simulatorCertificateInstallerTheDeviceCountExceeds1000SelectA) }
        var ids = Set<String>()
        var devices: [Device] = []
        for (runtime, records) in listing.devices {
            for record in records where record.isAvailable != false {
                guard let identifier = UUID(uuidString: record.udid), !record.name.isEmpty,
                      record.name.utf8.count <= 2048, runtime.utf8.count <= 512 else {
                    throw Failure(OperationIssue.simulatorCertificateInstallerSimctlReturnedAnInvalidDeviceIdentifierOrName)
                }
                let id = identifier.uuidString
                guard ids.insert(id).inserted else { throw Failure(OperationIssue.simulatorCertificateInstallerSimctlReturnedADuplicateDeviceIdentifier) }
                devices.append(Device(id: id, name: record.name, runtime: runtime, state: record.state))
            }
        }
        return devices.sorted {
            if $0.isBooted != $1.isBooted { return $0.isBooted }
            return ($0.runtimeName, $0.name, $0.id) < ($1.runtimeName, $1.name, $1.id)
        }
    }

    static func list(deviceSet: URL? = nil, runner: Runner = run) throws -> [Device] {
        let command = try command(["list", "devices", "available", "-j"], deviceSet: deviceSet, timeout: 15)
        let output = try runner(command)
        try requireSuccess(output, operation: Strings.Errors.simulatorCertificateInstallerReadTheDeviceList)
        return try parseDevices(output.stdout)
    }

    static func install(certificate: URL, device: Device, deviceSet: URL? = nil, runner: Runner = run) throws {
        guard UUID(uuidString: device.id) != nil, device.isBooted else {
            throw Failure(OperationIssue.simulatorCertificateInstallerStartInXcodeOrSimulatorThenRefreshThe(String(device.name)))
        }
        let material = try CertificateFormats.load(certificate: certificate)
        try CertificateFormats.validate(material, purpose: .upstreamCA)
        let command = try command(["keychain", device.id, "add-root-cert", certificate.path], deviceSet: deviceSet, timeout: 20)
        let output = try runner(command)
        try requireSuccess(output, operation: Strings.Errors.simulatorCertificateInstallerInstallTheCaOn(String(device.name)))
    }

    private static func command(_ arguments: [String], deviceSet: URL?, timeout: TimeInterval) throws -> Command {
        var parameters = ProcessInfo.processInfo.environment["PM_SIMCTL"] == nil ? ["simctl"] : []
        if let deviceSet {
            try validateDeviceSet(deviceSet)
            parameters += ["--set", deviceSet.path]
        }
        parameters += arguments
        return Command(executable: DeviceAutomation.simctlPath, arguments: parameters, timeout: timeout)
    }

    private static func requireSuccess(_ output: Output, operation: String) throws {
        guard output.status == 0 else {
            let details = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(OperationIssue.simulatorCertificateInstallerFailedExitCode(String(operation), Int(output.status), String(details.isEmpty ? OperationIssue.simulatorCheckRuntime.diagnostic : String(details.prefix(2048)))))
        }
    }

    /// stdout/stderr go to private files so a verbose simctl cannot deadlock a
    /// full pipe. The executable is a fixed xcrun (or the existing PM_SIMCTL test hook).
    static func run(_ command: Command) throws -> Output {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Simctl-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        try PrivateAppFile.write(Data(), to: stdoutURL)
        try PrivateAppFile.write(Data(), to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + command.timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw Failure(OperationIssue.simulatorCertificateInstallerSimctlExceededSecondsAndWasStoppedCheckXcode(Int(Int(command.timeout))))
        }
        let output = try FileHandle(forReadingFrom: stdoutURL)
        let errors = try FileHandle(forReadingFrom: stderrURL)
        defer { try? output.close(); try? errors.close() }
        let data = try output.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 4 * 1024 * 1024 else { throw Failure(OperationIssue.simulatorCertificateInstallerSimctlStandardOutputExceeds4Mib) }
        let errorData = try errors.read(upToCount: 8192) ?? Data()
        return Output(status: process.terminationStatus, stdout: data, stderr: String(decoding: errorData, as: UTF8.self))
    }
}
