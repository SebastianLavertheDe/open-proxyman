import Foundation

enum CertificatePlatformGuides {
    struct Link: Identifiable { let title: String; let url: URL; var id: String { url.absoluteString } }
    struct Guide { let steps: [String]; let commands: String; let links: [Link] }

    static let frameworks = ["Java", "NextJS", "Docker", "React Native", "Flutter", "Python", "Ruby", "NodeJS", "Electron", "HTTP Clients", "VPN"]
    static let simulatorPlatforms = ["watchOS", "tvOS", "visionOS", "Xcode Preview (SwiftUI)"]

    static func guide(for platform: String, certificatePath: String, port: Int) -> Guide {
        let proxy = "http://127.0.0.1:\(port)"
        let environment = "PM_CA=\(shellQuote(certificatePath))\nPM_PROXY=\(shellQuote(proxy))\n"
        func link(_ title: String, _ url: String) -> Link { Link(title: title, url: URL(string: url)!) }
        switch platform {
        case "iOS":
            return Guide(steps: [
                "在设备 Wi-Fi 中把 HTTP 代理设为此 Mac 的局域网 IP 和当前监听端口；先在 ProxyMirror 中启用局域网访问并授权设备 IP。",
                "导出 CA 证书并发送到设备。安装描述文件后，在「设置 → 通用 → 关于本机 → 证书信任设置」为此 CA 开启完全信任。",
                "在自己的测试应用发起请求，并为目标域启用 SSL 解密。结束后恢复设备原代理配置。"
            ], commands: "", links: [link("Apple：手动安装证书并开启信任", "https://support.apple.com/en-us/102390")])
        case "Android":
            return Guide(steps: [
                "设备 Wi-Fi 代理指向 Mac 局域网 IP；Android Emulator 通常使用 10.0.2.2。启用局域网监听并授权实际来源 IP。",
                "从「安全 / 加密与凭据 → 安装证书 → CA 证书」安装导出的 CA。Android 新版本的应用通常不会默认信任用户 CA。",
                "自己的 debug 应用可以通过 Network Security Config 的 debug-overrides 信任用户证书。可写模拟器可用菜单中的 adb root 安装流程或仓库中的 Magisk 模块脚本。",
                "ProxyMirror 尚未提供 Android VPN 配套应用。VPN 仅改变路由，不能通用地绕过 Android 系统 CA 写入权限或应用证书固定；不把用户 CA 安装表述为系统 CA 安装。"
            ], commands: "<network-security-config>\n  <debug-overrides>\n    <trust-anchors><certificates src=\"user\" /></trust-anchors>\n  </debug-overrides>\n</network-security-config>", links: [link("Android：Network Security Config", "https://developer.android.com/privacy-and-security/security-config")])
        case "watchOS", "tvOS", "visionOS", "Xcode Preview (SwiftUI)":
            let preview = platform == "Xcode Preview (SwiftUI)"
            return Guide(steps: [
                "在 Xcode 安装对应 Simulator Runtime，启动目标模拟器，然后从 simctl 列表复制它的 UDID。不要把宿主 Mac 的信任设置当作模拟器已安装证书。",
                "执行下方 add-root-cert，并通过「接管系统代理」或应用自身代理配置将请求发送给 ProxyMirror。simctl keychain 是否可用取决于 Xcode 和具体 runtime；以本机 help 和命令结果为准。",
                preview ? "iOS/visionOS Preview 需要在实际承载 Preview 的模拟器 runtime 中信任 CA，随后停止并重建 Canvas。macOS Preview 使用 Mac 信任。若 Preview 隐藏设备未出现在 simctl 列表，可先在可见 Simulator 运行同一应用验证；此入口不承诺自动定位所有 Xcode Preview 版本的隐藏设备。" : "watchOS 还涉及配对 iPhone 和实际网络路径；真机不能用 simctl。tvOS/visionOS 真机请按平台支持的描述文件管理方式安装 CA，并检查代理是否可达。"
            ], commands: environment + "xcrun simctl list devices available\nxcrun simctl help keychain\nPM_SIMULATOR_UDID='替换为目标模拟器的 UDID'\nxcrun simctl keychain \"$PM_SIMULATOR_UDID\" add-root-cert \"$PM_CA\"",
                links: [link("Apple：Simulator", "https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device")])
        case "Java":
            return Guide(steps: [
                "确认 JAVA_HOME 指向应用实际使用的 JDK。复制它的 truststore，再交互式导入测试 CA；保留原 JDK 的信任库。",
                "运行时同时设置 HTTPS/HTTP 代理和复制后的 truststore。keytool 会提示输入该 truststore 的原口令；不把口令写入命令历史。"
            ], commands: environment + "cp \"$JAVA_HOME/lib/security/cacerts\" ./proxymirror-java-cacerts\nkeytool -importcert -alias proxymirror-ca -file \"$PM_CA\" -keystore ./proxymirror-java-cacerts\njava -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=\(port) -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=\(port) -Djavax.net.ssl.trustStore=\"$PWD/proxymirror-java-cacerts\" -jar app.jar",
                links: [link("Oracle：keytool", "https://docs.oracle.com/en/java/javase/25/docs/specs/man/keytool.html")])
        case "NodeJS", "NextJS":
            return Guide(steps: [
                "在 Node.js 进程启动前设置 NODE_EXTRA_CA_CERTS。NODE_USE_ENV_PROXY 需支持此选项的 Node.js 版本（22.21+/24+）；各网络库仍应按其代理 API 检查。",
                platform == "NextJS" ? "下方命令针对 Next.js 的 Node runtime。Edge runtime、浏览器请求和原生模块是不同网络栈；浏览器需使用系统代理，旧 Node 可按项目所用 Undici/HTTP 客户端配置 ProxyAgent。" : "先对测试域验证 HTTP 与 HTTPS。不要使用 NODE_TLS_REJECT_UNAUTHORIZED=0 代替 CA 信任。"
            ], commands: environment + "HTTP_PROXY=\"$PM_PROXY\" HTTPS_PROXY=\"$PM_PROXY\" NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=\"$PM_CA\" " + (platform == "NextJS" ? "npm run dev" : "node app.js"),
                links: [link("Node.js：代理环境与额外 CA", "https://nodejs.org/api/cli.html#node_use_env_proxy1"), link("Undici：ProxyAgent", "https://undici.nodejs.org/#/docs/api/ProxyAgent")])
        case "Python":
            return Guide(steps: [
                "Requests 使用 HTTP_PROXY/HTTPS_PROXY 与 REQUESTS_CA_BUNDLE；需要时把测试 CA 追加到项目自己的 CA bundle 副本，再指向该文件。",
                "urllib/ssl 等标准库使用自己的 SSLContext/SSL_CERT_FILE；其他库可能需要显式设置代理。下方示例针对 Requests，不关闭证书校验。"
            ], commands: environment + "HTTP_PROXY=\"$PM_PROXY\" HTTPS_PROXY=\"$PM_PROXY\" REQUESTS_CA_BUNDLE=\"$PM_CA\" python app.py",
                links: [link("Requests：SSL 与代理", "https://requests.readthedocs.io/en/latest/user/advanced/#ssl-cert-verification")])
        case "Ruby":
            return Guide(steps: [
                "对支持环境代理的 Ruby HTTP 库，可为单次进程设置 http_proxy/https_proxy。证书路径应指向项目的测试 CA bundle。",
                "Net::HTTP 可显式使用 Net::HTTP::Proxy 和 ca_file；不要设置 VERIFY_NONE。实际行为取决于应用使用的 HTTP 库。"
            ], commands: environment + "http_proxy=\"$PM_PROXY\" https_proxy=\"$PM_PROXY\" SSL_CERT_FILE=\"$PM_CA\" ruby app.rb",
                links: [link("Ruby：Net::HTTP", "https://docs.ruby-lang.org/en/master/Net/HTTP.html")])
        case "Docker":
            return Guide(steps: [
                "容器有独立信任库和网络命名空间。把 CA 复制进测试镜像；仅在自己的调试镜像中安装。下方 Dockerfile 片段面向已包含 ca-certificates 的 Debian/Ubuntu 系镜像。",
                "Docker Desktop 中通常通过 host.docker.internal 访问 Mac。确认 ProxyMirror 监听地址、局域网授权和容器来源 IP 允许该连接；Linux Docker 需单独配置 host-gateway。"
            ], commands: "# 将导出的 CA 放在 Docker build context 中\nCOPY proxymirror-ca.pem /usr/local/share/ca-certificates/proxymirror-ca.crt\nRUN update-ca-certificates\nENV HTTP_PROXY=http://host.docker.internal:\(port)\nENV HTTPS_PROXY=http://host.docker.internal:\(port)",
                links: [link("Docker：容器 CA 证书", "https://docs.docker.com/engine/network/ca-certs/")])
        case "React Native":
            return Guide(steps: [
                "iOS 调试构建先在设备/模拟器安装并信任 CA，再设置系统代理。Android debug 构建通过 Network Security Config 的 debug-overrides 信任用户 CA。",
                "Android Emulator 使用 10.0.2.2，真机使用 Mac 局域网 IP；两端均需能访问端口 \(port)。网络安全配置必须被 debug Manifest 的 android:networkSecurityConfig 引用。",
                "React Native fetch 依赖平台原生网络栈；使用自带证书固定的库时，需要该调试构建提供可测试配置。不要把放宽信任配置加入 release 构建。"
            ], commands: "<network-security-config>\n  <debug-overrides>\n    <trust-anchors><certificates src=\"user\" /></trust-anchors>\n  </debug-overrides>\n</network-security-config>",
                links: [link("React Native：Networking", "https://reactnative.dev/docs/network"), link("Android：Debug CA", "https://developer.android.com/privacy-and-security/security-config#debug-overrides")])
        case "Flutter":
            return Guide(steps: [
                "Dart HttpClient 可以显式指定 findProxy，并用 SecurityContext 添加导出的测试 CA。把 PEM 声明为 debug 项目的 asset。",
                "下方 10.0.2.2 面向 Android Emulator；iOS Simulator 可按实际连通性使用 127.0.0.1，真机使用 Mac 局域网 IP。插件原生请求需要单独配置。"
            ], commands: "import 'dart:io';\nimport 'package:flutter/services.dart';\n\nfinal ca = await rootBundle.load('assets/proxymirror-ca.pem');\nfinal context = SecurityContext(withTrustedRoots: true);\ncontext.setTrustedCertificatesBytes(\n  ca.buffer.asUint8List(ca.offsetInBytes, ca.lengthInBytes),\n);\nfinal client = HttpClient(context: context)\n  ..findProxy = (_) => 'PROXY 10.0.2.2:\(port)';",
                links: [link("Dart：HttpClient.findProxy", "https://api.dart.dev/dart-io/HttpClient/findProxy.html"), link("Dart：SecurityContext", "https://api.dart.dev/dart-io/SecurityContext-class.html")])
        case "Electron":
            return Guide(steps: [
                "在 app ready 后、创建 BrowserWindow 前，对其实际使用的 session 调用 setProxy。renderer 使用 Chromium 的信任链，应在 Mac 上安装并信任 CA。",
                "主进程的 Node HTTP 请求需另配 Node 代理与 CA。不要用忽略所有证书错误的开关替代信任配置。"
            ], commands: "const { app, session, BrowserWindow } = require('electron');\napp.whenReady().then(async () => {\n  await session.defaultSession.setProxy({\n    proxyRules: 'http=127.0.0.1:\(port);https=127.0.0.1:\(port)',\n  });\n  const window = new BrowserWindow();\n  await window.loadURL('https://example.com');\n});",
                links: [link("Electron：session.setProxy", "https://www.electronjs.org/docs/latest/api/session#sessetproxyconfig")])
        case "HTTP Clients":
            return Guide(steps: [
                "在 Postman / Insomnia / Paw 的代理设置中填写 HTTP 代理 127.0.0.1:\(port)，并检查客户端自己的 bypass 列表。",
                "在客户端 CA 管理中添加导出的 ProxyMirror CA；使用 macOS 信任库的客户端可从证书菜单安装到 Mac。代理服务端 CA 与 mTLS 客户端身份是两个独立设置。",
                "发送测试请求，核对 ProxyMirror 中的解密流量和状态；保持客户端 SSL 校验开启。"
            ], commands: environment + "curl --proxy \"$PM_PROXY\" --cacert \"$PM_CA\" https://example.com/",
                links: [link("Postman：代理配置", "https://learning.postman.com/docs/getting-started/installation/proxy/")])
        case "VPN":
            return Guide(steps: [
                "VPN 路由、系统 HTTP 代理和 ProxyMirror 透明代理分别生效；确认 VPN 允许应用访问本机代理端口。先用显式 curl 代理确认链路。",
                "应用忽略系统代理时，使用它支持的显式代理配置，或在已签名的 ProxyMirror 中验证透明代理扩展与 VPN 的兼容性。",
                "配置 CA 不会自动解决证书固定、VPN 流量隧道或 QUIC。针对自己的测试应用选择其支持的 HTTPS 代理路径，并核对实际捕获。"
            ], commands: environment + "curl --proxy \"$PM_PROXY\" --cacert \"$PM_CA\" https://example.com/",
                links: [link("Apple：Network Extension", "https://developer.apple.com/documentation/networkextension")])
        case "Firefox":
            return Guide(steps: [
                "Firefox → 设置 → 网络设置：手动代理 127.0.0.1:\(port)，同时用于 HTTPS。检查不使用代理的地址列表。",
                "隐私与安全 → 证书 → 查看证书 → 证书颁发机构 → 导入 CA，并允许它识别网站。Firefox 的证书管理与 Mac 信任库可能独立。"
            ], commands: "", links: [link("Mozilla：Firefox 证书", "https://support.mozilla.org/en-US/kb/setting-certificate-authorities-firefox")])
        default: return Guide(steps: ["选择证书菜单中的具体平台，以查看对应网络栈的代理与 CA 配置。"], commands: "", links: [])
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
