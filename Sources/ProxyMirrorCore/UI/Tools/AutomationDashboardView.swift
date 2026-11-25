import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct AutomationDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var message = ""
    @State private var error = false
    @State private var busy = false
    @State private var manual = false
    @State private var terminal = ProxyAutomation.Target.terminal
    @State private var customCommand = "open -na '/Applications/My Terminal.app' --args -e /bin/zsh -il"
    @State private var editingCommand = false
    @State private var electron: URL?

    public init() {}
    private var command: String {
        let environment = ProxyAutomation.environment(port: appState.listenerPort, certificate: appState.certificateAuthority.caCertPath)
        return environment.keys.sorted().map { "export \($0)=\(ProxyAutomation.shellQuote(environment[$0]!))" }.joined(separator: "\n")
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GuideTitle(title: Strings.Guides.setupAutomaticTitle)
                Picker(Strings.Guides.setupMethod, selection: $manual) {
                    Text(Strings.Guides.setupAutomaticTab).tag(false)
                    Text(Strings.Guides.setupManualTab).tag(true)
                }.pickerStyle(.segmented)
                if !appState.proxyRunning { Button(Strings.Tools.startProxyListener) { appState.startProxy() } }
                if !manual {
                    Text(Strings.Guides.setupAutomaticStepOne).font(.system(size: 14, weight: .semibold))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow {
                            Text(Strings.Guides.setupTerminalApp)
                            HStack {
                                Picker(Strings.Guides.setupTerminalApp, selection: $terminal) {
                                    Text(verbatim: "Apple Terminal").tag(ProxyAutomation.Target.terminal)
                                    Text(verbatim: "iTerm2").tag(ProxyAutomation.Target.iTerm)
                                    Text(verbatim: "Ghostty").tag(ProxyAutomation.Target.ghostty)
                                    Text(Strings.Guides.setupOwnTerminal).tag(ProxyAutomation.Target.customTerminal)
                                }.labelsHidden().frame(width: 180)
                                if terminal == .customTerminal {
                                    Button(Strings.Tools.edit) { editingCommand = true }
                                }
                                Button(Strings.Guides.setupOpenTerminal) { launchTerminal() }
                            }
                        }
                        GridRow {
                            Text(Strings.Guides.setupWebBrowsers)
                            Menu(Strings.Guides.setupOpenBrowser) {
                                Button(Strings.Guides.setupChromeCurrent) { launchCurrentChrome() }
                                Button(Strings.Guides.setupChromeNew) { launch(.chrome) }
                                Button { launch(.firefox) } label: { Text(verbatim: "Firefox…") }
                            }.fixedSize()
                        }
                        GridRow {
                            Text(verbatim: "ElectronJS App:")
                            HStack {
                                Button(Strings.Guides.setupSelectElectron) { chooseElectron() }
                                Text(electron?.lastPathComponent ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                                if electron != nil { Button(Strings.Guides.setupLaunch) { launch(.electron, application: electron) } }
                            }
                        }
                    }.font(.system(size: 13)).disabled(!appState.proxyRunning || busy)
                    Text(Strings.Guides.setupAutomaticStepTwo).font(.system(size: 14, weight: .semibold))
                }
                GuideCodeBlock(code: command)
                Text(Strings.Guides.setupTerminalSupport).font(.system(size: 11)).foregroundStyle(.secondary)
                if busy { ProgressView().controlSize(.small) }
                if !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(error ? .red : .secondary).textSelection(.enabled)
                }
                Text(Strings.Tools.httpsRequiresTrustingTheProxymirrorCaInEachClient)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(30)
        }.frame(minWidth: 700, minHeight: 600)
        .onChange(of: terminal) { value in if value == .customTerminal { editingCommand = true } }
        .sheet(isPresented: $editingCommand) {
            VStack(alignment: .leading, spacing: 14) {
                Text(Strings.Guides.setupOwnTerminal).font(.headline)
                Text(Strings.Guides.setupCustomCommandNote).font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $customCommand).font(.system(size: 12, design: .monospaced)).frame(height: 150)
                HStack { Spacer(); Button(Strings.Tools.done) { editingCommand = false }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 620)
        }
    }

    private func chooseElectron() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        electron = panel.url
    }
    private func launchTerminal() {
        guard terminal == .customTerminal else { launch(terminal); return }
        guard !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { editingCommand = true; return }
        let script = command + "\n" + customCommand
        let authority = appState.certificateAuthority
        busy = true; message = ""
        Task { @MainActor in
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try authority.ensureCA()
                    _ = try DeviceCommandRunner.run("/bin/zsh", ["-lc", script], timeout: 20)
                }.value
                message = Strings.Guides.setupOperationComplete; error = false
            } catch { message = LocalizedErrorPresentation.message(for: error); self.error = true }
        }
    }
    private func launchCurrentChrome() {
        busy = true; message = ""
        Task { @MainActor in
            defer { busy = false }
            do { message = try await ProxyAutomation.launchChromeCurrentProfile(port: appState.listenerPort); error = false }
            catch { message = LocalizedErrorPresentation.message(for: error); self.error = true }
        }
    }
    private func launch(_ target: ProxyAutomation.Target, application: URL? = nil) {
        busy = true; message = Strings.Tools.starting
        Task { @MainActor in
            defer { busy = false }
            do {
                try appState.certificateAuthority.ensureCA()
                message = try await ProxyAutomation.launchAndWait(target, port: appState.listenerPort,
                    certificate: appState.certificateAuthority.caCertPath, application: application)
                error = false
            } catch { message = LocalizedErrorPresentation.message(for: error); self.error = true }
        }
    }
}
