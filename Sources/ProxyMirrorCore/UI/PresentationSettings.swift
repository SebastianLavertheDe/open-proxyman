import AppKit
import Foundation
import SwiftUI
import ProxyMirrorFoundation

@MainActor
enum PresentationFonts {
    static var availableFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.font(withFamily: family, traits: .fixedPitchFontMask, weight: 5, size: 12)?.isFixedPitch == true
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func resolvedSize(_ baseSize: CGFloat = 12, settings: AppSettings = .shared) -> CGFloat {
        max(8, min(48, CGFloat(settings.fontSize) + baseSize - 12))
    }

    static func nsFont(size: CGFloat = 12, settings: AppSettings = .shared, weight: NSFont.Weight = .regular) -> NSFont {
        let size = resolvedSize(size, settings: settings)
        guard settings.useMonospacedFont else { return NSFont.systemFont(ofSize: size, weight: weight) }
        if !settings.monospacedFontFamily.isEmpty,
           let font = NSFontManager.shared.font(withFamily: settings.monospacedFontFamily, traits: .fixedPitchFontMask,
                                                weight: weight == .semibold || weight == .bold ? 9 : 5, size: size), font.isFixedPitch {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func swiftUIFont(size: CGFloat = 12, settings: AppSettings = .shared, weight: NSFont.Weight = .regular) -> Font {
        Font(nsFont(size: size, settings: settings, weight: weight))
    }
}

/// One cache is shared by transaction and WebSocket timestamps. Its key includes every display choice.
enum PresentationTime {
    static func string(from date: Date, settings: AppSettings = .shared,
                       timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        string(from: date, uses24HourClock: settings.use24HourClock, includesDate: settings.showFullDate,
               timeZone: timeZone, locale: locale)
    }

    static func string(from date: Date, uses24HourClock: Bool, includesDate: Bool,
                       timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        DisplayTimeFormatter.string(from: date, uses24HourClock: uses24HourClock, includesDate: includesDate,
                                    timeZone: timeZone, locale: locale)
    }
}

/// Region-sensitive UI numbers. Wire formats, request generators and HAR keep
/// their own stable numeric serialization and never use this presentation API.


@MainActor
enum CodeTextStyle {
    static func paragraphStyle(font: NSFont, tabWidth: Int, wordWrap: Bool) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        let space = max(1, (" " as NSString).size(withAttributes: [.font: font]).width)
        paragraph.defaultTabInterval = space * CGFloat(min(16, max(1, tabWidth)))
        paragraph.lineBreakMode = wordWrap ? .byWordWrapping : .byClipping
        return paragraph
    }

    static func apply(to textView: NSTextView, settings: AppSettings = .shared,
                      fontSize: CGFloat = 12, wordWrap: Bool = true) {
        let font = PresentationFonts.nsFont(size: fontSize, settings: settings)
        let paragraph = paragraphStyle(font: font, tabWidth: settings.codeTabWidth, wordWrap: wordWrap)
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor]
        textView.textStorage?.addAttributes([.font: font, .paragraphStyle: paragraph],
                                          range: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.textContainer?.lineBreakMode = paragraph.lineBreakMode
    }
}

/// Read-only selectable code that participates in an outer SwiftUI ScrollView.
/// Tabs remain actual tab glyphs; their advance comes from NSTextView paragraph stops.
@MainActor
struct CodeText: NSViewRepresentable {
    let text: String
    var attributed: AttributedString?
    var fontSize: CGFloat = 12
    var wordWrap = true
    var showInvisibles = false
    @ObservedObject private var settings = AppSettings.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var attributed: AttributedString?
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text || context.coordinator.attributed != attributed {
            let output = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.textColor])
            if let attributed {
                var offset = 0
                for run in attributed.runs {
                    let count = String(attributed[run.range].characters).utf16.count
                    if let color = run.foregroundColor, offset + count <= output.length {
                        output.addAttribute(.foregroundColor, value: NSColor(color), range: NSRange(location: offset, length: count))
                    }
                    offset += count
                }
            }
            view.textStorage?.setAttributedString(output)
            context.coordinator.attributed = attributed
        }
        view.textContainer?.widthTracksTextView = wordWrap
        view.isHorizontallyResizable = !wordWrap
        view.layoutManager?.showsInvisibleCharacters = showInvisibles
        CodeTextStyle.apply(to: view, settings: settings, fontSize: fontSize, wordWrap: wordWrap)
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = wordWrap ? max(1, proposal.width ?? 600) : CGFloat.greatestFiniteMagnitude
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let line = layout.defaultLineHeight(for: view.font ?? PresentationFonts.nsFont(size: fontSize))
        return CGSize(width: wordWrap ? width : max(1, ceil(used.width)), height: max(line, ceil(used.height)))
    }
}

/// Shared plain-text editor used by scripts and other code surfaces.
@MainActor
struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12
    var wordWrap = true
    @ObservedObject private var settings = AppSettings.shared

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CodeEditorScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = !wordWrap
        scroll.autohidesScrollers = true
        let editor = NSTextView()
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false; editor.isVerticallyResizable = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.autoresizingMask = [.width]
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if editor.string != text {
            let selection = editor.selectedRanges
            editor.string = text
            let length = (text as NSString).length
            editor.selectedRanges = selection.map { range in
                let value = range.rangeValue
                let location = min(value.location, length)
                return NSValue(range: NSRange(location: location, length: min(value.length, length - location)))
            }
        }
        (scroll as? CodeEditorScrollView)?.wordWrap = wordWrap
        editor.textContainer?.widthTracksTextView = wordWrap
        editor.isHorizontallyResizable = !wordWrap
        if !wordWrap { editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude) }
        editor.textColor = .textColor
        scroll.hasHorizontalScroller = !wordWrap
        CodeTextStyle.apply(to: editor, settings: settings, fontSize: fontSize, wordWrap: wordWrap)
    }

    private final class CodeEditorScrollView: NSScrollView {
        var wordWrap = true
        override func layout() {
            super.layout()
            guard wordWrap, let editor = documentView as? NSTextView else { return }
            editor.setFrameSize(NSSize(width: max(1, contentSize.width), height: max(contentSize.height, editor.frame.height)))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if text.wrappedValue != editor.string { text.wrappedValue = editor.string }
        }
    }
}

/// Selection covers highlights; a highlight covers zebra striping.
@MainActor
enum TrafficRowPresentation {
    static func background(selected: Bool, highlight: NSColor?, alternate: Bool) -> NSColor {
        if selected { return ProxymanTheme.tableSelectionColor }
        if let highlight {
            return ProxymanTheme.tableBackgroundColor.blended(withFraction: 0.28, of: highlight.withAlphaComponent(1))
                ?? ProxymanTheme.tableBackgroundColor
        }
        return alternate ? ProxymanTheme.tableAlternateColor : ProxymanTheme.tableBackgroundColor
    }
}


/// The table only intercepts these shortcuts while it is first responder, preserving text-field copying.
enum TrafficCopyShortcut: Equatable {
    case preferred, curl
    static func resolve(characters: String?, modifiers: NSEvent.ModifierFlags) -> TrafficCopyShortcut? {
        guard characters?.lowercased() == "c" else { return nil }
        let modifiers = modifiers.intersection([.command, .shift, .control, .option])
        if modifiers == [.command] { return .preferred }
        if modifiers == [.command, .shift] { return .curl }
        return nil
    }
}
