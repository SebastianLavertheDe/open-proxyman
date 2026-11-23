import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ClientTLSIdentitySettings: View {
    @State private var entries = ClientTLSIdentities.shared.summaries
    @State private var host = ""
    @State private var certificate: URL?
    @State private var privateKey: URL?
    @State private var feedback: String?
    @State private var saving = false
    @State private var failed = false
    @State private var usePKCS12 = false
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("上游客户端证书 (mTLS)").font(.headline)
            Text("按目标主机选择 PEM 证书链与私钥，或导入口令保护的 P12 身份。精确主机优先于子域规则。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(entries) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.host).fontWeight(.medium)
                        Text(item.subject).font(.caption).foregroundStyle(.secondary)
                        Text("到期：\(item.expiry.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { remove(item.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除 \(item.host) 的客户端证书")
                    .disabled(saving)
                }
            }
            Picker("身份格式", selection: $usePKCS12) {
                Text("PEM 证书 + 私钥").tag(false)
                Text("PKCS#12 (.p12/.pfx)").tag(true)
            }.pickerStyle(.segmented)
            TextField("目标主机或 *.example.com", text: $host)
                .accessibilityLabel("mTLS 目标主机")
            HStack {
                Button(certificate?.lastPathComponent ?? "选择证书链…") { certificate = choose() ?? certificate }
                    .accessibilityLabel("选择客户端证书链")
                if !usePKCS12 {
                    Button(privateKey?.lastPathComponent ?? "选择私钥…") { privateKey = choose() ?? privateKey }
                        .accessibilityLabel("选择客户端私钥")
                }
            }
            if usePKCS12 { SecureField("P12 口令", text: $password) }
            HStack {
                Button("保存客户端身份") { save() }
                    .disabled(saving || certificate == nil || (!usePKCS12 && privateKey == nil) || ClientTLSIdentities.hostPattern(host) == nil)
                if saving { ProgressView().controlSize(.small) }
                Button("证书导入向导…") { CertificateToolWindows.showImporter(purpose: .client) }
            }
            if let feedback = feedback ?? ClientTLSIdentities.shared.loadError {
                Text(feedback).font(.caption)
                    .foregroundStyle(failed || ClientTLSIdentities.shared.loadError != nil ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .onAppear { entries = ClientTLSIdentities.shared.summaries }
        .onReceive(NotificationCenter.default.publisher(for: .proxyMirrorCertificatesChanged).receive(on: RunLoop.main)) { _ in
            entries = ClientTLSIdentities.shared.summaries
        }
        .onChange(of: usePKCS12) { _ in certificate = nil; privateKey = nil; password = ""; feedback = nil }
        .onDisappear { password = "" }
    }

    private func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func save() {
        guard let certificate, usePKCS12 || privateKey != nil else { return }
        let key = privateKey, p12 = usePKCS12, secret = password
        password = ""
        let targetHost = host
        perform("客户端身份已保存，应用于新建上游 TLS 连接。") {
            if p12 {
                try ClientTLSIdentities.shared.install(host: targetHost, p12: certificate, password: secret)
            } else if let key {
                try ClientTLSIdentities.shared.install(host: targetHost, certificate: certificate, privateKey: key)
            }
        } after: {
            host = ""
            self.certificate = nil
            self.privateKey = nil
        }
    }

    private func remove(_ id: UUID) {
        perform("已移除客户端身份。") { try ClientTLSIdentities.shared.remove(id) }
    }

    private func perform(_ success: String, operation: @Sendable @escaping () throws -> Void,
                         after: @escaping () -> Void = {}) {
        saving = true
        feedback = nil
        Task {
            defer { saving = false }
            do {
                try await Task.detached(priority: .userInitiated, operation: operation).value
                UpstreamTrust.clearClientIdentityContexts()
                entries = ClientTLSIdentities.shared.summaries
                feedback = success
                failed = false
                after()
            } catch {
                feedback = error.localizedDescription
                failed = true
            }
        }
    }
}
