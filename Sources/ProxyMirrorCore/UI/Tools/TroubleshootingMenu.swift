import SwiftUI

/// Topics are shared by the Help menu and the guide's own navigation. Selecting
/// a menu item also updates an already-open guide, so it never lands on a home tab.
enum HelpGuideTopic: String, CaseIterable, Identifiable, Equatable {
    case gettingStarted, noTraffic, https
    case devices, data, automation
    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .gettingStarted: return Strings.Help.gettingStarted
        case .noTraffic: return Strings.Help.noTraffic
        case .https: return Strings.Help.httpsCertificates
        case .devices: return Strings.Help.deviceSetup
        case .data: return Strings.Help.dataBackups
        case .automation: return Strings.Help.scriptsAndAutomation
        }
    }
    var troubleshootingTitle: String {
        switch self {
        case .gettingStarted: return Strings.Help.proxyCannotStart
        case .noTraffic: return Strings.Help.noClientTraffic
        case .https: return Strings.Help.httpsOrCertificateErrors
        case .devices: return Strings.Help.deviceConnectionFailed
        case .data: return Strings.Help.recoverSessionsDataBackups
        case .automation: return Strings.Help.scriptOrAutomationErrors
        }
    }
}

@MainActor
final class HelpGuideCoordinator: ObservableObject {
    static let shared = HelpGuideCoordinator()
    @Published private(set) var topic = HelpGuideTopic.gettingStarted
    func show(_ topic: HelpGuideTopic) { self.topic = topic }
}

struct TroubleshootingMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Menu(Strings.Help.troubleshooting) {
            ForEach(HelpGuideTopic.allCases) { topic in
                Button((topic.troubleshootingTitle)) {
                    HelpGuideCoordinator.shared.show(topic)
                    openWindow(id: "help-guide")
                }
            }
        }
    }
}

struct MemoryPressureStatusView: View {
    @ObservedObject private var pressure = MemoryPressureController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Strings.Help.memoryPressureDiagnostics, systemImage: "memorychip").font(.headline)
            Text(Strings.Help.memoryMonitoringStatus(String(describing: (pressure.isMonitoring ? Strings.Help.running : Strings.Help.notStarted)), Int(pressure.cleanupCount), Int(pressure.systemCount), Int(pressure.simulationCount)))
                .font(.caption).foregroundStyle(.secondary)
            if let event = pressure.lastEvent {
                Text(event.summary).font(.caption).textSelection(.enabled)
                Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                if let released = event.residentBytesReleased {
                    Text(Strings.Help.residentMemoryReleased(String(describing: ByteCountFormatter.string(fromByteCount: Int64(clamping: released), countStyle: .memory))))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(Strings.Help.simulateMemoryWarning) { pressure.simulateWarning() }
                .help(Strings.Help.clearRebuildableCachesAsWithAMacosMemoryWarning)
        }
    }
}
