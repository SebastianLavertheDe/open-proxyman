import SwiftUI

/// 证书菜单的安装指南弹窗（iOS/Android/Java/Firefox 等平台的证书安装指引）
struct CertificateGuideSheet: View {
    let platform: String
    @Environment(\.dismiss) private var dismiss

    private var guide: CertificatePlatformGuides.Guide {
        CertificatePlatformGuides.guide(for: platform, certificatePath: CertificateAuthority.shared.caCertPath.path,
                                       port: AppSettings.shared.port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在 \(platform) 上安装证书")
                .font(.system(size: 14, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    if !guide.commands.isEmpty {
                        Text(guide.commands).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        Button("复制配置示例") { AppState.shared.copyText(guide.commands) }
                    }
                    ForEach(guide.links) { link in Link(link.title, destination: link.url) }
                }
            }.frame(maxHeight: 480)
            HStack {
                Button("导出 CA 证书") { CertInstaller.exportCA(extension: "pem") }
                    .buttonStyle(.borderedProminent)
                if platform == "iOS" || CertificatePlatformGuides.simulatorPlatforms.contains(platform) {
                    Button("选择模拟器并安装 CA…") { CertificateToolWindows.showSimulatorInstaller(platform: platform) }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 680)
    }
}

/// 证书菜单（对齐 Proxyman：安装/自定义/导出/重置）
struct CertificateMenuContent: View {
    var body: some View {
        Group {
        Button("在此 Mac 上安装证书…") {
            AppState.shared.installCACertificate()
        }
        Menu("在 iOS 上安装证书") {
            Button("一键配置 iOS 模拟器…") { AppState.shared.runSimulatorAutomation() }
            Button("选择模拟器并安装 CA…") { CertificateToolWindows.showSimulatorInstaller(platform: "iOS") }
            Button("安装指南…") { AppState.shared.certificateGuide = "iOS" }
        }
        Menu("在 Android 上安装证书") {
            Button("通过 adb 复制用户 CA…") { AppState.shared.prepareAndroidUserCertificate() }
            Button("Android 模拟器自动化（adb root）…") { AppState.shared.runAndroidEmulatorAutomation() }
            Button("安装指南…") { AppState.shared.certificateGuide = "Android" }
        }
        Menu("其他 Apple 平台 / SwiftUI Preview") {
            ForEach(CertificatePlatformGuides.simulatorPlatforms, id: \.self) { platform in
                Menu(platform) {
                    Button("选择设备并安装 CA…") { CertificateToolWindows.showSimulatorInstaller(platform: platform) }
                    Button("配置指南…") { AppState.shared.certificateGuide = platform }
                }
            }
        }
        Menu("开发框架与工具接入") {
            ForEach(CertificatePlatformGuides.frameworks, id: \.self) { framework in
                Button(framework + "…") { AppState.shared.certificateGuide = framework }
            }
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
        }
        Divider()
        Group {
        Button("证书导入向导（PEM / DER / P12）…") { CertificateToolWindows.showImporter() }
        Button("导入上游 mTLS 身份…") { CertificateToolWindows.showImporter(purpose: .client) }
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
        }
        Divider()
        Menu("导出") {
            Button("CA 证书 (.pem)") { CertInstaller.exportCA(extension: "pem") }
            Button("CA 证书 (.cer)") { CertInstaller.exportCA(extension: "cer") }
            Button("CA 证书 (.der)…") { CertificateToolWindows.showExporter(format: .der) }
            Button("加密 CA 私钥 (.pem)…") { CertificateToolWindows.showExporter(format: .privateKey) }
            Button("CA 身份 (.p12)…") { CertificateToolWindows.showExporter(format: .p12) }
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
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重置所有 ProxyMirror 证书")
                .font(.system(size: 14, weight: .semibold))
            Text("将删除钥匙串中的 ProxyMirror CA 并重新生成新证书。\n此前「已解密」的历史会话仍可查看，但需重新信任新 CA。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { onConfirm() }.disabled(working)
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重置") {
                        working = true
                        errorMessage = nil
                        CertInstaller.resetAll { result in
                            working = false
                            switch result {
                            case .success:
                                appState.caInstalled = false
                                appState.caBannerDismissed = false
                                UserDefaults.standard.set(false, forKey: "caBannerDismissed")
                                appState.systemProxyMessage = "ProxyMirror CA 已重置，请重新安装并信任新证书。"
                                onConfirm()
                            case .failure(let error):
                                errorMessage = "重置证书失败：\(error.localizedDescription)"
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .interactiveDismissDisabled(working)
    }
}
