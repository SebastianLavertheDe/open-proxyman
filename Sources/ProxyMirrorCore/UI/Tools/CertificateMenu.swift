import SwiftUI

/// 证书菜单的安装指南弹窗（iOS/Android/Java/Firefox 等平台的证书安装指引）
struct CertificateGuideSheet: View {
    let platform: String
    @Environment(\.dismiss) private var dismiss

    private var steps: [String] {
        switch platform {
        case "iOS":
            return [
                "1. 点击下方「导出 CA 证书」，将 proxymirror-ca.pem 通过 AirDrop/邮件 发送到 iPhone",
                "2. iPhone 上打开该文件 → 设置 → 已下载的描述文件 → 安装",
                "3. 设置 → 通用 → 关于本机 → 证书信任设置 → 开启 ProxyMirror CA 的完全信任",
            ]
        case "Android":
            return [
                "1. 点击下方「导出 CA 证书」，将 proxymirror-ca.pem 发送到 Android 设备",
                "2. 设置 → 安全 → 加密与凭据 → 安装证书 → CA 证书",
                "3. 选择导出的 .pem 文件完成安装（应用需自行配置使用用户证书）",
            ]
        case "Java":
            return [
                "1. 点击下方「导出 CA 证书」",
                "2. 执行: keytool -importcert -alias ProxyMirrorCA -file proxymirror-ca.pem \\\n        -keystore $JAVA_HOME/lib/security/cacerts -storepass changeit",
            ]
        case "Firefox":
            return [
                "1. 点击下方「导出 CA 证书」",
                "2. Firefox → 设置 → 隐私与安全 → 证书 → 查看证书 → 导入",
                "3. 选择 proxymirror-ca.pem，勾选「信任使用此 CA 标识网站」",
            ]
        default:
            return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在 \(platform) 上安装证书")
                .font(.system(size: 14, weight: .semibold))
            ForEach(steps, id: \.self) { step in
                Text(step)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("导出 CA 证书") { CertInstaller.exportCA(extension: "pem") }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

/// 证书菜单（对齐 Proxyman：安装/自定义/导出/重置）
struct CertificateMenuContent: View {
    var body: some View {
        Button("在此 Mac 上安装证书…") {
            AppState.shared.installCACertificate()
        }
        Menu("在 iOS 上安装证书") {
            Button("一键配置 iOS 模拟器…") { AppState.shared.runSimulatorAutomation() }
            Button("安装指南…") { AppState.shared.certificateGuide = "iOS" }
        }
        Menu("在 Android 上安装证书") {
            Button("通过 adb 复制用户 CA…") { AppState.shared.prepareAndroidUserCertificate() }
            Button("Android 模拟器自动化（adb root）…") { AppState.shared.runAndroidEmulatorAutomation() }
            Button("安装指南…") { AppState.shared.certificateGuide = "Android" }
        }
        Menu("在 Java 虚拟机上安装证书") {
            Button("安装指南…") { AppState.shared.certificateGuide = "Java" }
        }
        Menu("在开发中安卓浏览器上安装证书") {
            Button("安装指南…") { AppState.shared.certificateGuide = "Android" }
        }
        Menu("在 Firefox 浏览器上安装证书") {
            Button("安装指南…") { AppState.shared.certificateGuide = "Firefox" }
        }
        Divider()
        Button("按域名自定义服务端证书…") { AppState.shared.openTool(.customCertificates) }
        Button("导入自定义根证书 (PEM + 私钥)…") { CertInstaller.importRootCA() }
        Button("添加自定义证书…") { CertInstaller.importCustomCertificate() }
        Button("导入上游 CA 信任链 (.pem)…") {
            let panel = NSOpenPanel()
            panel.message = "选择代理连接 HTTPS 上游时信任的 PEM 根证书链"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try UpstreamTrust.install(Data(contentsOf: url))
                AppState.shared.systemProxyMessage = "已更新新连接使用的上游 CA 信任链。"
            } catch {
                AppState.shared.systemProxyMessage = "导入上游 CA 失败：\(error.localizedDescription)"
            }
        }
        Button("移除自定义上游 CA 信任链") {
            do {
                try UpstreamTrust.reset()
                AppState.shared.systemProxyMessage = "新建上游连接已恢复系统根证书。"
            } catch {
                AppState.shared.systemProxyMessage = "移除上游 CA 失败：\(error.localizedDescription)"
            }
        }
        Divider()
        Menu("导出") {
            Button("CA 证书 (.pem)") { CertInstaller.exportCA(extension: "pem") }
            Button("CA 证书 (.cer)") { CertInstaller.exportCA(extension: "cer") }
        }
        Divider()
        Button("重置所有 ProxyMirror 证书…") {
            AppState.shared.showResetCA = true
        }
    }
}

struct GuidePlatformBox: Identifiable {
    let value: String
    var id: String { value }
}

struct ResetCAConfirmView: View {
    let onConfirm: () -> Void
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重置所有 ProxyMirror 证书")
                .font(.system(size: 14, weight: .semibold))
            Text("将删除钥匙串中的 ProxyMirror CA 并重新生成新证书。\n此前「已解密」的历史会话仍可查看，但需重新信任新 CA。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("取消") { onConfirm() }
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重置") {
                        working = true
                        CertInstaller.resetAll {
                            working = false
                            onConfirm()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
