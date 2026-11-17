import SwiftUI

enum HTTPProtobuf {
    static func matches(contentType: String, query: String, isRequest: Bool) -> Bool {
        let mime = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch mime {
        case "application/protobuf", "application/x-protobuf", "application/x-protobuffer",
             "application/x-google-protobuf", "application/vnd.google.protobuf":
            return true
        default:
            if mime.hasPrefix("application/"), mime.hasSuffix("+protobuf") { return true }
        }
        // alt selects the response representation. A server can still reply in JSON.
        guard !isRequest, mime.isEmpty || mime == "application/octet-stream", !query.isEmpty else { return false }
        return URLComponents(string: "?\(query)")?.queryItems?.contains {
            ($0.name == "alt" || $0.name == "$alt") && $0.value == "proto"
        } == true
    }
}

struct HTTPProtobufView: View {
    let data: Data
    let revision: UInt64
    let generation: UInt64
    let complete: Bool
    let truncated: Bool
    let isError: Bool
    let decodedEncoding: String?
    @State private var output: (key: DecodeKey, value: Decoded)?

    private struct DecodeKey: Equatable {
        let revision: UInt64
        let generation: UInt64
        let isError: Bool
    }

    private enum Decoded: Sendable {
        case rendered(GRPCProtobuf.HTTPDescription)
        case failure(String)
    }

    var body: some View {
        let key = complete && !truncated && !data.isEmpty
            ? DecodeKey(revision: revision, generation: generation, isError: isError) : nil
        let decoded = output.flatMap { $0.key == key ? $0.value : nil }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if case .rendered(let description) = decoded {
                    Text(description.type.map { "Protobuf · \($0)" } ?? "Protobuf · 按字段编号显示")
                } else {
                    Text("Protobuf")
                }
                Spacer()
                if let decodedEncoding { Text("已解码 \(decodedEncoding)") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)

            if data.isEmpty {
                message(complete ? "无正文" : "等待接收正文…")
            } else if truncated {
                fallback("正文已截断，无法完整解析 Protobuf。")
            } else if !complete {
                message("等待接收完整的 Protobuf 正文…")
            } else {
                switch decoded {
                case .rendered(let description):
                    ScrollView([.vertical, .horizontal]) {
                        Text(description.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .failure(let error):
                    fallback(error)
                case nil:
                    ProgressView("正在解析 Protobuf…").controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: key) {
            guard let key else { return }
            let worker = Task.detached(priority: .userInitiated) { () -> Decoded in
                do { return .rendered(try GRPCProtobuf.describeHTTP(data, isError: isError)) }
                catch { return .failure(error.localizedDescription) }
            }
            let value = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { output = (key, value) }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fallback(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text).font(.caption).foregroundStyle(.secondary).padding(6)
            HexView(data: data, generation: generation)
        }
    }
}
