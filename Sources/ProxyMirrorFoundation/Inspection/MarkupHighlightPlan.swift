import Foundation

/// XML/HTML highlighting uses the same bounded UTF-16 spans as the JSON editor.
package enum MarkupHighlightPlan {
    package static func make(_ text: String) -> JSONHighlightPlan {
        guard text.utf8.count <= JSONHighlightPlan.maximumInputBytes else { return .init(spans: [], limited: true) }
        let pattern = #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[^>]*\?>|</?[\w:.-]+|/?>|[\w:.-]+\s*(?==)|\"[^\"]*\"|'[^']*'"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return .init(spans: [], limited: false) }
        let range = NSRange(text.startIndex..., in: text)
        var spans: [JSONHighlightPlan.Span] = []
        expression.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let match, let range = Range(match.range, in: text) else { return }
            if spans.count >= JSONHighlightPlan.maximumSpans { stop.pointee = true; return }
            let token = text[range]
            let kind: JSONHighlightPlan.Kind = token.hasPrefix("<!--") || token.hasPrefix("<![CDATA[") ? .constant
                : token.hasPrefix("\"") || token.hasPrefix("'") ? .string
                : token.hasPrefix("<") || token.hasSuffix(">") ? .punctuation : .key
            spans.append(.init(offset: match.range.location, length: match.range.length, kind: kind))
        }
        return .init(spans: spans, limited: spans.count == JSONHighlightPlan.maximumSpans)
    }
}
