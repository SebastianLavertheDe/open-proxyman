import SwiftUI

struct GistPublishView: View {
    let transactions: [Transaction]
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var description = "Captured with ProxyMirror"
    @State private var isPublic = false
    @State private var rememberToken = true
    @State private var preview = ""
    @State private var error: String?
    @State private var publishing = false
    @State private var publishedURL: URL?
    @State private var publishTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("发布到 GitHub Gist").font(.headline)
                Spacer()
                Text("\(transactions.count) 个请求").foregroundStyle(.secondary)
            }
            HStack {
                SecureField("GitHub Token（Gists 写入权限）", text: $token)
                Link("创建 Token", destination: URL(string: "https://github.com/settings/tokens/new?scopes=gist&description=ProxyMirror")!)
            }
            HStack {
                Toggle("保存到钥匙串", isOn: $rememberToken)
                Button("移除已保存 Token") {
                    do { try GistService.deleteToken(); token = "" }
                    catch { self.error = error.localizedDescription }
                }
                Spacer()
                Toggle("公开 Gist", isOn: $isPublic)
            }
            TextField("描述", text: $description)
            Text("Authorization、Cookie、Set-Cookie 与常见 API Key 请求头已脱敏。URL、正文和注释保持原样，请检查下方预览。非公开 Gist 仍可由知道链接的人访问。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $preview).font(.system(.body, design: .monospaced))
                .accessibilityLabel("发布前 HAR 预览")
                .overlay(Rectangle().strokeBorder(.quaternary))
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            if let publishedURL { Link("打开已发布 Gist", destination: publishedURL).textSelection(.enabled) }
            HStack {
                Button("复制预览") { CopyPaste.copy(preview) }.disabled(preview.isEmpty)
                Spacer()
                if publishing { ProgressView().controlSize(.small) }
                Button(publishing ? "取消发布" : "关闭") {
                    if publishing { publishTask?.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("发布") { publish() }.buttonStyle(.borderedProminent)
                    .disabled(publishing || preview.isEmpty || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || publishedURL != nil)
            }
        }
        .padding(18).frame(width: 740, height: 580)
        .onAppear {
            do { preview = try GistService.preview(transactions); token = try GistService.savedToken() ?? "" }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { publishTask?.cancel() }
    }

    private func publish() {
        publishing = true; error = nil
        publishTask = Task { @MainActor in
            defer { publishing = false; publishTask = nil }
            do {
                if rememberToken { try GistService.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines)) }
                else { try GistService.deleteToken() }
                publishedURL = try await GistService.publish(preview: preview, description: description, isPublic: isPublic, token: token)
            } catch is CancellationError { self.error = "已取消。若请求已送达 GitHub，请先检查账号中的 Gist，避免重复发布。" }
            catch { self.error = error.localizedDescription }
        }
    }
}
