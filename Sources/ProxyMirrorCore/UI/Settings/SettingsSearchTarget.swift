import Foundation

enum SettingsSearchTarget: String, CaseIterable, Identifiable {
    case listenPort, autoStart, autoTakeOver, followLatest, appearance, lan, applyListener, systemProxy
    case decryptHTTPS, http2, caCertificate, fingerprint, excludedHosts, clientCertificate
    case bodyLimit, transactionLimit, restart, upstreamProxy

    var id: Self { self }

    private var entry: (tab: Int, title: String, keywords: String) {
        switch self {
        case .listenPort: return (0, "代理端口", "proxy listen port localhost 9090 监听")
        case .autoStart: return (0, "打开 App 时自动启动监听", "auto start launch startup 自动启动")
        case .autoTakeOver: return (0, "监听启动后自动接管系统代理", "auto takeover macOS system proxy 自动接管")
        case .followLatest: return (0, "自动滚动到最新请求", "auto scroll follow latest request 选中新请求")
        case .appearance: return (0, "外观", "appearance theme dark light system 主题 深色 浅色")
        case .lan: return (0, "局域网代理与设备地址", "LAN Wi-Fi WiFi network device IPv4 address 本机地址 IP 地址 手机")
        case .applyListener: return (0, "应用监听设置", "apply listen bind address port 重绑端口")
        case .systemProxy: return (0, "系统代理", "macOS system proxy HTTP HTTPS 管理员 授权")
        case .decryptHTTPS: return (1, "HTTPS 解密", "TLS MITM intercept decryption 抓包 中间人")
        case .http2: return (1, "HTTP/2 协商与 h2c 上游", "HTTP2 h2 h2c ALPN protocol HTTPS plaintext cleartext 明文上游 多路复用 协议")
        case .caCertificate: return (1, "安装和信任 CA 证书", "certificate CA root trust keychain 钥匙串 根证书 导出 Finder")
        case .fingerprint: return (1, "证书 SHA-256 指纹", "certificate fingerprint sha256 hash 校验")
        case .excludedHosts: return (1, "不解密的主机", "exclude host bypass SSL TLS wildcard 域名 通配符 排除")
        case .clientCertificate: return (1, "上游客户端证书", "mTLS mutual TLS client certificate PEM private key 双向认证 客户端身份 私钥")
        case .bodyLimit: return (2, "正文捕获上限", "body capture limit size MB binary payload 请求响应 正文 容量 截断")
        case .transactionLimit: return (2, "最大保留请求数", "traffic request transaction limit history 留存 流量 容量")
        case .restart: return (2, "应用并重启代理", "apply restart reload proxy 重启 重新加载")
        case .upstreamProxy: return (2, "外部代理与 PAC", "upstream external proxy HTTP HTTPS CONNECT SOCKS5 bypass PAC proxy auto config 上游代理 自动代理配置 直连 转发 绕过")
        }
    }

    var tab: Int { entry.tab }
    var title: String { entry.title }
    var tabTitle: String {
        switch tab {
        case 0: return "General · 常规"
        case 1: return "SSL · 证书与协议"
        default: return "Advanced · 高级"
        }
    }

    static func results(for query: String) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return allCases.filter { item in
            let text = [item.title, item.tabTitle, item.entry.keywords].joined(separator: " ")
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }
}
