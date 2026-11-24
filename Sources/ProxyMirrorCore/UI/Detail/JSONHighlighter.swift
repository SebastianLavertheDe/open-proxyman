import SwiftUI
import AppKit
import ProxyMirrorFoundation

/// Colors are applied to a bounded Foundation plan in one NSTextStorage update.
enum JSONHighlighter {
    static func color(for kind: JSONHighlightPlan.Kind) -> NSColor {
        switch kind {
        case .key: return NSColor(ProxymanTheme.jsonKey)
        case .string: return NSColor(ProxymanTheme.jsonString)
        case .number: return NSColor(ProxymanTheme.jsonNumber)
        case .constant: return NSColor(ProxymanTheme.jsonBoolNull)
        case .punctuation: return .secondaryLabelColor
        }
    }
}
