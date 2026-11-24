import Foundation

/// UTF-16 ranges apply directly to one text storage. Dense documents retain
/// their text and omit coloring when the input or attribute-run budget is full.
package struct JSONHighlightPlan: Sendable, Equatable {
    package enum Kind: Equatable, Sendable { case key, string, number, constant, punctuation }
    package struct Span: Sendable, Equatable {
        package let offset: Int
        package let length: Int
        package let kind: Kind
    }
    package let spans: [Span]
    package let limited: Bool
    package static let maximumInputBytes = 131_072
    package static let maximumSpans = 2_048

    package static func make(_ text: String, cancelled: () -> Bool = { Task.isCancelled }) -> Self? {
        guard !cancelled() else { return nil }
        guard text.utf8.count <= maximumInputBytes else {
            return cancelled() ? nil : Self(spans: [], limited: true)
        }
        let units = Array(text.utf16)
        var spans: [Span] = []
        var i = 0, work = 0
        func white(_ value: UInt16) -> Bool { value == 32 || value == 9 || value == 10 || value == 13 }
        func stopped() -> Bool {
            work += 1
            return work & 255 == 0 && cancelled()
        }
        while i < units.count {
            if stopped() { return nil }
            let start = i, c = units[i]
            var kind: Kind?
            if c == 34 {
                i += 1
                while i < units.count {
                    if stopped() { return nil }
                    if units[i] == 92 { i = min(units.count, i + 2) }
                    else if units[i] == 34 { i += 1; break }
                    else { i += 1 }
                }
                var next = i
                while next < units.count, white(units[next]) {
                    if stopped() { return nil }
                    next += 1
                }
                kind = next < units.count && units[next] == 58 ? .key : .string
            } else if c == 45 || (48...57).contains(c) {
                i += 1
                while i < units.count, (48...57).contains(units[i]) || [43, 45, 46, 69, 101].contains(units[i]) {
                    if stopped() { return nil }
                    i += 1
                }
                kind = .number
            } else if [123, 125, 91, 93, 44, 58].contains(c) { i += 1; kind = .punctuation }
            else {
                let literal: [UInt16]? = c == 116 ? [116,114,117,101] : c == 102 ? [102,97,108,115,101] : c == 110 ? [110,117,108,108] : nil
                if let literal, i + literal.count <= units.count,
                   units[i..<(i + literal.count)].elementsEqual(literal) { i += literal.count; kind = .constant }
                else { i += 1 }
            }
            if let kind {
                guard spans.count < maximumSpans else {
                    return cancelled() ? nil : Self(spans: [], limited: true)
                }
                spans.append(Span(offset: start, length: i - start, kind: kind))
            }
        }
        return cancelled() ? nil : Self(spans: spans, limited: false)
    }
}

/// This actor has no suspension inside a render: at most one parse/format/token
/// operation runs globally, including while a cancelled view awaits replacement.
package actor JSONDocumentRenderer {
    package static let shared = JSONDocumentRenderer()
    package static let maximumRenderBytes = 1_048_576
    package struct Document: Sendable {
        package let text: String
        package let highlights: JSONHighlightPlan?
        package let truncated: Bool
    }
    package init() {}

    package func render(_ data: Data, pretty: Bool,
                        cancelled: @Sendable () -> Bool = { Task.isCancelled }) -> Document? {
        guard !cancelled() else { return nil }
        let decoded = String(decoding: data.prefix(Self.maximumRenderBytes), as: UTF8.self)
        let truncated = data.count > Self.maximumRenderBytes || decoded.utf8.count > Self.maximumRenderBytes
        let plain = Self.boundedText(decoded)
        guard pretty, !truncated, !cancelled(),
              let object = try? JSONSerialization.jsonObject(with: data), !cancelled() else {
            return cancelled() ? nil : Document(text: plain, highlights: nil, truncated: truncated)
        }
        do {
            var formatted = Data()
            let finished = try BoundedJSONWriter.write(object, maximumLineBytes: Self.maximumRenderBytes, append: { line in
                let separator = formatted.isEmpty ? 0 : 1
                guard separator <= Self.maximumRenderBytes - formatted.count,
                      line.utf8.count <= Self.maximumRenderBytes - formatted.count - separator else { return false }
                if separator != 0 { formatted.append(10) }
                formatted.append(contentsOf: line.utf8)
                return true
            }, cancelled: cancelled)
            guard finished else { return cancelled() ? nil : Document(text: plain, highlights: nil, truncated: false) }
            guard !cancelled() else { return nil }
            let text = String(decoding: formatted, as: UTF8.self)
            guard let highlights = JSONHighlightPlan.make(text, cancelled: cancelled), !cancelled() else { return nil }
            return Document(text: text, highlights: highlights, truncated: false)
        } catch is CancellationError { return nil }
        catch { return cancelled() ? nil : Document(text: plain, highlights: nil, truncated: false) }
    }

    private static func boundedText(_ text: String) -> String {
        let bytes = text.utf8
        guard bytes.count > maximumRenderBytes else { return text }
        var end = bytes.index(bytes.startIndex, offsetBy: maximumRenderBytes)
        while end > bytes.startIndex, bytes[end] & 0xc0 == 0x80 { end = bytes.index(before: end) }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

}
