import SwiftUI
import ProxyMirrorFoundation

/// Read-only inspection: captured form values remain immutable evidence.
struct FormBodyView: View {
    let data: Data
    let contentType: String
    let complete: Bool
    @State private var selected: Int?
    @State private var multipart: FormBody.Multipart?
    @State private var loaded = false
    @State private var encodedFields: [(String, String)] = []

    private struct PartRow: Identifiable {
        let id: Int
        let part: FormBody.Part
        let value: String
    }

    var body: some View {
        Group {
            if contentType.localizedCaseInsensitiveContains("application/x-www-form-urlencoded") {
                let entries = encodedFields
                List(entries.indices, id: \.self) { index in
                    HStack(alignment: .top) {
                        Text(entries[index].0).frame(width: 160, alignment: .leading)
                        Text(entries[index].1).frame(maxWidth: .infinity, alignment: .leading)
                    }.textSelection(.enabled).font(.system(size: 12, design: .monospaced))
                }
            } else if !loaded {
                ProgressView().controlSize(.small)
            } else if let multipart {
                VStack(spacing: 0) {
                    HSplitView {
                        let rows = multipart.parts.enumerated().map { index, part in
                            PartRow(id: index, part: part, value: String(data: data.subdata(in: part.range.lowerBound..<min(part.range.upperBound, part.range.lowerBound + 96)), encoding: .utf8) ?? "…")
                        }
                        Table(rows, selection: $selected) {
                            TableColumn(Strings.Detail.bodyToolsPart) { Text($0.part.name) }.width(min: 70, ideal: 100)
                            TableColumn(Strings.Detail.bodyToolsContentType) { Text($0.part.contentType) }.width(min: 85, ideal: 120)
                            TableColumn(Strings.Detail.bodyToolsFileName) { Text($0.part.filename ?? "—") }.width(min: 70, ideal: 100)
                            TableColumn(Strings.Detail.bodyToolsValue) { Text($0.value).lineLimit(1) }.width(min: 80, ideal: 120)
                        }.frame(minWidth: 200, idealWidth: 400)
                        if let selected, multipart.parts.indices.contains(selected) {
                            let part = multipart.parts[selected]
                            let bytes = data.subdata(in: part.range)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(part.filename ?? part.name).fontWeight(.semibold).textSelection(.enabled)
                                Text(verbatim: "\(part.contentType) · \(PresentationNumbers.byteCount(Int64(bytes.count)))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(Strings.Detail.bodyToolsSavePart) { BodyExportService.save(bytes, contentType: part.contentType, filename: part.filename) }
                                BodyContentView(data: bytes, contentType: part.contentType, pretty: true,
                                                complete: true, truncated: false, revision: 0)
                            }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Text(Strings.Detail.bodyToolsSelectPart).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    if !multipart.complete || !complete {
                        Text(Strings.Detail.bodyToolsWaitingForParts).font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                }
            } else {
                Text(Strings.Detail.bodyToolsInvalidMultipart).foregroundStyle(.secondary)
            }
        }
        .task(id: data) {
            loaded = false
            let bytes = data, type = contentType
            if type.localizedCaseInsensitiveContains("application/x-www-form-urlencoded") {
                let worker = Task.detached(priority: .userInitiated) { FormBody.urlEncoded(bytes) }
                let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                encodedFields = result
                loaded = true
                return
            }
            let worker = Task.detached(priority: .userInitiated) { FormBody.multipart(bytes, contentType: type) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            multipart = result
            if let selected, !(result?.parts.indices.contains(selected) ?? false) { self.selected = nil }
            loaded = true
        }
    }
}
