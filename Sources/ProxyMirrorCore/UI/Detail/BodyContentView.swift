import SwiftUI
import AppKit
import ImageIO

/// Body 内容查看器：JSON 语法高亮 / 图片 / Hex / 纯文本（对齐 Proxyman 的 Pretty/Raw 切换）
struct BodyContentView: View {
    let data: Data
    let contentType: String
    let pretty: Bool
    let complete: Bool
    let truncated: Bool
    let revision: UInt64
    var generation: UInt64 = 0

    var body: some View {
        if data.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: complete ? "tray" : "hourglass")
                    .font(.system(size: 26))
                    .foregroundColor(.secondary.opacity(0.6))
                Text(complete ? "无 Body" : "接收中…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .image {
            ImageViewer(data: data, complete: complete, revision: revision)
        } else if Self.isBinary(data: data, contentType: contentType) {
            HexView(data: data, generation: generation)
        } else {
            TextViewer(data: data, pretty: pretty && complete && !truncated && contentType.lowercased().contains("json"),
                       revision: revision)
        }
    }

    private var kind: BodyKind {
        BodyKind.from(contentType: contentType, scheme: nil)
    }

    static func isBinary(data: Data, contentType: String) -> Bool {
        guard !data.isEmpty else { return false }
        let kind = BodyKind.from(contentType: contentType, scheme: nil)
        let mime = contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        let textualApplication = mime == "application/x-www-form-urlencoded" || mime == "application/graphql"
        if (kind == .binary && !textualApplication) || kind == .image || kind == .font { return true }
        let prefix = data.prefix(1024)
        if prefix.contains(where: { $0 < 32 && $0 != 9 && $0 != 10 && $0 != 13 }) { return true }
        if String(data: prefix, encoding: .utf8) != nil { return false }
        // A byte preview can end inside a UTF-8 scalar.
        if data.count > prefix.count, (1...3).contains(where: {
            String(data: prefix.dropLast($0), encoding: .utf8) != nil
        }) { return false }
        return true
    }
}

// MARK: - 文本（含 JSON Pretty + 高亮）

struct TextViewer: View {
    let data: Data
    let pretty: Bool
    let revision: UInt64

    private static let maxRender = 1 * 1024 * 1024
    @State private var rendered: Rendered?

    private struct Input: Equatable {
        let revision: UInt64
        let pretty: Bool
    }

    private struct Rendered: Sendable {
        let plain: String
        let formatted: AttributedString?
    }

    var body: some View {
        let input = Input(revision: revision, pretty: pretty)
        ScrollView {
            Group {
                if let attr = rendered?.formatted {
                    Text(attr)
                        .font(.system(size: 11, design: .monospaced))
                } else {
                    Text(rendered?.plain ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .textSelection(.enabled)
        }
        .task(id: input) {
            let worker = Task.detached(priority: .userInitiated) {
                Self.render(data, pretty: input.pretty)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { rendered = result }
        }
    }

    private static func render(_ data: Data, pretty: Bool) -> Rendered {
        let plain = String(decoding: data.prefix(maxRender), as: UTF8.self)
            + (data.count > maxRender ? "\n\n…（超过 1MB，仅显示前 1MB）" : "")
        guard pretty, data.count <= maxRender, !Task.isCancelled,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              prettyData.count <= maxRender, !Task.isCancelled,
              let text = String(data: prettyData, encoding: .utf8) else {
            return Rendered(plain: plain, formatted: nil)
        }
        return Rendered(plain: plain, formatted: JSONHighlighter.highlight(text))
    }
}

// MARK: - 图片

struct ImageViewer: View {
    let data: Data
    let complete: Bool
    let revision: UInt64
    @State private var preview: Thumbnail?
    @State private var failed = false

    private struct Thumbnail: Sendable {
        let image: CGImage
        let width: Int
        let height: Int
    }

    var body: some View {
        VStack(spacing: 8) {
            if let preview {
                Image(decorative: preview.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .shadow(radius: 2)
                Text("\(preview.width) × \(preview.height) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if failed {
                Text("无法解码图片")
                    .foregroundColor(.secondary)
            } else {
                ProgressView(complete ? "正在解码…" : "接收中…")
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: complete ? revision : nil) {
            guard complete else { return }
            preview = nil
            failed = false
            let worker = Task.detached(priority: .userInitiated) { Self.thumbnail(data) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled {
                preview = result
                failed = result == nil
            }
        }
    }

    private static func thumbnail(_ data: Data) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              !Task.isCancelled,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        return Thumbnail(image: image,
                         width: properties?[kCGImagePropertyPixelWidth as String] as? Int ?? image.width,
                         height: properties?[kCGImagePropertyPixelHeight as String] as? Int ?? image.height)
    }
}

// MARK: - Hex

struct HexView: View {
    let data: Data
    var generation: UInt64 = 0

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                BodyPreview(data: data, format: .hex, generation: generation) {
                    scroll.scrollTo(BodyPreview.ScrollAnchor.pageTop, anchor: .top)
                }
            }
        }
    }

    var text: some View {
        BodyPreview(data: data, format: .hex, generation: generation)
    }
}
