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
    private var rates = TransferRateMeter()

    func sample(up: Int64, down: Int64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        rates.sample(up: up, down: down, now: now)
        upload = rates.upload
        download = rates.download
        if let resident = MemoryPressureController.residentMemory() { memory = Int64(clamping: resident) }
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
            .help(Strings.Tools.appResidentMemoryCapturedUploadDownloadSpeeds)
            .onReceive(timer) { _ in
                let totals = store.cumulativeTransferredBytes
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
        } catch { AppState.shared.systemProxyMessage = LocalizedErrorPresentation.message(for: error) }
    }
    static func debugInfo() -> String {
        let state = AppState.shared
        return """
        ProxyMirror \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        architecture: \(MemoryLayout<Int>.size * 8)-bit
        listening: \(state.proxyRunning), recording: \(state.recordingEnabled)
        systemProxy: \(state.systemProxyActive), port: \(state.listenerPort)
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
            throw SystemProxyError(Strings.Tools.stopTheListenerAndTransparentCaptureThenRestoreThe)
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
        for key in defaults.dictionaryRepresentation().keys where ["ui.", "proxy.", "capture.", "export.", "repeat.", "automation.", "updates."]
            .contains(where: { key.hasPrefix($0) }) { defaults.removeObject(forKey: key) }
        AppState.shared.settings.objectWillChange.send()
        AppState.shared.systemProxyMessage = Strings.Tools.preferencesRestoredTheRuleBackupIsInTheBackups
    }
}

struct FactoryResetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keepRules = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Strings.Tools.restoreDefaults).font(.headline)
            Text(Strings.Tools.rulesAreBackedUpBeforeRestoringDefaultsSavedSessions)
            Toggle(Strings.Tools.keepRules, isOn: $keepRules)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button(Strings.Tools.cancel) { dismiss() }
                Button(Strings.Tools.restoreDefaults2, role: .destructive) {
                    do { try AppDiagnostics.factoryReset(keepRules: keepRules); dismiss() }
                    catch { self.error = LocalizedErrorPresentation.message(for: error) }
                }
            }
        }.padding(20).frame(width: 420)
    }
}
