import AppKit
import SwiftUI

@MainActor
struct SimulatorCertificateInstallerView: View {
    let initialPlatform: String
    @State private var useCustomSet = false
    @State private var customSet: URL?
    @State private var platform = "全部"
    @State private var devices: [SimulatorCertificateInstaller.Device] = []
    @State private var selected = Set<String>()
    @State private var loading = false
    @State private var installing = false
    @State private var feedback: String?
    @State private var results: [String] = []
    @State private var operation: Task<Void, Never>?

    private let platforms = ["全部", "iOS", "watchOS", "tvOS", "visionOS"]
    private var deviceSet: URL? { useCustomSet ? customSet : nil }
    private var visibleDevices: [SimulatorCertificateInstaller.Device] { devices.filter { $0.matches(platform: platform) } }
    private var busy: Bool { loading || installing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("向所选 Simulator 安装当前 ProxyMirror CA").font(.headline)
            sourceSelector
            HStack {
                Picker("平台", selection: $platform) {
                    ForEach(platforms, id: \.self) { Text($0).tag($0) }
                }.frame(width: 190).disabled(busy)
                Spacer()
                Button("刷新设备") { refresh() }.disabled(busy || (useCustomSet && customSet == nil))
                if loading { ProgressView().controlSize(.small) }
            }
            List {
                ForEach(visibleDevices) { device in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("选择 \(device.name)", isOn: Binding(get: { selected.contains(device.id) }, set: { value in
                            if value { selected.insert(device.id) } else { selected.remove(device.id) }
                        })).labelsHidden().disabled(busy || !device.isBooted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).fontWeight(.medium)
                            Text("\(device.runtimeName) · \(device.id)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Label(device.isBooted ? "Booted" : device.state, systemImage: device.isBooted ? "play.circle.fill" : "stop.circle")
                            .font(.caption).foregroundStyle(device.isBooted ? Color.green : .secondary)
                    }.padding(.vertical, 3)
                }
                if !loading && visibleDevices.isEmpty {
                    Text("此设备集中没有匹配的可用模拟器。检查平台筛选、Xcode runtime 或所选 device-set 目录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 200, idealHeight: 250)
            Text("仅对已启动设备执行 add-root-cert；不会启动或删除设备，也不会替换 Mac 当前 CA。证书信任与请求走代理是两个步骤，安装后请另外确认代理路径。")
                .font(.caption).foregroundStyle(.secondary)
            if let feedback { Text(feedback).font(.caption).textSelection(.enabled) }
            if !results.isEmpty {
                ScrollView { Text(results.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
            }
            HStack {
                Button("选中已启动设备") { selected = Set(visibleDevices.filter(\.isBooted).map(\.id)) }.disabled(busy)
                Button("清除选择") { selected.removeAll() }.disabled(busy || selected.isEmpty)
                Spacer()
                if installing {
                    ProgressView().controlSize(.small)
                    Button("取消后续安装") { operation?.cancel(); feedback = "当前设备命令完成后停止，不再安装其他设备。" }
                }
                Button("安装到 \(selected.count) 台设备") { install() }
                    .buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty)
            }
        }
        .padding(18).frame(width: 780)
        .onAppear {
            platform = platforms.contains(initialPlatform) ? initialPlatform : "全部"
            refresh()
        }
        .onChange(of: platform) { _ in selected.formIntersection(visibleDevices.map(\.id)) }
        .onDisappear { operation?.cancel() }
    }

    private var sourceSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("设备集", selection: Binding(get: { useCustomSet }, set: { value in
                useCustomSet = value; devices = []; selected.removeAll(); feedback = nil
                if !value || customSet != nil { refresh() }
            })) {
                Text("标准 Simulator device set").tag(false)
                Text("手动选择 device set（含 Preview）").tag(true)
            }.pickerStyle(.segmented)
            if useCustomSet {
                HStack {
                    Text(customSet?.path ?? "尚未选择目录").font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("选择目录…", action: chooseDeviceSet)
                }
                Text("为 Xcode Preview 选择其实际 device-set 目录（需包含 device_set.plist）；安装器不会猜测隐藏 runtime 路径。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(busy)
    }

    private func chooseDeviceSet() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "使用此设备集"
        panel.message = "选择包含 device_set.plist 的现有 Simulator device-set 目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SimulatorCertificateInstaller.validateDeviceSet(url)
            customSet = url; useCustomSet = true; selected.removeAll(); devices = []; refresh()
        } catch { feedback = error.localizedDescription }
    }

    private func refresh() {
        guard !busy, !useCustomSet || customSet != nil else { return }
        let set = deviceSet
        loading = true; feedback = nil; results = []
        operation = Task {
            defer { loading = false; operation = nil }
            do {
                let listed = try await Task.detached(priority: .userInitiated) {
                    try SimulatorCertificateInstaller.list(deviceSet: set)
                }.value
                guard !Task.isCancelled else { return }
                devices = listed
                selected.formIntersection(listed.filter(\.isBooted).map(\.id))
                feedback = "已读取 \(listed.count) 台可用设备。请选择要安装 CA 的 Booted 设备。"
            } catch { devices = []; selected.removeAll(); feedback = error.localizedDescription }
        }
    }

    private func install() {
        guard !busy else { return }
        let targets = devices.filter { selected.contains($0.id) && $0.isBooted }
        guard !targets.isEmpty else { return }
        let set = deviceSet
        installing = true; results = []; feedback = "准备当前 CA…"
        operation = Task {
            defer { installing = false; operation = nil }
            do {
                let certificate = try await Task.detached(priority: .userInitiated) {
                    let pem = try CertificateAuthority.shared.caPEM()
                    let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Simulator-CA-" + UUID().uuidString + ".pem")
                    try PrivateAppFile.write(Data(pem.utf8), to: snapshot)
                    return snapshot
                }.value
                defer { try? FileManager.default.removeItem(at: certificate) }
                var successes = 0
                for device in targets {
                    try Task.checkCancellation()
                    feedback = "正在安装：\(device.name) · \(device.runtimeName)…"
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try SimulatorCertificateInstaller.install(certificate: certificate, device: device, deviceSet: set)
                        }.value
                        successes += 1
                        results.append("✓ \(device.name)（\(device.runtimeName)）：simctl 已完成 CA 安装。")
                    } catch { results.append("✗ \(device.name)：\(error.localizedDescription)") }
                }
                feedback = "安装结束：\(successes) / \(targets.count) 台成功。请在目标应用发起测试请求并核对代理抓包。"
            } catch is CancellationError { feedback = "已停止后续安装。已完成的设备安装保持有效。" }
            catch { feedback = error.localizedDescription }
        }
    }
}
