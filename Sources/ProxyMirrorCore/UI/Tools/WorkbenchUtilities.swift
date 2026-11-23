import SwiftUI
import AppKit
import Darwin

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

struct FlowSummaryView: View {
    @ObservedObject var store: TrafficStore
    @State private var onlySelection = false
    private var items: [Transaction] { onlySelection ? store.selectedTransactions : store.visible }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("仅统计所选请求", isOn: $onlySelection)
            let flows = items
            let durations = flows.filter { $0.state == .completed }.map(\.duration).sorted()
            HStack(spacing: 32) {
                metric("请求", String(flows.count))
                metric("失败", String(flows.filter { $0.state == .failed || $0.statusCode >= 400 }.count))
                metric("平均耗时", durations.isEmpty ? "—" : String(format: "%.1f ms", durations.reduce(0, +) / Double(durations.count) * 1000))
                metric("P95 耗时", durations.isEmpty ? "—" : String(format: "%.1f ms", durations[min(durations.count - 1, Int(Double(durations.count - 1) * 0.95))] * 1000))
            }
            Text("上传 \(size(flows.reduce(0) { $0 + $1.requestBytes })) · 下载 \(size(flows.reduce(0) { $0 + $1.responseBytes }))")
            Divider()
            Text("按主机汇总").font(.headline)
            let groups = Dictionary(grouping: flows, by: \.host)
            List {
                ForEach(groups.keys.sorted(), id: \.self) { host in
                    let group = groups[host] ?? []
                    HStack {
                        Text(host).textSelection(.enabled)
                        Spacer()
                        Text("\(group.count) 条 · \(size(group.reduce(0) { $0 + $1.responseBytes }))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 600, minHeight: 420)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.monospacedDigit()) }
    }
    private func size(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }
}

struct ExperienceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
            Text("显示与复制").font(.headline)
            Toggle("在菜单栏显示图标", isOn: binding(\.showMenuBarIcon))
            Toggle("底部栏显示内存和实时传输速率", isOn: binding(\.showResourceUsage))
            Toggle("隐藏 Apple 后台流量", isOn: binding(\.hideAppleTraffic))
            Picker("列表与 URL 截断位置", selection: Binding(get: { settings.truncationStyle }, set: { settings.truncationStyle = $0 })) {
                Text("开头").tag("head"); Text("中间").tag("middle"); Text("末尾").tag("tail")
            }
            Toggle("正文自动换行", isOn: binding(\.wordWrap))
            Toggle("正文显示空白字符", isOn: binding(\.showInvisibles))
            Toggle("正文显示缩略导航", isOn: binding(\.showMinimap))
            }
            Group {
            Divider()
            Toggle("复制和导出时脱敏敏感头", isOn: binding(\.redactSensitiveHeaders))
            Toggle("复制命令时追加本机 --proxy", isOn: binding(\.appendProxyToCommands))
            Toggle("重复请求禁用缓存", isOn: binding(\.noCacheOnRepeat))
            Toggle("给上游请求附加 ProxyMirror 诊断头", isOn: binding(\.appendDiagnosticHeaders))
            }
        }
    }
    private func binding(_ key: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0 })
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
