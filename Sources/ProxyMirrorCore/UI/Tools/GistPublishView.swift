import SwiftUI

struct GistPublishView: View {
    let transactions: [Transaction]
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var description = Strings.Tools.gistDefaultDescription
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
                Text(Strings.Tools.publishToGithubGist).font(.headline)
                Spacer()
                Text(Strings.Tools.requests(Int(transactions.count))).foregroundStyle(.secondary)
            }
            HStack {
                SecureField(Strings.Tools.githubTokenGistsWritePermission, text: $token)
                Link(Strings.Tools.createToken, destination: URL(string: "https://github.com/settings/tokens/new?scopes=gist&description=ProxyMirror")!)
            }
            HStack {
                Toggle(Strings.Tools.saveToKeychain, isOn: $rememberToken)
                Button(Strings.Tools.removeSavedToken) {
                    do { try GistService.deleteToken(); token = "" }
                    catch { self.error = LocalizedErrorPresentation.message(for: error) }
                }
                Spacer()
                Toggle(Strings.Tools.publicGist, isOn: $isPublic)
            }
            TextField(Strings.Tools.description, text: $description)
            Text(Strings.Tools.authorizationCookieSetCookieAndCommonApiKeyHeaders)
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $preview).font(.system(.body, design: .monospaced))
                .accessibilityLabel(Strings.Tools.harPreviewBeforePublishing)
                .overlay(Rectangle().strokeBorder(.quaternary))
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            if let publishedURL { Link(Strings.Tools.openPublishedGist, destination: publishedURL).textSelection(.enabled) }
            HStack {
                Button(Strings.Tools.copyPreview) { CopyPaste.copy(preview) }.disabled(preview.isEmpty)
                Spacer()
                if publishing { ProgressView().controlSize(.small) }
                Button(publishing ? Strings.Tools.cancelPublishing : Strings.Tools.close) {
                    if publishing { publishTask?.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button(Strings.Tools.publish) { publish() }.buttonStyle(.borderedProminent)
                    .disabled(publishing || preview.isEmpty || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || publishedURL != nil)
            }
        }
        .padding(18).frame(width: 740, height: 580)
        .onAppear {
            do { preview = try GistService.preview(transactions); token = try GistService.savedToken() ?? "" }
            catch { self.error = LocalizedErrorPresentation.message(for: error) }
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
            } catch is CancellationError { self.error = Strings.Tools.canceledIfTheRequestReachedGithubCheckYourAccount }
            catch { self.error = LocalizedErrorPresentation.message(for: error) }
        }
    }
}
