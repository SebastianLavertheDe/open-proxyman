import SwiftUI

/// Topics are shared by the Help menu and the guide's own navigation. Selecting
/// a menu item also updates an already-open guide, so it never lands on a home tab.
enum HelpGuideTopic: String, CaseIterable, Identifiable, Equatable {
    case gettingStarted = "开始使用", noTraffic = "没有流量", https = "HTTPS 与证书"
    case devices = "设备接入", data = "数据与备份", automation = "脚本与自动化"
    var id: String { rawValue }
    var troubleshootingTitle: String {
        switch self {
        case .gettingStarted: return "代理无法启动…"
        case .noTraffic: return "客户端没有流量…"
        case .https: return "HTTPS 解密或证书错误…"
        case .devices: return "设备连接失败…"
        case .data: return "会话、数据与备份恢复…"
        case .automation: return "脚本或自动化异常…"
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
        Menu("故障排查") {
            ForEach(HelpGuideTopic.allCases) { topic in
                Button(topic.troubleshootingTitle) {
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
            Label("内存压力诊断", systemImage: "memorychip").font(.headline)
            Text("系统监测：\(pressure.isMonitoring ? "运行中" : "未启动") · 清理 \(pressure.cleanupCount) 次（系统 \(pressure.systemCount) / 模拟 \(pressure.simulationCount)）")
                .font(.caption).foregroundStyle(.secondary)
            if let event = pressure.lastEvent {
                Text(event.summary).font(.caption).textSelection(.enabled)
                Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                if let released = event.residentBytesReleased {
                    Text("本次采样驻留内存减少：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: released), countStyle: .memory))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("模拟内存警告") { pressure.simulateWarning() }
                .help("执行与 macOS 内存警告相同的可重建缓存清理；保留捕获记录、会话和用户文件")
        }
    }
}
