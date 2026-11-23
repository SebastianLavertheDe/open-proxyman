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
        var runtimeName: String {
            let identifier = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            let parts = identifier.split(separator: "-")
            guard let platform = parts.first else { return runtime }
            let display = platform == "xrOS" ? "visionOS" : String(platform)
            return display + (parts.count > 1 ? " " + parts.dropFirst().joined(separator: ".") : "")
        }
        func matches(platform: String) -> Bool {
            if platform == "全部" || platform == "Xcode Preview (SwiftUI)" { return true }
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

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
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
            throw Failure("请选择包含 device_set.plist 的现有 Simulator device-set 目录。不会创建新的设备集。")
        }
    }

    static func parseDevices(_ data: Data) throws -> [Device] {
        guard data.count <= 4 * 1024 * 1024 else { throw Failure("simctl 设备列表超过 4 MiB。") }
        let listing: Listing
        do { listing = try JSONDecoder().decode(Listing.self, from: data) }
        catch { throw Failure("无法解析 simctl 设备列表。请确认已选择可用的 Xcode 与 Simulator runtime。") }
        guard listing.devices.values.reduce(0, { $0 + $1.count }) <= 1000 else { throw Failure("设备数量超过 1000，请选择较小的设备集。") }
        var ids = Set<String>()
        var devices: [Device] = []
        for (runtime, records) in listing.devices {
            for record in records where record.isAvailable != false {
                guard let identifier = UUID(uuidString: record.udid), !record.name.isEmpty,
                      record.name.utf8.count <= 2048, runtime.utf8.count <= 512 else {
                    throw Failure("simctl 返回了无效的设备标识或名称。")
                }
                let id = identifier.uuidString
                guard ids.insert(id).inserted else { throw Failure("simctl 返回了重复设备标识。") }
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
        try requireSuccess(output, operation: "读取设备列表")
        return try parseDevices(output.stdout)
    }

    static func install(certificate: URL, device: Device, deviceSet: URL? = nil, runner: Runner = run) throws {
        guard UUID(uuidString: device.id) != nil, device.isBooted else {
            throw Failure("请先在 Xcode 或 Simulator 中启动 \(device.name)，然后刷新列表。安装器不会自动启动设备。")
        }
        let material = try CertificateFormats.load(certificate: certificate)
        try CertificateFormats.validate(material, purpose: .upstreamCA)
        let command = try command(["keychain", device.id, "add-root-cert", certificate.path], deviceSet: deviceSet, timeout: 20)
        let output = try runner(command)
        try requireSuccess(output, operation: "向 \(device.name) 安装 CA")
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
            throw Failure("\(operation)失败（退出码 \(output.status)）。\(details.isEmpty ? "请检查 Xcode、runtime 与设备状态。" : String(details.prefix(2048)))")
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
            throw Failure("simctl 执行超过 \(Int(command.timeout)) 秒，已停止本次命令。请检查 Xcode 和目标 runtime。")
        }
        let output = try FileHandle(forReadingFrom: stdoutURL)
        let errors = try FileHandle(forReadingFrom: stderrURL)
        defer { try? output.close(); try? errors.close() }
        let data = try output.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 4 * 1024 * 1024 else { throw Failure("simctl 标准输出超过 4 MiB。") }
        let errorData = try errors.read(upToCount: 8192) ?? Data()
        return Output(status: process.terminationStatus, stdout: data, stderr: String(decoding: errorData, as: UTF8.self))
    }
}
