import Foundation

enum SettingsSearchTarget: String, CaseIterable, Identifiable {
    case listenPort, autoStart, autoTakeOver, followLatest, appearance, lan, applyListener, systemProxy
    case decryptHTTPS, http2, caCertificate, fingerprint, excludedHosts, clientCertificate
    case bodyLimit, transactionLimit, restart, upstreamProxy, displayBehavior, copyBehavior, bypassProxy
    case contentLayout, recording, menuBar, truncation, appBehavior, language, privacy, mcp, networkExtension, cleanup, github, workspace, products
    case h2c, appleTraffic, mcpPrivacy

    var id: Self { self }

    // 双语检索别名是搜索数据，不作为界面文案显示。
    private var entry: (page: PreferencesPage, title: String, keywords: String) {
        switch self {
        case .listenPort: return (.general, Strings.Settings.proxyPort, "代理端口 Proxy port proxy listen port localhost 9090 监听")
        case .autoStart: return (.advanced, Strings.Settings.startListeningWhenProxymirrorLaunches, "打开 App 时自动启动监听 Start listening when ProxyMirror launches auto start launch startup 自动启动")
        case .autoTakeOver: return (.general, Strings.Settings.setTheSystemProxyAtLaunch, "启动时自动接管系统代理 Set the system proxy at launch auto takeover macOS system proxy 自动接管")
        case .followLatest: return (.advanced, Strings.Settings.followLatestRequest, "自动滚动到最新请求 Follow Latest Request auto scroll follow latest request 选中新请求")
        case .appearance: return (.appearance, Strings.Settings.applicationTheme, "应用主题 Application Theme appearance theme dark light system 主题 深色 浅色")
        case .lan: return (.advanced, Strings.Settings.lanProxyDevices, "局域网代理与设备地址 LAN Proxy & Devices LAN Wi-Fi WiFi network device IPv4 address 本机地址 IP 地址 手机")
        case .applyListener: return (.advanced, Strings.Settings.applyListenerSettings, "应用监听设置 Apply Listener Settings apply listen bind address port 重绑端口")
        case .systemProxy: return (.advanced, Strings.Settings.systemProxyHelper, "系统代理与辅助工具 System Proxy & Helper macOS system proxy HTTP HTTPS helper service 管理员 授权 后台服务 卸载")
        case .decryptHTTPS: return (.advanced, Strings.Settings.httpsDecryption, "HTTPS 解密 HTTPS Decryption TLS MITM intercept decryption 抓包 中间人")
        case .http2: return (.general, Strings.Settings.http2Negotiation, "HTTP/2 协商 HTTP/2 Negotiation HTTP2 h2 ALPN protocol HTTPS 多路复用 协议")
        case .caCertificate: return (.general, Strings.Settings.installTrustCaCertificate, "安装和信任 CA 证书 Install & Trust CA Certificate certificate CA root trust keychain 钥匙串 根证书 导出 Finder")
        case .fingerprint: return (.general, Strings.Settings.certificateSha256Fingerprint, "证书 SHA-256 指纹 Certificate SHA-256 Fingerprint certificate fingerprint sha256 hash 校验")
        case .excludedHosts: return (.advanced, Strings.Settings.hostsExcludedFromDecryption, "不解密的主机 Hosts Excluded from Decryption exclude host bypass SSL TLS wildcard 域名 通配符 排除")
        case .clientCertificate: return (.advanced, Strings.Settings.upstreamClientCertificates, "上游客户端证书 Upstream Client Certificates mTLS mutual TLS client certificate PEM private key 双向认证 客户端身份 私钥")
        case .bodyLimit: return (.advanced, Strings.Settings.bodyCaptureLimit, "正文捕获上限 Body Capture Limit body capture limit size MB binary payload 请求响应 正文 容量 截断")
        case .transactionLimit: return (.advanced, Strings.Settings.maximumRetainedRequests2, "最大保留请求数 Maximum Retained Requests traffic request transaction limit history 留存 流量 容量")
        case .restart: return (.advanced, Strings.Settings.applyRestartProxy, "应用并重启代理 Apply & Restart Proxy apply restart reload proxy 重启 重新加载")
        case .upstreamProxy: return (.advanced, Strings.Settings.externalProxyPac, "外部代理与 PAC External Proxy & PAC upstream external proxy HTTP HTTPS CONNECT SOCKS5 bypass PAC proxy auto config 上游代理 自动代理配置 直连 转发 绕过")
        case .displayBehavior: return (.appearance, Strings.Settings.userInterfaceBodies, "应用界面与正文 User Interface & Bodies Proxyman compatible shortcuts keyboard 兼容 快捷键 resource usage memory upload download word wrap minimap invisibles font size monospace family tab width 24hour 12hour date zebra alternating rows Use monospaced font Show hidden characters Show minimap Scroll beyond last line Show resource usage Use 24-hour time Show full date and time Alternating row backgrounds 内存 速率 换行 空白字符 缩略导航 隐藏字符 字体 等宽字体 Tab宽度 制表符 24小时 12小时 小时制 完整日期 斑马纹")
        case .copyBehavior: return (.tools, Strings.Settings.copyRepeat, "复制与重放 Copy & Repeat preserve original headers add proxy curl no cache repeat diagnostic headers default copy format command C Disable cache when repeating requests 复制 重发 缓存 诊断头 默认复制 默认 复制格式 原始请求头")
        case .bypassProxy: return (.advanced, Strings.Settings.systemProxyBypass, "系统代理旁路 System Proxy Bypass bypass exceptions macOS proxy 域名 绕过 旁路 捕获本机请求 回环 Capture local requests Chrome Chromium localhost loopback 127.0.0.1")
        case .contentLayout: return (.general, Strings.Settings.contentLayout2, "内容布局 Content layout content layout request response horizontal vertical 请求 响应 垂直 水平")
        case .recording: return (.general, Strings.Settings.startRecordingTrafficAtLaunch, "启动时自动开始记录流量 Start recording traffic at launch Start recording traffic at launch startup capture 录制 记录 自动")
        case .menuBar: return (.general, Strings.Settings.menuBarIcon, "菜单栏图标 Menu Bar Icon menu bar icon 托盘")
        case .truncation: return (.general, Strings.Settings.truncationStyle2, "截断样式 Truncation style truncate truncation head middle tail 开头 中间 尾部 末尾")
        case .appBehavior: return (.general, Strings.Settings.applicationBehavior, "应用行为 Application behavior application behavior Warn before quitting Show update notifications at launch quit warning confirmation 退出 警报 更新 通知")
        case .language: return (.general, Strings.Settings.applicationLanguage, "应用语言 Application language language locale English Chinese 中文 英文 简体")
        case .privacy: return (.privacy, Strings.Settings.privacyRedaction, "隐私与脱敏 Privacy & Redaction privacy redact sensitive authorization cookie token 敏感头 隐私 脱敏")
        case .mcp: return (.mcp, Strings.Settings.mcpServer, "MCP 服务器 MCP Server model context protocol AI Claude Codex stdio HTTP 配置 启动 停止")
        case .networkExtension: return (.networkExtension, Strings.Settings.networkExtension, "网络扩展 Network Extension transparent proxy network extension capture 透明抓包 签名 系统扩展")
        case .cleanup: return (.advanced, Strings.Settings.automaticallyRemoveOldRequests, "自动移除较早的请求 Automatically remove old requests Automatically remove old requests automatic cleanup memory retention interval 内存 清理 自动 移除 旧请求")
        case .github: return (.github, "GitHub Gist", "GitHub Gist GitHub Gist GitHub Gist token sharing 分享 发布")
        case .workspace: return (.workspace, Strings.Settings.workspaceBackup, "Workspace 与备份 Workspace & Backup workspace views session backup restore 工作区 视图 会话 备份 恢复")
        case .products: return (.products, Strings.Settings.productVersion, "产品与版本 Product & Version about version releases product 关于 版本 更新 产品")
        case .h2c: return (.advanced, Strings.Settings.http2CleartextUpstreamH2c, "HTTP/2 明文上游 (h2c) HTTP/2 Cleartext Upstream (h2c) HTTP2 h2c plaintext cleartext upstream 明文上游")
        case .appleTraffic: return (.advanced, Strings.Settings.hideAppleTrafficFromIosSimulators, "隐藏 iOS 模拟器中的 Apple 流量 Hide Apple traffic from iOS Simulators Apple traffic filter simulator 后台 流量 过滤")
        case .mcpPrivacy: return (.mcp, Strings.Settings.mcpPrivacyRedaction, "MCP 隐私与脱敏 MCP Privacy & Redaction MCP AI privacy redact sensitive headers 敏感头 隐私 脱敏")
        }
    }

    var page: PreferencesPage { entry.page }
    var title: String { entry.title }
    var tabTitle: String { page.title }
    var opensConnectionSettings: Bool {
        [.autoStart, .lan, .applyListener, .followLatest, .bodyLimit, .transactionLimit,
         .decryptHTTPS, .excludedHosts, .clientCertificate, .restart, .upstreamProxy, .bypassProxy, .h2c].contains(self)
    }

    static func results(for query: String) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return allCases.filter { item in
            let text = [item.title, item.tabTitle, item.page.searchAliases, item.entry.keywords].joined(separator: " ")
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }
}
