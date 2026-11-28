import Foundation
import SwiftUI
import AppKit
import ProxyMirrorFoundation

extension Notification.Name {
    static let pmOpenProtobuf = Notification.Name("ProxyMirror.openProtobuf")
}

struct CustomPreviewer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = Strings.Detail.jsonSummary
    var enabled = true
    var contentType = "*"
    var source = """
    function preview(input) {
      const body = JSON.parse(input.body || '{}');
      return { url: input.url, side: input.side, body };
    }
    """

    func matches(_ type: String) -> Bool {
        enabled && (contentType == "*" || type.localizedCaseInsensitiveContains(contentType))
    }
}

@MainActor
final class CustomPreviewerStore: ObservableObject {
    static let shared = CustomPreviewerStore()
    @Published private(set) var items: [CustomPreviewer] = []
    private let url = CertificateAuthority.applicationSupport.appendingPathComponent("previewers.json")
    init() {
        if let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([CustomPreviewer].self, from: data) { items = decoded }
    }
    func save(_ next: [CustomPreviewer]) throws {
        guard next.count <= 50, next.allSatisfy({ !$0.name.isEmpty && $0.source.utf8.count <= 64 * 1024 }) else {
            throw PreviewerError(Strings.Detail.useUpTo50PreviewersWithScriptsUpTo64Kib)
        }
        let data = try JSONEncoder().encode(next)
        guard data.count <= 2 * 1024 * 1024 else { throw PreviewerError(Strings.Detail.thePreviewerConfigurationExceeds2Mib) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateAppFile.write(data, to: url)
        items = next
    }
}

struct PreviewerError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

/// Preview scripts use the same disposable worker as interception scripts.
enum PreviewerWorker {
    static func render(source: String, input: [String: Any], cancellation: WorkCancellation) throws -> String {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ProxyMirrorScriptWorker"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw PreviewerError(Strings.Detail.theScriptWorkerWasNotFoundUseACompleteApplicationBuild) }
        let request = try JSONSerialization.data(withJSONObject: ["operation": "preview", "source": source, "input": input])
        guard request.count <= 2 * 1024 * 1024 else { throw PreviewerError(Strings.Detail.thePreviewInputExceeds2Mib) }
        let output: Data
        do { output = try PreviewProcessRunner.run(executable: executable, input: request, cancellation: cancellation) }
        catch PreviewProcessRunner.Failure.outputLimit { throw PreviewerError(Strings.Detail.thePreviewResultExceedsTheLimit) }
        catch is PreviewProcessRunner.Failure { throw PreviewerError(Strings.Detail.thePreviewerFailedOrTimedOut) }
        guard let result = try JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw PreviewerError(Strings.Detail.thePreviewerReturnedAnInvalidResult) }
        if let error = result["error"] as? String { throw PreviewerError(error) }
        guard let value = result["preview"] as? String else { throw PreviewerError(Strings.Detail.previewInputMustReturnTextOrJson) }
        return value
    }
}

struct CustomPreviewerManagerView: View {
    @ObservedObject private var store = CustomPreviewerStore.shared
    @State private var draft = CustomPreviewerStore.shared.items
    @State private var selection: UUID?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HSplitView {
                List(selection: $selection) {
                    ForEach(draft) { item in Text(item.name).tag(item.id) }
                }.frame(minWidth: 180, idealWidth: 220)
                if let index = draft.firstIndex(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(Strings.Detail.previewerName, text: $draft[index].name)
                        Toggle(Strings.Detail.enable, isOn: $draft[index].enabled)
                        TextField(Strings.Detail.contentTypeContainsMatchesAll, text: $draft[index].contentType)
                        Text(Strings.Detail.previewInputCanReadUrlMethodSideHeadersBodyAndBodybase64)
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft[index].source).font(.system(.body, design: .monospaced)).border(.quaternary)
                    }.padding(10).frame(minWidth: 420)
                } else {
                    Text(Strings.Detail.addOrSelectACustomPreviewer).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button(Strings.Detail.add) { let item = CustomPreviewer(); draft.append(item); selection = item.id }
                Button(Strings.Detail.delete) { draft.removeAll { $0.id == selection }; selection = nil }.disabled(selection == nil)
                Spacer()
                Button(Strings.Detail.revert) { draft = store.items; error = nil }
                Button(Strings.Detail.saveEnable) {
                    do { try store.save(draft); error = nil } catch { self.error = LocalizedErrorPresentation.message(for: error) }
                }.keyboardShortcut("s", modifiers: .command)
            }
        }.padding(16).frame(minWidth: 720, minHeight: 440)
    }
}

struct CustomPreviewerResultView: View {
    let previewer: CustomPreviewer
    @ObservedObject var tx: Transaction
    let side: ContentSide
    @State private var output = ""
    private var request: Bool { side == .request }
    private var key: String { "\(previewer.id):\(previewer.source):\(tx.id):\(request ? tx.requestBodyRevision : tx.responseBodyRevision)" }
    var body: some View {
        ScrollView {
            Text(output.isEmpty ? Strings.Detail.runningPreviewer : output)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .task(id: key) {
            let body = request ? tx.requestBody : tx.responseBody
            guard body.count <= 512 * 1024 else { output = Strings.Detail.previewersSupportBodiesUpTo512Kib; return }
            let headers = request ? tx.requestHeaders : tx.responseHeaders
            let input: [String: Any] = ["url": tx.fullURL, "method": tx.method, "side": request ? "request" : "response",
                "headers": headers.pairs.map { ["name": $0.name, "value": $0.value] },
                "body": String(data: body, encoding: .utf8) ?? "", "bodyBase64": body.base64EncodedString()]
            let source = previewer.source
            let cancellation = WorkCancellation()
            output = ""
            do {
                let rendered = try await withTaskCancellationHandler(operation: {
                    try await Task.detached(priority: .userInitiated) {
                        try PreviewerWorker.render(source: source, input: input, cancellation: cancellation)
                    }.value
                }, onCancel: { cancellation.cancel() })
                if !Task.isCancelled { output = rendered }
            } catch is CancellationError {
                // The replacement task owns the result. Its cancelled predecessor
                // cannot overwrite it or retain a worker slot.
            } catch {
                if !Task.isCancelled { output = LocalizedErrorPresentation.message(for: error) }
            }
        }
    }
}
