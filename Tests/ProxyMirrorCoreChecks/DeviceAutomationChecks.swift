import Foundation
@testable import ProxyMirrorCore

/// G3：模拟器/设备自动化（PM_SIMCTL 替身命令 + JSON 解析 + 命令拼装）
func checkDeviceAutomation(_ test: CoreAssertions) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pm-automation-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let json = """
        {"devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-0" : [
                {"udid" : "AAAAAAAA-1111-2222-3333-444444444444", "name" : "iPhone 15", "state" : "Shutdown"},
                {"udid" : "BBBBBBBB-1111-2222-3333-444444444444", "name" : "iPhone 16", "state" : "Booted"}
            ],
            "com.apple.CoreSimulator.SimRuntime.tvOS-17-0" : [
                {"udid" : "CCCCCCCC-1111-2222-3333-444444444444", "name" : "Apple TV", "state" : "Booted (Simulating)"}
            ]
        }}
        """
    let mock = dir.appendingPathComponent("simctl-mock")
    let log = dir.appendingPathComponent("args.log")
    try! """
        #!/bin/sh
        echo "$@" >> "\(log.path)"
        if [ "$1" = "list" ]; then cat <<'JSON'
        \(json)
        JSON
        fi
        """.write(to: mock, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock.path)
    setenv("PM_SIMCTL", mock.path, 1)
    defer { unsetenv("PM_SIMCTL") }

    let devices = try? DeviceAutomation.listSimulators()
    test.equal(devices?.count, 3, "解析 simctl JSON 设备清单")
    test.equal(devices?.filter(\.isBooted).count, 2, "识别 Booted 状态（含 Simulating）")

    let booted = try? DeviceAutomation.bootedSimulators()
    test.equal(booted?.map(\.udid), ["CCCCCCCC-1111-2222-3333-444444444444", "BBBBBBBB-1111-2222-3333-444444444444"],
               "bootedSimulators 过滤并排序")

    let cert = dir.appendingPathComponent("ca.pem")
    try! Data("-----BEGIN CERTIFICATE-----\n".utf8).write(to: cert)
    _ = try? DeviceAutomation.installRootCertificate(cert.path, simulator: booted?.first?.udid ?? "")
    let argsLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    test.expect(argsLog.contains("keychain CCCCCCCC-1111-2222-3333-444444444444 add-root-cert \(cert.path)"),
                "安装证书命令拼装 keychain add-root-cert")

    // 无 Booted 设备 → noBootedSimulators
    let emptyMock = dir.appendingPathComponent("simctl-empty")
    try! """
        #!/bin/sh
        echo '{"devices" : {"runtime" : [{"udid" : "D-1", "name" : "Pad", "state" : "Shutdown"}]}}'
        """.write(to: emptyMock, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: emptyMock.path)
    setenv("PM_SIMCTL", emptyMock.path, 1)
    do {
        _ = try DeviceAutomation.bootedSimulators()
        test.expect(false, "无启动设备应抛出 noBootedSimulators")
    } catch {
        test.equal(error as? DeviceAutomation.AutomationError, .noBootedSimulators, "无启动设备报 noBootedSimulators")
    }

    let mockADB = dir.appendingPathComponent("adb-mock")
    let adbLog = dir.appendingPathComponent("adb-args.log")
    try! """
        #!/bin/sh
        echo "$@" >> "\(adbLog.path)"
        if [ "$1" = devices ]; then
            printf 'List of devices attached\\nfixture-device\\tdevice\\nother\\tunauthorized\\n'
        fi
        """.write(to: mockADB, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockADB.path)
    setenv("PM_ADB", mockADB.path, 1)
    defer { unsetenv("PM_ADB") }

    test.equal(try? DeviceAutomation.androidDevices(), ["fixture-device"], "adb 只选择已授权设备")
    test.expect((try? DeviceAutomation.prepareAndroidUserCertificate(certificatePath: cert.path)) != nil,
                "adb 将用户 CA 复制到设备")
    let commands = (try? String(contentsOf: adbLog, encoding: .utf8)) ?? ""
    test.expect(commands.contains("-s fixture-device push \(cert.path) /sdcard/Download/ProxyMirror-CA.cer"),
                "adb 用户 CA 复制命令绑定设备序列号")
    test.rejects(try DeviceAutomation.setupAndroidEmulator(certificatePath: cert.path),
                 with: DeviceAutomation.AutomationError.self, "adb root 路径拒绝实体设备")

}
