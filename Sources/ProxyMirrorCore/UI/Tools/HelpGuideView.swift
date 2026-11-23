import SwiftUI
import AppKit

struct HelpGuideView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var guide = HelpGuideCoordinator.shared
    private var topic: HelpGuideTopic { guide.topic }
    var body: some View {
        HSplitView {
            List(HelpGuideTopic.allCases) { candidate in
                Button { guide.show(candidate) } label: {
                    Text(candidate.localizedTitle).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.buttonStyle(.plain)
                    .listRowBackground(guide.topic == candidate ? Color.accentColor.opacity(0.15) : .clear)
            }.frame(minWidth: 190, idealWidth: 210, maxWidth: 280)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(topic.localizedTitle).font(.title2.bold())
                    Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    HStack {
                        Button(Strings.Help.copyDebugInformation) { appState.copyText(AppDiagnostics.debugInfo()) }
                        Button(Strings.Help.dataFolder) { AppDiagnostics.openDataFolder() }
                        Button(Strings.Help.backupFolder) { AppDiagnostics.openDataFolder(backups: true) }
                    }
                    if topic == .noTraffic || topic == .gettingStarted {
                        Button((appState.proxyRunning ? Strings.Help.openProxyStatus : Strings.Help.startListening)) {
                            if appState.proxyRunning { appState.systemProxyMessage = AppDiagnostics.debugInfo() }
                            else { appState.startProxy() }
                        }
                    }
                    if topic == .https {
                        Button(Strings.Help.installTrustLocalCa) { appState.installCACertificate() }
                        Button(Strings.Help.showCaFile) { appState.revealCAFile() }
                    }
                    Divider()
                    MemoryPressureStatusView()
                    Link(Strings.Help.documentationFeedback, destination: URL(string: "https://github.com/SebastianLavertheDe/open-proxyman")!)
                }.padding(22)
            }.frame(minWidth: 460)
        }.frame(minWidth: 680, minHeight: 430)
    }

    private var content: String {
        switch topic {
        case .gettingStarted: return Strings.Help.gettingStartedContent(Int(appState.listenerPort))
        case .noTraffic: return Strings.Help.noTrafficContent(Int(appState.listenerPort))
        case .https: return Strings.Help.httpsContent
        case .devices: return Strings.Help.devicesContent
        case .data: return Strings.Help.dataContent
        default: return Strings.Help.automationContent
        }
    }
}
