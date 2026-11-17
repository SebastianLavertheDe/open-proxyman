import SwiftUI

enum ProxyMirrorAppearance: String, CaseIterable {
    case system = "跟随系统", light = "浅色", dark = "深色"

    static let key = "ui.appearance"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 设置窗口（对齐 Proxyman Preferences 的工具栏标签页风格）
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(ProxyMirrorAppearance.key) private var appearance = ProxyMirrorAppearance.system
    @State private var selectedTab = 0

    @State private var search = ""
    @State private var reveal: SettingsSearchTarget?
    @State private var revealRequest = UUID()
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索设置", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit {
                            if let target = SettingsSearchTarget.results(for: search).first { show(target) }
                        }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("清空设置搜索")
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.top, 12)

                Picker("", selection: Binding(
                    get: { selectedTab },
                    set: { selectedTab = $0; search = ""; reveal = nil }
                )) {
                    Text("General").tag(0)
                    Text("SSL").tag(1)
                    Text("Advanced").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)

                Divider()

                ScrollView {
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchResults
                    } else {
                        switch selectedTab {
                        case 0: generalTab
                        case 1: sslTab
                        default: advancedTab
                        }
                    }
                }
                .padding(20)
            }
            .onChange(of: revealRequest) { _ in
                guard let reveal else { return }
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(reveal, anchor: .center) }
                }
            }
        }
        .frame(width: 520, height: 455)
        .onAppear { revealSettingsTarget() }
        .onChange(of: appState.settingsTarget) { _ in revealSettingsTarget() }
    }

    private var searchResults: some View {
        let results = SettingsSearchTarget.results(for: search)
        return VStack(alignment: .leading, spacing: 6) {
            if results.isEmpty {
                Text("未找到匹配设置。").foregroundStyle(.secondary)
            }
            ForEach(results) { target in
                Button {
                    show(target)
                } label: {
                    HStack {
                        Text(target.title)
                        Spacer()
                        Text(target.tabTitle).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func revealSettingsTarget() {
        guard let target = appState.settingsTarget else { return }
        appState.settingsTarget = nil
        show(target)
    }

    private func show(_ target: SettingsSearchTarget) {
        selectedTab = target.tab
        search = ""
        searchFocused = false
        reveal = target
        revealRequest = UUID()
    }

    private func setting<V: View>(_ target: SettingsSearchTarget, @ViewBuilder content: () -> V) -> some View {
        content()
            .background {
                if reveal == target {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.15))
                }
            }
            .id(target)
    }

    // MARK: General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            setting(.listenPort) {
                HStack {
                    Text("代理端口").frame(width: 120, alignment: .leading)
                    TextField("Port", value: Binding(
                        get: { Int(settings.port) },
                        set: { settings.port = UInt16(min(max($0, 1024), 65535)) }
                    ), formatter: NumberFormatter())
                        .frame(width: 90)
                    Text("默认 9090").font(.caption).foregroundColor(.secondary)
                }
            }

            setting(.autoStart) {
                Toggle("打开 App 时自动启动监听", isOn: Binding(
                    get: { settings.autoStartProxy },
                    set: { settings.autoStartProxy = $0 }))
            }

            setting(.autoTakeOver) {
                Toggle("监听启动后自动接管系统代理", isOn: Binding(
                    get: { settings.autoTakeOverSystemProxy },
                    set: { settings.autoTakeOverSystemProxy = $0 }))
            }

            setting(.followLatest) {
                Toggle("自动滚动到最新请求", isOn: Binding(
                    get: { settings.followLatest },
                    set: { settings.followLatest = $0 }))
            }

            setting(.appearance) {
                Picker("外观", selection: $appearance) {
                    ForEach(ProxyMirrorAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }

            Divider()

            setting(.lan) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("允许指定设备连接局域网代理", isOn: Binding(
                        get: { settings.lanEnabled }, set: { settings.lanEnabled = $0 }))
                    if settings.lanEnabled {
                        Picker("本机地址", selection: Binding(
                            get: { settings.lanAddress }, set: { settings.lanAddress = $0 })) {
                            Text("选择地址").tag("")
                            ForEach(LANAccess.addresses, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("设备 IPv4 地址", text: Binding(
                            get: { settings.deviceAddress }, set: { settings.deviceAddress = $0 }))
                        Text("在设备的 Wi-Fi HTTP 代理设置中填写此地址及端口 \(settings.port)。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            setting(.applyListener) {
                Button("应用监听设置") { appState.applyAndRestartIfNeeded() }
                    .disabled(settings.lanAccess?.valid == false || appState.systemProxyBusy)
            }

            Divider()

            setting(.systemProxy) {
                Button(appState.systemProxyActive ? "关闭系统代理" : "设置系统代理") {
                    if appState.systemProxyActive { appState.stopSystemProxy() } else { appState.startSystemProxy() }
                }
                .disabled(appState.systemProxyBusy)
            }

            if appState.systemProxyServiceInstalled {
                Button("移除系统代理授权", role: .destructive, action: appState.uninstallSystemProxyService)
                    .disabled(appState.systemProxyBusy || appState.systemProxyActive)
            }

            Text("首次接管需要管理员授权。同一版本会复用授权，退出时会恢复原代理设置。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: SSL / MITM

    private var sslTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            setting(.decryptHTTPS) {
                Toggle("启用 HTTPS 解密 (MITM)", isOn: Binding(
                    get: { settings.mitmEnabled },
                    set: { settings.mitmEnabled = $0; appState.applyAndRestartIfNeeded() }))
            }

            setting(.http2) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("新建 HTTPS 连接协商 HTTP/2", isOn: Binding(
                        get: { settings.http2Enabled },
                        set: { settings.http2Enabled = $0; appState.applyAndRestartIfNeeded() }))
                    H2CUpstreamSettings()
                }
                .disabled(!settings.mitmEnabled)
            }

            setting(.caCertificate) {
                HStack {
                    Text("CA 证书").frame(width: 120, alignment: .leading)
                    Button("安装到钥匙串并信任…") { appState.installCACertificate() }
                    Button("在 Finder 中显示") { appState.revealCAFile() }
                }
            }

            Text("安装后请在系统弹出的确认框中点击「始终信任」。已信任的 CA 可解密 HTTPS 流量。")
                .font(.caption)
                .foregroundColor(.secondary)

            setting(.fingerprint) {
                if let fp = CertificateAuthority.shared.caFingerprintSHA256 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SHA-256 指纹")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(fp)
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                        HStack {
                            if let expiry = CertificateAuthority.shared.caExpiry {
                                Text("有效期至 " + expiry.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("复制指纹") { CopyPaste.copy(fp) }.controlSize(.small)
                        }
                    }
                } else {
                    Text("当前暂无 CA 指纹。").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            setting(.excludedHosts) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("不解密的主机（每行一个，支持 *.example.com）")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: Binding(
                        get: { settings.mitmExcludedHosts.joined(separator: "\n") },
                        set: { settings.mitmExcludedHosts = $0.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 90)
                        .border(Color.gray.opacity(0.3))

            Divider()

            setting(.clientCertificate) { ClientTLSIdentitySettings() }
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            setting(.bodyLimit) {
                HStack {
                    Text("Body 捕获上限 (MB)").frame(width: 160, alignment: .leading)
                    Stepper("\(settings.maxBodyMB)", value: Binding(
                        get: { settings.maxBodyMB },
                        set: { settings.maxBodyMB = $0 }), in: 1...100)
                }
            }

            setting(.transactionLimit) {
                HStack {
                    Text("最大保留请求数").frame(width: 160, alignment: .leading)
                    Stepper("\(settings.maxTransactions)", value: Binding(
                        get: { settings.maxTransactions },
                        set: { settings.maxTransactions = $0 }), in: 100...50000, step: 500)
                }
            }

            Divider()

            setting(.restart) {
                Button("应用并重启代理") { appState.applyAndRestartIfNeeded() }
                    .buttonStyle(.borderedProminent)
            }

            Divider()

            setting(.upstreamProxy) { ExternalProxySettings() }
        }
    }
}
