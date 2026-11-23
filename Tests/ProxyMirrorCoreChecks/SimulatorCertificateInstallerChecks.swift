import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkSimulatorCertificateInstaller(_ test: CoreAssertions, certificate: URL) throws {
    let fixture = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"11111111-1111-1111-1111-111111111111","name":"Fixture iPhone","state":"Booted","isAvailable":true},{"udid":"22222222-2222-2222-2222-222222222222","name":"Stopped iPhone","state":"Shutdown","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.xrOS-2-0":[{"udid":"33333333-3333-3333-3333-333333333333","name":"Fixture Vision","state":"Booted","isAvailable":true},{"udid":"44444444-4444-4444-4444-444444444444","name":"Unavailable Vision","state":"Shutdown","isAvailable":false}]}}"#
    let data = Data(fixture.utf8)
    let recorder = SimulatorCommandRecorder()
    let runner: SimulatorCertificateInstaller.Runner = { command in
        recorder.append(command)
        return .init(status: 0, stdout: command.arguments.contains("list") ? data : Data(), stderr: "")
    }
    let standard = try SimulatorCertificateInstaller.list(runner: runner)
    test.equal(standard.count, 3, "Simulator installer excludes unavailable devices")
    test.equal(Array(recorder.commands[0].arguments.suffix(4)), ["list", "devices", "available", "-j"],
               "Standard device listing uses the actual simctl available JSON command")
    test.expect(!recorder.commands[0].arguments.contains("--set"), "Standard listing does not guess a custom device-set path")
    let vision = standard.first { $0.id == "33333333-3333-3333-3333-333333333333" }!
    test.equal(vision.runtimeName, "visionOS 2.0", "Legacy xrOS runtime identifiers display as visionOS")
    test.expect(vision.matches(platform: "visionOS") && vision.matches(platform: "全部") && !vision.matches(platform: "watchOS"),
                "Installer platform filtering uses runtime metadata")

    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let previewSet = directory.appendingPathComponent("Selected Preview Device Set", isDirectory: true)
    try FileManager.default.createDirectory(at: previewSet, withIntermediateDirectories: true)
    let metadata = try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .xml, options: 0)
    try metadata.write(to: previewSet.appendingPathComponent("device_set.plist"))
    let listed = try SimulatorCertificateInstaller.list(deviceSet: previewSet, runner: runner)
    test.equal(listed, standard, "Explicit device sets use the same device parsing path")
    let customArguments = recorder.commands.last!.arguments
    test.expect(customArguments.contains("--set") && customArguments.contains(previewSet.path),
                "Preview listing passes the user-selected existing device set as a literal argument")
    let booted = listed.first { $0.isBooted }!
    try SimulatorCertificateInstaller.install(certificate: certificate, device: booted, deviceSet: previewSet, runner: runner)
    let installation = recorder.commands.last!
    test.equal(Array(installation.arguments.suffix(4)), ["keychain", booted.id, "add-root-cert", certificate.path],
               "Selected-device installation executes the real CA add command with the selected UDID")
    test.expect(installation.arguments.contains(previewSet.path) && installation.timeout == 20,
                "Installation retains the same selected device set and a bounded timeout")
    test.expect(recorder.commands.allSatisfy { command in
        !command.arguments.contains("boot") && !command.arguments.contains("shutdown") && !command.arguments.contains("delete")
    }, "Listing and CA installation never boot, shut down, or delete simulators")

    let beforeFailure = recorder.commands.count
    let stopped = listed.first { !$0.isBooted }!
    test.rejects(try SimulatorCertificateInstaller.install(certificate: certificate, device: stopped, runner: runner),
                 with: SimulatorCertificateInstaller.Failure.self, "Installing to an unbooted device requires explicit user startup first")
    let unrelated = directory.appendingPathComponent("Not A Device Set", isDirectory: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    test.rejects(try SimulatorCertificateInstaller.list(deviceSet: unrelated, runner: runner),
                 with: SimulatorCertificateInstaller.Failure.self, "A custom path without device-set metadata is rejected before simctl can create anything")
    test.equal(recorder.commands.count, beforeFailure, "Rejected device and directory inputs do not execute commands")
    let failing: SimulatorCertificateInstaller.Runner = { _ in
        .init(status: 1, stdout: Data(), stderr: "Fixture runtime is not available")
    }
    do {
        _ = try SimulatorCertificateInstaller.list(runner: failing)
        test.expect(false, "simctl failures reach the installer")
    } catch {
        test.expect(error.localizedDescription.contains("Fixture runtime is not available"),
                    "Installer reports bounded actionable simctl stderr")
    }
    test.rejects(try SimulatorCertificateInstaller.parseDevices(Data("not-json".utf8)),
                 with: SimulatorCertificateInstaller.Failure.self, "Malformed simctl JSON is rejected")

    // Exercise the actual Process runner with harmless substitute executables;
    // no Xcode, simulator, device trust, or user's CA is changed by these checks.
    let emitted = try SimulatorCertificateInstaller.run(.init(executable: "/usr/bin/printf", arguments: ["%s", fixture], timeout: 2))
    test.equal(emitted.stdout, data, "Real simulator command runner captures substitute-command JSON without pipe deadlock")
    test.equal(emitted.status, 0, "Real simulator command runner preserves exit status")
    test.rejects(try SimulatorCertificateInstaller.run(.init(executable: "/bin/sleep", arguments: ["5"], timeout: 0.05)),
                 with: SimulatorCertificateInstaller.Failure.self, "Real simulator command runner terminates an overdue substitute command")
}

private final class SimulatorCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SimulatorCertificateInstaller.Command] = []
    func append(_ command: SimulatorCertificateInstaller.Command) {
        lock.lock(); defer { lock.unlock() }; values.append(command)
    }
    var commands: [SimulatorCertificateInstaller.Command] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}
