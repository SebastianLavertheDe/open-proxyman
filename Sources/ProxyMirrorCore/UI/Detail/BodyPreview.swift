import Foundation
import SwiftUI

enum BodyPreviewRenderer {
    static let hexLimit = 64 * 1024
    static let textLimit = 1024 * 1024

    enum Format: Equatable, Sendable {
        case hex, text

        var limit: Int {
            self == .hex ? BodyPreviewRenderer.hexLimit : BodyPreviewRenderer.textLimit
        }

        var pageSize: Int { self == .hex ? 4 * 1024 : 16 * 1024 }
    }

    private static let digits = Array("0123456789abcdef".utf8)

    static func pageCount(bytes: Int, format: Format) -> Int {
        let length = min(bytes, format.limit)
        return max(1, (length + format.pageSize - 1) / format.pageSize)
    }

    static func range(in data: Data, format: Format, page: Int) -> Range<Int>? {
        guard page >= 0, page < pageCount(bytes: data.count, format: format) else { return nil }
        let limit = min(data.count, format.limit)
        let start = page * format.pageSize
        let end = min(start + format.pageSize, limit)
        guard format == .text else { return start..<end }
        return textBoundary(start, in: data, limit: limit)..<textBoundary(end, in: data, limit: limit)
    }

    static func render(_ data: Data, format: Format, page: Int) -> String? {
        guard let range = range(in: data, format: format, page: page) else { return nil }
        return render(data, format: format, range: range)
    }

    static func renderAll(_ data: Data, format: Format) -> String? {
        render(data, format: format, range: 0..<min(data.count, format.limit))
    }

    // Move a boundary that falls inside a UTF-8 scalar to the start of that scalar.
    // Adjacent pages share a boundary, so copying or switching pages preserves the text.
    private static func textBoundary(_ offset: Int, in data: Data, limit: Int) -> Int {
        guard offset > 0, offset < limit, data[data.startIndex + offset] & 0xc0 == 0x80 else { return offset }
        for distance in 1...min(3, offset) {
            let boundary = offset - distance
            let byte = data[data.startIndex + boundary]
            switch byte {
            case 0x80...0xbf: continue
            case 0xc2...0xdf where distance < 2,
                 0xe0...0xef where distance < 3,
                 0xf0...0xf4:
                return boundary
            default:
                return offset
            }
        }
        return offset
    }

    fileprivate static func render(_ data: Data, format: Format, range: Range<Int>) -> String? {
        guard !Task.isCancelled else { return nil }
        let bytes = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
        if format == .text { return String(decoding: bytes, as: UTF8.self) }

        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var output: [UInt8] = []
            output.reserveCapacity((raw.count + 15) / 16 * 78)
            for row in stride(from: 0, to: raw.count, by: 16) {
                if row.isMultiple(of: 1024), Task.isCancelled { return nil }
                if row != 0 { output.append(10) }
                let offset = range.lowerBound + row
                for shift in stride(from: 28, through: 0, by: -4) {
                    output.append(digits[(offset >> shift) & 0x0f])
                }
                output.append(contentsOf: [32, 32])
                let end = min(row + 16, raw.count)
                for index in row..<end {
                    let byte = Int(raw[index])
                    output.append(digits[byte >> 4])
                    output.append(digits[byte & 0x0f])
                    output.append(32)
                }
                output.append(contentsOf: repeatElement(32, count: (row + 16 - end) * 3))
                output.append(contentsOf: [32, 124])
                for index in row..<end {
                    let byte = raw[index]
                    output.append((32..<127).contains(byte) ? byte : 46)
                }
                output.append(124)
            }
            return String(decoding: output, as: UTF8.self)
        }
    }
}

struct RawMessageHead: Equatable, Sendable {
    let startLine: String
    let headers: HTTPHeaders

    var text: String {
        guard !startLine.isEmpty else { return "" }
        return startLine + "\r\n" + String(decoding: headers.rawBytes, as: UTF8.self) + "\r\n"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.startLine == rhs.startLine && lhs.headers.pairs.elementsEqual(rhs.headers.pairs) {
            $0.name == $1.name && $0.value == $1.value
        }
    }
}

struct RawMessageHeadView: View, Equatable {
    let head: RawMessageHead

    var body: some View {
        if !head.startLine.isEmpty {
            Text(head.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 10)
        }
    }
}

/// Limits how much selectable text the main thread lays out at once. The task
/// key changes as the current page fills, then remains stable on later appends.
struct BodyPreview: View {
    let data: Data
    let format: BodyPreviewRenderer.Format
    var generation: UInt64 = 0
    var rawHead: RawMessageHead?
    var scrollToPageTop: (() -> Void)?

    enum ScrollAnchor: Hashable { case pageTop }

    @State private var page = 0
    @State private var rendered: Rendered?
    @State private var copyTask: Task<Void, Never>?

    private struct Source: Equatable {
        let generation: UInt64
        let format: BodyPreviewRenderer.Format
    }

    private struct Input: Equatable {
        let source: Source
        let page: Int
        let range: Range<Int>
    }

    private struct Rendered {
        let input: Input
        let text: String
    }

    var body: some View {
        let source = Source(generation: generation, format: format)
        let pages = BodyPreviewRenderer.pageCount(bytes: data.count, format: format)
        let selected = min(page, pages - 1)
        let range = BodyPreviewRenderer.range(in: data, format: format, page: selected) ?? 0..<0
        let input = Input(source: source, page: selected, range: range)
        VStack(alignment: .leading, spacing: 4) {
            if pages > 1 || !data.isEmpty || rawHead?.startLine.isEmpty == false {
                HStack(spacing: 8) {
                    if pages > 1 {
                        Button { page = selected - 1 } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("上一页正文")
                            .disabled(selected == 0)
                        Text("第 \(selected + 1) / \(pages) 页")
                            .monospacedDigit()
                        Button { page = selected + 1 } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("下一页正文")
                            .disabled(selected + 1 >= pages)
                    }
                    Spacer(minLength: 0)
                    Button(action: copyPreview) {
                        Label("复制预览", systemImage: "document.on.document")
                    }
                    .accessibilityLabel(rawHead == nil ? "复制正文预览" : "复制原文预览")
                    .disabled(copyTask != nil)
                }
                .font(.caption)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .id(ScrollAnchor.pageTop)
            }
            if let rendered, rendered.input.source == source, rendered.input.page == selected {
                Text(rendered.text)
                    .font(.system(size: format == .hex ? 10 : 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            } else if !data.isEmpty {
                ProgressView().controlSize(.small)
                    .padding(.horizontal, 10)
            }
            if data.count > format.limit {
                let limit = format == .hex ? "64 KiB" : "1 MiB"
                Text("仅显示前 \(limit) · 捕获 \(data.count) 字节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 5)
        .task(id: input) {
            guard rendered?.input != input else { return }
            let snapshot = data
            let worker = Task.detached(priority: .userInitiated) {
                BodyPreviewRenderer.render(snapshot, format: input.source.format, range: input.range)
            }
            let text = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled, let text { rendered = Rendered(input: input, text: text) }
        }
        .onChange(of: source) { _ in
            page = 0
            cancelCopy()
        }
        .onChange(of: selected) { _ in scrollToPageTop?() }
        .onDisappear(perform: cancelCopy)
    }

    private func copyPreview() {
        let snapshot = data
        let format = format
        let head = rawHead
        copyTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                BodyPreviewRenderer.renderAll(snapshot, format: format).map { (head?.text ?? "") + $0 }
            }
            let text = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            if let text { CopyPaste.copy(text) }
            copyTask = nil
        }
    }

    private func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
    }
}
