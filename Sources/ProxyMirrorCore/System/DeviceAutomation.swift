import Foundation

/// 模拟器/设备自动化：
/// - iOS 模拟器：`xcrun simctl keychain <udid> add-root-cert` 安装根证书，可选重启模拟器；
///   模拟器应用与宿主共享网络栈，HTTPS 解密配合「接管系统代理」即可生效。
/// - Android 模拟器：优先 adb root 路线安装系统级证书（仅限 Google APIs 镜像，由用户主动触发）；
///   不可 root 时给出用户证书的手工路径。
/// 测试通过 PM_SIMCTL / PM_ADB 注入替身命令。
enum DeviceAutomation {

    struct SimulatorDevice: Identifiable, Equatable {
        let udid: String
        let name: String
        let state: String
        var id: String { udid }
        var isBooted: Bool { state.lowercased().contains("booted") }
    }

    enum AutomationError: LocalizedError, OperationIssueProviding, Equatable {
        case noBootedSimulators
        case invalidOutput
        case unsupportedAndroidDevice
        case commandFailed(String)
        case operationFailed(OperationIssue)

        var errorDescription: String? { operationIssue.diagnostic }
        var operationIssue: OperationIssue {
            switch self {
            case .noBootedSimulators: return OperationIssue.deviceAutomationNoIosSimulatorIsRunningStartAtLeast
            case .unsupportedAndroidDevice:
                return OperationIssue.deviceAutomationAConnectedWritableAndroidEmulatorRunningAndroid13
            case .invalidOutput: return OperationIssue.deviceAutomationUnableToParseTheDeviceListCheckYour
            case .operationFailed(let issue): return issue
            case .commandFailed(let detail): return OperationIssue.deviceAutomationTheCommandFailed(String(detail))
            }
        }
    }

    static var simctlPath: String {
        ProcessInfo.processInfo.environment["PM_SIMCTL"] ?? "/usr/bin/xcrun"
    }

    static var adbPath: String {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PM_ADB"] { return path }
        let userSDK = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path
        let sdkPaths = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 } + [userSDK]
        let executablePaths = sdkPaths.map { $0 + "/platform-tools/adb" }
        let searchPaths = (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/adb" }
        let candidates = executablePaths + searchPaths + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/usr/bin/adb"
    }

    private static func run(_ executable: String, _ arguments: [String],
                            cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> (output: String, error: String) {
        do {
            let result = try DeviceCommandRunner.run(executable, arguments, cancellation: cancellation)
            return (result.stdout, result.stderr)
        } catch let failure as DeviceCommandRunner.Failure {
            throw AutomationError.operationFailed(failure.operationIssue)
        }
    }

    private static func simctl(_ arguments: [String], cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> String {
        let args = ProcessInfo.processInfo.environment["PM_SIMCTL"] != nil ? arguments : ["simctl"] + arguments
        return try run(simctlPath, args, cancellation: cancellation).output
    }

    static func adb(_ arguments: [String], cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> String {
        return try run(adbPath, arguments, cancellation: cancellation).output
    }

    // MARK: iOS 模拟器

    struct DevicesOutput: Decodable {
        let devices: [String: [Device]]

        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
        }
    }

    static func parseDevices(_ json: String) throws -> [SimulatorDevice] {
        guard let data = json.data(using: .utf8),
              let output = try? JSONDecoder().decode(DevicesOutput.self, from: data) else {
            throw AutomationError.invalidOutput
        }
        return output.devices.values.flatMap { $0 }.map {
            SimulatorDevice(udid: $0.udid, name: $0.name, state: $0.state)
        }.sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
    }

    static func listSimulators(cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> [SimulatorDevice] {
        try parseDevices(simctl(["list", "devices", "-j"], cancellation: cancellation))
    }

    static func bootedSimulators(cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> [SimulatorDevice] {
        let booted = try listSimulators(cancellation: cancellation).filter(\.isBooted)
        guard !booted.isEmpty else { throw AutomationError.noBootedSimulators }
        return booted
    }

    @discardableResult
    static func installRootCertificate(_ caPath: String, simulator udid: String,
                                        cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> String {
        try simctl(["keychain", udid, "add-root-cert", caPath], cancellation: cancellation)
    }

    static func restartSimulator(_ udid: String, cancellation: DeviceCommandRunner.Cancellation? = nil) throws {
        _ = try simctl(["shutdown", udid], cancellation: cancellation)
        _ = try simctl(["boot", udid], cancellation: cancellation)
    }

    /// 一键：向所有已启动模拟器安装 CA。返回人类可读结果（含后续提示）。
    static func setupSimulators(certificatePath: String, cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> String {
        let booted = try bootedSimulators(cancellation: cancellation)
        var lines: [String] = []
        for device in booted {
            _ = try installRootCertificate(certificatePath, simulator: device.udid, cancellation: cancellation)
            lines.append(Strings.Errors.deviceAutomationInstalledCa(String(device.name), String(device.udid.prefix(8))))
        }
        lines.append(Strings.Errors.deviceAutomationSimulatorAppsUseTheHostNetworkStackKeep)
        return lines.joined(separator: "\n")
    }

    // MARK: Android 模拟器（adb root 路线；不静默 root，由用户点击触发）

    static func androidCertificateHash(certificatePath: String, cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> String {
        let output = try run("/usr/bin/openssl", ["x509", "-subject_hash_old", "-noout", "-in", certificatePath], cancellation: cancellation).output
        guard let hash = output.split(separator: "\n").first,
              hash.utf8.count == 8, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AutomationError.invalidOutput
        }
        return String(hash)
    }

    static func androidDevices(cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> [String] {
        try adb(["devices"], cancellation: cancellation).split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[1] == "device" ? String(fields[0]) : nil
        }
    }

    /// Stage a CA for installation through the device's Settings app.
    static func prepareAndroidUserCertificate(certificatePath: String,
                                               cancellation: DeviceCommandRunner.Cancellation? = nil) throws -> String {
        let devices = try androidDevices(cancellation: cancellation)
        guard devices.count == 1, let device = devices.first else {
            throw AutomationError.operationFailed(OperationIssue.deviceAutomationConnectOnlyOneAndroidDeviceWithUsbDebugging)
        }
        _ = try adb(["-s", device, "push", certificatePath, "/sdcard/Download/ProxyMirror-CA.cer"], cancellation: cancellation)
        return Strings.Errors.deviceAutomationTheCertificateWasCopiedToTheDeviceDownload
    }


}
