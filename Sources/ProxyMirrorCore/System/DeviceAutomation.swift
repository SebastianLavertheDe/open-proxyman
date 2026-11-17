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

    enum AutomationError: LocalizedError, Equatable {
        case noBootedSimulators
        case invalidOutput
        case unsupportedAndroidDevice
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .noBootedSimulators: return "没有已启动的 iOS 模拟器。请先在 Xcode 里启动至少一台。"
            case .unsupportedAndroidDevice:
                return "需要一个已连接的可写 Android 模拟器（Android 13 或更早）。实体设备请使用用户证书安装指南。"
            case .invalidOutput: return "无法解析设备列表输出，请检查 Xcode 与 Command Line Tools 配置。"
            case .commandFailed(let detail): return "命令执行失败：\(detail)"
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

    private static func run(_ executable: String, _ arguments: [String]) throws -> (output: String, error: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning { Thread.sleep(forTimeInterval: 0.02) }
        guard process.terminationStatus == 0 else {
            throw AutomationError.commandFailed(String(decoding: errData, as: UTF8.self)
                + String(decoding: data, as: UTF8.self))
        }
        return (String(decoding: data, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    private static func simctl(_ arguments: [String]) throws -> String {
        let args = ProcessInfo.processInfo.environment["PM_SIMCTL"] != nil ? arguments : ["simctl"] + arguments
        return try run(simctlPath, args).output
    }

    static func adb(_ arguments: [String]) throws -> String {
        return try run(adbPath, arguments).output
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

    static func listSimulators() throws -> [SimulatorDevice] {
        try parseDevices(simctl(["list", "devices", "-j"]))
    }

    static func bootedSimulators() throws -> [SimulatorDevice] {
        let booted = try listSimulators().filter(\.isBooted)
        guard !booted.isEmpty else { throw AutomationError.noBootedSimulators }
        return booted
    }

    @discardableResult
    static func installRootCertificate(_ caPath: String, simulator udid: String) throws -> String {
        try simctl(["keychain", udid, "add-root-cert", caPath])
    }

    static func restartSimulator(_ udid: String) throws {
        _ = try simctl(["shutdown", udid])
        _ = try simctl(["boot", udid])
    }

    /// 一键：向所有已启动模拟器安装 CA。返回人类可读结果（含后续提示）。
    static func setupSimulators(certificatePath: String) throws -> String {
        let booted = try bootedSimulators()
        var lines: [String] = []
        for device in booted {
            _ = try installRootCertificate(certificatePath, simulator: device.udid)
            lines.append("已安装 CA：\(device.name)（\(device.udid.prefix(8))）")
        }
        lines.append("模拟器应用走宿主网络栈：需要解密时请保持「接管系统代理」。")
        return lines.joined(separator: "\n")
    }

    // MARK: Android 模拟器（adb root 路线；不静默 root，由用户点击触发）

    static func androidCertificateHash(certificatePath: String) throws -> String {
        let output = try run("/usr/bin/openssl", ["x509", "-subject_hash_old", "-noout", "-in", certificatePath]).output
        guard let hash = output.split(separator: "\n").first,
              hash.utf8.count == 8, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AutomationError.invalidOutput
        }
        return String(hash)
    }

    static func androidDevices() throws -> [String] {
        try adb(["devices"]).split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[1] == "device" ? String(fields[0]) : nil
        }
    }

    /// Stage a CA for installation through the device's Settings app.
    static func prepareAndroidUserCertificate(certificatePath: String) throws -> String {
        let devices = try androidDevices()
        guard devices.count == 1, let device = devices.first else {
            throw AutomationError.commandFailed("请仅连接一台已授权 USB 调试的 Android 设备。")
        }
        _ = try adb(["-s", device, "push", certificatePath, "/sdcard/Download/ProxyMirror-CA.cer"])
        return "证书已复制到设备的 Download 文件夹。请在 Android「设置 → 安全 → 安装 CA 证书」选择 ProxyMirror-CA.cer。"
    }

    /// Only the explicitly connected writable emulator is eligible for adb root.
    static func setupAndroidEmulator(certificatePath: String) throws -> String {
        let emulators = try androidDevices().filter { $0.hasPrefix("emulator-") }
        guard emulators.count == 1, let serial = emulators.first else { throw AutomationError.unsupportedAndroidDevice }
        func command(_ args: [String]) throws -> String { try adb(["-s", serial] + args) }
        let sdkText = try command(["shell", "getprop", "ro.build.version.sdk"])
        let fingerprint = try command(["shell", "getprop", "ro.build.fingerprint"])
        guard let sdk = Int(sdkText.trimmingCharacters(in: .whitespacesAndNewlines)), sdk < 34,
              !fingerprint.localizedCaseInsensitiveContains("playstore") else {
            throw AutomationError.unsupportedAndroidDevice
        }
        let hash = try androidCertificateHash(certificatePath: certificatePath)
        _ = try command(["root"])
        _ = try command(["wait-for-device"])
        guard try command(["shell", "id", "-u"]).trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
            throw AutomationError.unsupportedAndroidDevice
        }
        _ = try command(["remount"])
        let destination = "/system/etc/security/cacerts/\(hash).0"
        _ = try command(["push", certificatePath, destination])
        _ = try command(["shell", "chmod", "644", destination])
        return "已为 Android 模拟器 \(serial)（API \(sdk)）安装系统 CA。请按模拟器镜像要求重启后验证。"
    }
}
