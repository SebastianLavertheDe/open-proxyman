import SwiftUI

enum HTTPProtobuf {
    static func matches(contentType: String, query: String, isRequest: Bool) -> Bool {
        let mime = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch mime {
        case "application/proto", "application/protobuf", "application/x-protobuf", "application/x-protobuffer",
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

@MainActor
struct HTTPProtobufView: View {
    let data: Data
    let revision: UInt64
    let generation: UInt64
    let complete: Bool
    let truncated: Bool
    let isError: Bool
    let decodedEncoding: String?
    var target = ""
    var isRequest = false
    var rawHead: RawMessageHead? = nil
    var rawTrailers = HTTPHeaders()
    @ObservedObject private var rules = ProtobufRuleStore.shared
    @State private var output: (key: DecodeKey, value: Decoded)?

    private struct DecodeKey: Hashable {
        let revision: UInt64
        let generation: UInt64
        let isError: Bool
        let mapping: UUID
    }

    private enum Decoded: Sendable {
        case rendered(GRPCProtobuf.HTTPDescription)
        case failure(String)
    }

    var body: some View {
        let key = complete && !truncated && !data.isEmpty
            ? DecodeKey(revision: revision, generation: generation, isError: isError, mapping: rules.revision) : nil
        let decoded = output.flatMap { $0.key == key ? $0.value : nil }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if case .rendered(let description) = decoded {
                    Text(description.type.map { "Protobuf · \($0)" } ?? Strings.Detail.protobufFieldNumbers)
                } else {
                    Text("Protobuf")
                }
                Spacer()
                if let decodedEncoding { Text(Strings.Detail.decoded(String(describing: decodedEncoding))) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)

            if data.isEmpty {
                message(complete ? Strings.Detail.noBody2 : Strings.Detail.waitingForTheBody)
            } else if truncated {
                fallback(Strings.Detail.theBodyWasTruncatedAndCannotBeFullyParsedAsProtobuf)
            } else if !complete {
                message(Strings.Detail.waitingForTheCompleteProtobufBody)
            } else {
                switch decoded {
                case .rendered(let description):
                    BodyPreview(data: Data(description.text.utf8), format: .text,
                                generation: generation, rawHead: rawHead,
                                includeHead: rawHead != nil, suffixText: rawTrailerText)
                        .id(key)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .failure(let error):
                    fallback(error)
                case nil:
                    ProgressView(Strings.Detail.parsingProtobuf).controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: key) {
            guard let key else { return }
            let resolution = rules.resolution(for: target, isRequest: isRequest)
            let worker = Task.detached(priority: .userInitiated) { () -> Decoded in
                do {
                    if let resolution {
                        return .rendered(GRPCProtobuf.HTTPDescription(text: try ProtobufPayload.describe(data, resolution: resolution), type: resolution.type))
                    }
                    return .rendered(try GRPCProtobuf.describeHTTP(data, isError: isError))
                }
                catch { return .failure(LocalizedErrorPresentation.message(for: error)) }
            }
            let value = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled {
                output = (key, value)
                if case .failure(let message) = value { rules.log("\(target)：\(message)", isError: true) }
                else if let resolution { rules.log(Strings.Detail.decoded2(String(describing: resolution.ruleName), String(describing: isRequest ? Strings.Detail.request : Strings.Detail.response))) }
            }
        }
    }

    @ViewBuilder
    private func message(_ text: String) -> some View {
        if let rawHead {
            CodeDocument(text: rawHead.text + "\n" + text + rawTrailerText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(text).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fallback(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text).font(.caption).foregroundStyle(.secondary).padding(6)
            BodyPreview(data: data, format: .hex, generation: generation, rawHead: rawHead,
                        includeHead: rawHead != nil, suffixText: rawTrailerText)
        }
    }

    private var rawTrailerText: String {
        guard rawHead != nil, rawTrailers.count > 0 else { return "" }
        return "\r\n" + RawMessageHead(startLine: "Trailers", headers: rawTrailers).text
    }
}
