import SwiftUI
import AppKit

struct HelpGuideView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var guide = HelpGuideCoordinator.shared
    private var topic: String { guide.topic.rawValue }
    var body: some View {
        HSplitView {
            List(HelpGuideTopic.allCases) { candidate in
                Button { guide.show(candidate) } label: {
                    Text(candidate.rawValue).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.buttonStyle(.plain)
                    .listRowBackground(guide.topic == candidate ? Color.accentColor.opacity(0.15) : .clear)
            }.frame(width: 160)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(topic).font(.title2.bold())
                    Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    HStack {
                        Button("复制调试信息") { appState.copyText(AppDiagnostics.debugInfo()) }
                        Button("数据文件夹") { AppDiagnostics.openDataFolder() }
                        Button("备份文件夹") { AppDiagnostics.openDataFolder(backups: true) }
                    }
                    if topic == "没有流量" || topic == "开始使用" {
                        Button(appState.proxyRunning ? "打开代理状态" : "启动监听") {
                            if appState.proxyRunning { appState.systemProxyMessage = AppDiagnostics.debugInfo() }
                            else { appState.startProxy() }
                        }
                    }
                    if topic == "HTTPS 与证书" {
                        Button("安装并信任本机 CA…") { appState.installCACertificate() }
                        Button("显示 CA 文件") { appState.revealCAFile() }
                    }
                    Divider()
                    MemoryPressureStatusView()
                    Link("项目文档与问题反馈", destination: URL(string: "https://github.com/SebastianLavertheDe/open-proxyman")!)
                }.padding(22)
            }.frame(minWidth: 460)
        }.frame(minWidth: 680, minHeight: 430)
    }

    private var content: String {
        switch topic {
        case "开始使用": return "1. 启动监听并检查状态栏端口。\n2. 从系统代理状态中接管 macOS 代理，或单独为测试客户端指定 http://127.0.0.1:\(appState.settings.port)。\n3. HTTPS 抓包先安装并信任 CA，再确认全局 MITM 和域名 SSL 规则已启用。\n4. 发出测试请求，选择列表记录查看正文、原文、耗时和连接日志。\n5. 调试结束后恢复系统代理并停止监听。"
        case "没有流量": return "检查监听是否启动、录制是否暂停以及端口是否一致。确认客户端使用 HTTP 或 SOCKS5 代理；透明抓包需要带签名网络扩展的版本。清除来源选择、搜索、过滤器、Hide Apple Traffic 等显示条件。\n\n部分客户端自行管理网络配置；可通过 Automation Dashboard 启动独立浏览器或终端，并使用 curl --proxy http://127.0.0.1:\(appState.settings.port) <测试URL> 验证。外部代理和 DNS 规则的命中记录见 Connection Log。"
        case "HTTPS 与证书": return "安装 CA 后确认钥匙串信任状态，检查 CA 有效期和指纹。全局 HTTPS 解密、SSL Proxying List、按应用规则、不解密主机及工具总开关共同决定新连接行为；修改后需让客户端重连。\n\n如果客户端拒绝测试 CA 或存在证书锁定，可在详情中为应用或域名选择透传。透传只显示隧道元数据。重置 CA 会要求客户端重新信任，已有会话内容继续保留。"
        case "设备接入": return "在常规设置选择 Mac 的局域网监听地址，添加设备 IP / CIDR 白名单并应用。设备与 Mac 需网络可达，设备代理地址填写所选 Mac 地址和监听端口。HTTPS 还需在设备上安装并信任该 Mac 的 CA。\n\nAndroid Emulator 可使用 10.0.2.2 访问宿主回环端口；应用是否接受用户 CA 取决于调试网络安全配置。各平台和框架的具体步骤见证书菜单。"
        case "数据与备份": return "活动会话请使用「文件 → 保存会话」，重要请求可存入 Saved Folder。清空捕获列表不等于会话已导出。应用使用保留条数和正文上限控制内存，正文截断后无法恢复未捕获字节。\n\n规则与设置备份包含工具配置和 Protobuf 描述符；私钥与钥匙串 Token 单独保管。恢复默认设置前会在 Backups 中自动保存规则备份。可使用工具菜单的规则与设置备份预览，再选择合并或替换恢复。会话文件从「文件 → 打开」恢复。"
        default: return "脚本在独立 worker 内限时执行。Console 可按错误、警告、用户及系统日志过滤；修改后用 ⌘S 保存启用，⌘B 格式化。require 支持内置模块和受控本地 Addons，未提供完整 Node 文件系统或 npm 安装器。sharedState 可在脚本窗口重置。\n\nMCP 连接配置见帮助菜单。HTTP 端点仅在回环地址开放并需要本次启动令牌，stdio 使用 proxymirror-cli mcp stdio。增量查询用最后读到的 flow ID 继续翻页。"
        }
    }
}
