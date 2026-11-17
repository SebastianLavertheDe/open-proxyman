import AppKit
import SwiftUI

struct ProxyStatusPopover: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    private var engine: ProxyEngine { .shared }
    private var lan: LANAccess? { appState.proxyRunning ? engine.lanAccess : settings.lanAccess }
    private var address: String { lan?.address ?? "127.0.0.1" }
    private var port: UInt16 { appState.proxyRunning ? engine.port : settings.port }
    private var isRecording: Bool { appState.proxyRunning && appState.recordingEnabled }

    var body: some View {
        VStack(spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 5) {
                detail("IP") {
                    HStack(spacing: 7) {
                        Text(address).monospacedDigit()
                        Button { CopyPaste.copy(address) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("复制 IP 地址")
                            .accessibilityLabel("复制 IP 地址")
                    }
                }
                detail("代理端口") {
                    HStack(spacing: 7) {
                        Text(String(port)).monospacedDigit()
                        Button { openSettings(at: .listenPort) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("编辑代理端口")
                            .accessibilityLabel("编辑代理端口")
                    }
                }
                detail("监听范围") {
                    Text(lan.map { "本机与 \($0.device)" } ?? "仅本机")
                }
                detail("HTTP 模式") {
                    Picker("HTTP 模式", selection: Binding(
                        get: { settings.http2Enabled },
                        set: { enabled in
                            settings.http2Enabled = enabled
                            engine.http2Enabled = enabled
                        })) {
                        Text("HTTP/1.1").tag(false)
                        Text("HTTP/1.1 + HTTP/2").tag(true)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            VStack(spacing: 8) {
                switchRow(isRecording ? "正在录制" : "录制", isOn: Binding(
                    get: { isRecording },
                    set: { if $0 != isRecording { appState.toggleRecording() } }))
                switchRow(appState.systemProxyBusy ? "macOS 代理切换中…" : "macOS 代理", isOn: Binding(
                    get: { appState.systemProxyActive },
                    set: { enabled in
                        if enabled { appState.startSystemProxy() } else { appState.stopSystemProxy() }
                    }))
                    .disabled(!appState.proxyRunning || appState.systemProxyBusy || appState.transparentProxyNeedsStop)
                switchRow("网络扩展", isOn: Binding(
                    get: { appState.transparentProxyNeedsStop },
                    set: { if $0 != appState.transparentProxyNeedsStop { appState.toggleTransparentProxy() } }))
                    .disabled(!TransparentProxyController.isAvailable || appState.systemProxyBusy || appState.systemProxyActive)
                    .help(TransparentProxyController.isAvailable ? "透明抓包" : "此版本未包含网络扩展")
            }

            HStack {
                Button(appState.proxyRunning ? "停止监听" : "启动监听", action: appState.toggleProxy)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(appState.systemProxyBusy)
                Spacer()
                Button("高级设置…") { openSettings(at: .bodyLimit) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 12))
            .padding(.top, 4)
        }
        .font(.system(size: 13))
        .padding(.vertical, 13)
        .padding(.horizontal, 17)
        .frame(width: 298)
    }

    private func detail<Value: View>(_ name: String, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func openSettings(at target: SettingsSearchTarget) {
        appState.settingsTarget = target
        if #available(macOS 14, *) {
            environment.openSettings()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        dismiss()
    }
}
