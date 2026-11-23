import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum CertificateToolWindows {
    private static var importer: NSWindowController?
    private static var exporter: NSWindowController?
    private static var simulatorInstaller: NSWindowController?

    static func showImporter(purpose: CertificateFormats.Purpose = .client) {
        if importer?.window?.isVisible == true { importer?.showWindow(nil); return }
        importer = window(title: "证书导入向导", view: CertificateImporterView(initialPurpose: purpose))
        importer?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showExporter(format: CertificateFormats.ExportFormat) {
        if exporter?.window?.isVisible == true { exporter?.showWindow(nil); return }
        exporter = window(title: "导出 ProxyMirror CA", view: CertificateExportView(format: format))
        exporter?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showSimulatorInstaller(platform: String = "全部") {
        if simulatorInstaller?.window?.isVisible == true { simulatorInstaller?.showWindow(nil); return }
        simulatorInstaller = window(title: "Simulator CA 安装器", view: SimulatorCertificateInstallerView(initialPlatform: platform))
        simulatorInstaller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closeImporter() { importer?.close() }
    static func closeExporter() { exporter?.close() }

    private static func window<Content: View>(title: String, view: Content) -> NSWindowController {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }
}

@MainActor
private struct CertificateExportView: View {
    let format: CertificateFormats.ExportFormat
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(format.rawValue).font(.headline)
            if format.needsPassword {
                Text("为导出身份设置口令。导出文件权限为 0600；口令仅传给本次格式转换进程。")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("导出口令", text: $password)
                SecureField("确认口令", text: $confirmation)
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : .secondary).textSelection(.enabled) }
            HStack {
                Button("关闭") { CertificateToolWindows.closeExporter() }.disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("选择位置并导出…") { export() }
                    .disabled(working || (format.needsPassword && (password.isEmpty || password != confirmation)))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 490)
        .onDisappear { password = ""; confirmation = "" }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxymirror-ca." + format.fileExtension
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let secret = password
        password = ""; confirmation = ""
        working = true; feedback = nil
        let selectedFormat = format
        Task {
            defer { working = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CertificateFormats.export(format: selectedFormat, password: secret, to: target)
                }.value
                feedback = "已导出至 \(target.path)"
                failed = false
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch { feedback = error.localizedDescription; failed = true }
        }
    }
}

@MainActor
private struct CertificateImporterView: View {
    let initialPurpose: CertificateFormats.Purpose
    @State private var purpose = CertificateFormats.Purpose.client
    @State private var certificate: URL?
    @State private var privateKey: URL?
    @State private var password = ""
    @State private var host = ""
    @State private var material: CertificateFormats.Material?
    @State private var working = false
    @State private var feedback: String?
    @State private var failed = false
    @State private var confirmRootReplacement = false

    private var pkcs12: Bool { certificate.map { ["p12", "pfx"].contains($0.pathExtension.lowercased()) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择用途与文件").font(.headline)
            Picker("导入用途", selection: $purpose) {
                ForEach(CertificateFormats.Purpose.allCases) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Button(certificate?.lastPathComponent ?? "选择 PEM / DER / CER / P12…") {
                    certificate = choose("选择证书、证书链或 PKCS#12 身份") ?? certificate
                    material = nil
                }
                if purpose.needsKey && !pkcs12 {
                    Button(privateKey?.lastPathComponent ?? "选择私钥（或使用同文件身份）…") {
                        privateKey = choose("选择 PEM / DER 私钥") ?? privateKey
                        material = nil
                    }
                }
            }
            if purpose.needsKey || pkcs12 {
                SecureField("P12 / 加密私钥口令（无口令留空）", text: $password)
            }
            if purpose == .client || purpose == .server {
                TextField("目标主机或 *.example.com", text: $host)
            }
            Button("2. 解析并校验") { inspect() }.disabled(working || certificate == nil)
            if let material {
                Divider()
                Group {
                    Text("Subject: \(material.subject)")
                    Text("Issuer: \(material.issuer)")
                    Text("到期：\(material.expiry.formatted()) · \(material.certificateCount) 张证书 · \(material.isCA ? "CA" : "叶子证书")")
                    Text("SHA-256: \(material.fingerprint)").font(.system(size: 10, design: .monospaced))
                }.font(.caption).textSelection(.enabled)
                Text("已检查有效期、CA/身份用途、密钥匹配及服务端 SAN。此步骤尚未修改信任或代理配置。")
                    .font(.caption).foregroundStyle(.secondary)
                if purpose == .rootCA {
                    Toggle("确认替换当前抓包根 CA；随后由我重新安装并信任新 CA", isOn: $confirmRootReplacement)
                    Text("不会删除钥匙串中现有证书。已建立的 TLS 连接继续使用原证书。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : .secondary).textSelection(.enabled) }
            HStack {
                Button("关闭") { CertificateToolWindows.closeImporter() }.disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(purpose == .rootCA ? "3. 替换抓包根 CA" : "3. 导入所选用途") { install() }
                    .disabled(working || material == nil || (purpose == .rootCA && !confirmRootReplacement))
            }
        }.padding(20).frame(width: 650).disabled(working)
        .onAppear { purpose = initialPurpose }
        .onChange(of: purpose) { _ in material = nil; confirmRootReplacement = false; feedback = nil }
        .onChange(of: host) { _ in material = nil }
        .onChange(of: password) { _ in material = nil }
        .onDisappear { password = ""; material = nil }
    }

    private func choose(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.message = message
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func inspect() {
        guard let certificate else { return }
        let key = purpose.needsKey && !pkcs12 ? privateKey : nil
        let secret = password, target = purpose, targetHost = host
        material = nil; feedback = nil; confirmRootReplacement = false; working = true
        Task {
            defer { working = false }
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let value = try CertificateFormats.load(certificate: certificate, privateKey: key, password: secret)
                    try CertificateFormats.validate(value, purpose: target, host: targetHost)
                    return value
                }.value
                material = parsed
                feedback = "校验通过。核对证书信息后再导入。"; failed = false
            } catch { feedback = error.localizedDescription; failed = true }
        }
    }

    private func install() {
        guard let material, purpose != .rootCA || confirmRootReplacement else { return }
        let target = purpose, targetHost = host
        working = true; feedback = nil
        Task {
            defer { working = false }
            do {
                try CertificateFormats.validate(material, purpose: target, host: targetHost)
                if target == .server {
                    try installServer(material, host: targetHost)
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        switch target {
                        case .rootCA:
                            guard let key = material.privateKeyPEM else { throw CertificateFormats.FormatError("缺少 CA 私钥。") }
                            try CertificateAuthority.shared.importRootCA(certificatePEM: material.certificatePEM, privateKeyPEM: key)
                        case .upstreamCA: try UpstreamTrust.install(Data(material.certificatePEM.utf8))
                        case .client:
                            try ClientTLSIdentities.shared.install(host: targetHost, material: material)
                            UpstreamTrust.clearClientIdentityContexts()
                        case .server: break
                        }
                    }.value
                }
                if target == .rootCA { AppState.shared.caInstalled = false; AppState.shared.caBannerDismissed = false }
                NotificationCenter.default.post(name: .proxyMirrorCertificatesChanged, object: nil)
                self.material = nil; password = ""; confirmRootReplacement = false
                feedback = target == .rootCA ? "已替换抓包 CA。请使用证书菜单重新安装，并在客户端信任新 CA。" : "已导入；新连接将使用所选证书配置。"
                failed = false
            } catch { feedback = error.localizedDescription; failed = true }
        }
    }

    private func installServer(_ material: CertificateFormats.Material, host input: String) throws {
        guard let key = material.privateKeyPEM, let host = ClientTLSIdentities.hostPattern(input) else {
            throw CertificateFormats.FormatError("缺少有效的服务端身份或域名。")
        }
        let directory = CertificateAuthority.applicationSupport.appendingPathComponent("ServerIdentities", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let certificate = directory.appendingPathComponent("chain.pem")
        let privateKey = directory.appendingPathComponent("key.pem")
        do {
            try PrivateAppFile.write(Data(material.certificatePEM.utf8), to: certificate)
            try PrivateAppFile.write(Data(key.utf8), to: privateKey)
            let rules = RulesStore.shared
            var backup = rules.backup()
            var entries = backup.customCertificates ?? []
            // Append a separately identifiable rule. Existing user files and rules are preserved.
            entries.insert(CustomCertificateRule(hostPattern: host, certificatePath: certificate.path, privateKeyPath: privateKey.path), at: 0)
            backup.customCertificates = entries
            try rules.install(backup)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
