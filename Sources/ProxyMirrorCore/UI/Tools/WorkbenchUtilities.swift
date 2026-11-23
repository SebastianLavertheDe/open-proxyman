import SwiftUI
import AppKit
import Darwin
import ProxyMirrorSystemProxy

/// Samples counters on the UI timer; no polling or traffic work is added to NIO loops.
@MainActor
final class ResourceUsageMonitor: ObservableObject {
    @Published private(set) var memory: Int64 = 0
    @Published private(set) var upload: Int64 = 0
    @Published private(set) var download: Int64 = 0
    private var previous: (time: TimeInterval, up: Int64, down: Int64)?

    func sample(up: Int64, down: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        if let previous, now > previous.time {
            upload = Int64(Double(max(0, up - previous.up)) / (now - previous.time))
            download = Int64(Double(max(0, down - previous.down)) / (now - previous.time))
        }
        previous = (now, up, down)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { memory = Int64(info.resident_size) }
    }
}

struct ResourceUsageView: View {
    @ObservedObject var store: TrafficStore
    @StateObject private var monitor = ResourceUsageMonitor()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Text("\(bytes(monitor.memory)) · ↑\(bytes(monitor.upload))/s ↓\(bytes(monitor.download))/s")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .help("应用驻留内存 · 当前捕获的上传 / 下载速率")
            .onReceive(timer) { _ in
                let totals = store.transferredBytes
                monitor.sample(up: totals.request, down: totals.response)
            }
    }
    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }
}

@MainActor
enum AppDiagnostics {
    static var backupDirectory: URL { CertificateAuthority.applicationSupport.appendingPathComponent("Backups", isDirectory: true) }
    static func openDataFolder(backups: Bool = false) {
        let target = backups ? backupDirectory : CertificateAuthority.applicationSupport
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            NSWorkspace.shared.open(target)
        } catch { AppState.shared.systemProxyMessage = error.localizedDescription }
    }
    static func debugInfo() -> String {
        let state = AppState.shared
        return """
        ProxyMirror \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        architecture: \(MemoryLayout<Int>.size * 8)-bit
        listening: \(state.proxyRunning), recording: \(state.recordingEnabled)
        systemProxy: \(state.systemProxyActive), port: \(state.settings.port)
        HTTP/2: \(state.settings.http2Enabled), MITM: \(state.settings.mitmEnabled)
        requests: \(state.store.visible.count)
        CA installed: \(state.caInstalled)
        debug: \(UserDefaults.standard.bool(forKey: "diagnostics.debugMode"))
        """
    }
    static func backup() throws -> URL {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = backupDirectory.appendingPathComponent("rules-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
        try PrivateAppFile.write(JSONEncoder().encode(RuleBackup.snapshot(settings: AppState.shared.settings)), to: target)
        return target
    }
    static func factoryReset(keepRules: Bool) throws {
        guard !AppState.shared.proxyRunning, !AppState.shared.systemProxyActive, !AppState.shared.systemProxyBusy,
              !AppState.shared.transparentProxyNeedsStop else {
            throw SystemProxyError("请先停止监听、透明抓包并恢复系统代理。")
        }
        _ = try backup()
        if !keepRules {
            var empty = RulesStore.shared.backup()
            empty.mapLocal = []; empty.mapRemote = []; empty.blockList = []; empty.allowList = []
            empty.sslProxyingList = []; empty.sslApplications = []; empty.customCertificates = []
            empty.breakpoints = []; empty.dns = []; empty.rewrite = []; empty.latency = LatencyConditions()
            empty.noCaching = false
            empty.organization = RuleOrganization()
            empty.reverse = []
            empty.external = ExternalProxyConfig()
            empty.h2c = H2CUpstreamConfig()
            empty.protobuf = ProtobufConfiguration()
            try RulesStore.shared.install(empty)
        }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where ["ui.", "proxy.", "capture.", "export.", "repeat."]
            .contains(where: { key.hasPrefix($0) }) { defaults.removeObject(forKey: key) }
        AppState.shared.settings.objectWillChange.send()
        AppState.shared.systemProxyMessage = "已恢复偏好设置，规则备份保存在 Backups 文件夹。重新打开应用后使用默认偏好。"
    }
}

struct FactoryResetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keepRules = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("恢复默认设置").font(.headline)
            Text("恢复前会保存规则备份。已保存会话和证书继续保留。")
            Toggle("保留规则", isOn: $keepRules)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("恢复默认", role: .destructive) {
                    do { try AppDiagnostics.factoryReset(keepRules: keepRules); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.padding(20).frame(width: 420)
    }
}
