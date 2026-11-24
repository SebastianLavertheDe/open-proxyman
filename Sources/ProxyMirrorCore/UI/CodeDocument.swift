import ProxyMirrorFoundation
import AppKit
import SwiftUI

/// A single selectable document shared by Body and Raw. The minimap renders the
/// actual laid-out glyphs and tracks this scroll view, so navigation never changes
/// the text selection or silently switches to a different page of the body.
@MainActor
struct CodeDocument: NSViewRepresentable {
    let text: String
    var attributed: AttributedString?
    var highlights: JSONHighlightPlan?
    var fontSize: CGFloat = 12
    var wordWrap: Bool?
    var showInvisibles: Bool?
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> CodeDocumentContainer { CodeDocumentContainer(frame: .zero) }

    func updateNSView(_ view: CodeDocumentContainer, context: Context) {
        view.configure(text: text, attributed: attributed, fontSize: fontSize,
                       wordWrap: wordWrap ?? settings.wordWrap,
                       showInvisibles: showInvisibles ?? settings.showInvisibles,
                       settings: settings, highlights: highlights)
    }
}

enum CodeViewportGeometry {
    static func origin(at fraction: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(0, documentHeight - viewportHeight),
            max(0, min(1, max(0, fraction)) * documentHeight - viewportHeight / 2))
    }

    static func visibleRange(origin: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> ClosedRange<CGFloat> {
        let height = max(1, documentHeight)
        let lower = min(1, max(0, origin / height))
        return lower...min(1, max(lower, (origin + viewportHeight) / height))
    }
}

@MainActor
final class CodeDocumentContainer: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let minimap = CodeMinimapView(frame: .zero)
    private var wordWrap = true
    private var scrollBeyondLastLine = false
    private var styled: Style?
    private var lastAttributed: AttributedString?
    private var lastHighlights: JSONHighlightPlan?
    private var lastLayoutWidth: CGFloat = -1
    private var lastLayoutHeight: CGFloat = -1

    private struct Style: Equatable {
        let size: CGFloat
        let family: String
        let monospaced: Bool
        let tabs: Int
        let wrap: Bool
        let invisibles: Bool
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 240) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.setAccessibilityLabel(Strings.Editor.bodyText)
        scrollView.documentView = textView
        addSubview(scrollView)
        minimap.document = self
        addSubview(minimap)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(text: String, attributed: AttributedString?, fontSize: CGFloat,
                   wordWrap: Bool, showInvisibles: Bool, settings: AppSettings, highlights: JSONHighlightPlan? = nil) {
        textView.setAccessibilityLabel(Strings.Editor.bodyText)
        minimap.updateAccessibilityLabels()
        let style = Style(size: PresentationFonts.resolvedSize(fontSize, settings: settings),
                          family: settings.monospacedFontFamily, monospaced: settings.useMonospacedFont,
                          tabs: settings.codeTabWidth, wrap: wordWrap, invisibles: showInvisibles)
        let changedText = textView.string != text || lastAttributed != attributed || lastHighlights != highlights
        if changedText {
            let selection = textView.selectedRanges
            let output = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.textColor])
            if let attributed {
                var offset = 0
                for run in attributed.runs {
                    let length = String(attributed[run.range].characters).utf16.count
                    if let color = run.foregroundColor, offset + length <= output.length {
                        output.addAttribute(.foregroundColor, value: NSColor(color), range: NSRange(location: offset, length: length))
                    }
                    offset += length
                }
            }
            for span in highlights?.spans ?? [] where span.offset >= 0 && span.length > 0
                && span.offset <= output.length && span.length <= output.length - span.offset {
                output.addAttribute(.foregroundColor, value: JSONHighlighter.color(for: span.kind),
                                    range: NSRange(location: span.offset, length: span.length))
            }
            textView.textStorage?.setAttributedString(output)
            textView.selectedRanges = selection.map {
                let range = $0.rangeValue
                let start = min(range.location, output.length)
                return NSValue(range: NSRange(location: start, length: min(range.length, output.length - start)))
            }
            lastAttributed = attributed
            lastHighlights = highlights
        }
        if styled != style || changedText {
            CodeTextStyle.apply(to: textView, settings: settings, fontSize: fontSize, wordWrap: wordWrap)
            textView.layoutManager?.showsInvisibleCharacters = showInvisibles
            styled = style
            minimap.invalidateSnapshot()
        }
        self.wordWrap = wordWrap
        scrollBeyondLastLine = settings.scrollBeyondLastLine
        minimap.isHidden = !settings.showMinimap
        scrollView.hasHorizontalScroller = !wordWrap
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let mapWidth: CGFloat = minimap.isHidden ? 0 : min(100, max(58, bounds.width * 0.15))
        scrollView.frame = NSRect(x: 0, y: 0, width: max(1, bounds.width - mapWidth), height: bounds.height)
        minimap.frame = NSRect(x: bounds.width - mapWidth, y: 0, width: mapWidth, height: bounds.height)
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        let viewport = scrollView.contentSize
        let width = max(1, viewport.width - textView.textContainerInset.width * 2)
        textView.isHorizontallyResizable = !wordWrap
        container.widthTracksTextView = false
        container.containerSize = NSSize(width: wordWrap ? width : CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let trailingSpace = scrollBeyondLastLine ? max(0, viewport.height * 0.8) : 0
        let documentSize = NSSize(width: wordWrap ? viewport.width : max(viewport.width, ceil(used.maxX) + 20),
                                  height: max(viewport.height, ceil(used.maxY) + 20 + trailingSpace))
        if textView.frame.size != documentSize { textView.setFrameSize(documentSize) }
        // Resizing changes line wrapping and the minimap projection, but scrolling
        // only redraws its viewport overlay and reuses the cached glyph image.
        if lastLayoutWidth != documentSize.width || lastLayoutHeight != documentSize.height {
            lastLayoutWidth = documentSize.width
            lastLayoutHeight = documentSize.height
            minimap.invalidateSnapshot()
        }
        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: min(max(0, origin.x), max(0, documentSize.width - viewport.width)),
                                                  y: min(max(0, origin.y), max(0, documentSize.height - viewport.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func viewportChanged() { minimap.needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        minimap.invalidateSnapshot()
    }
}

@MainActor
final class CodeMinimapView: NSView {
    weak var document: CodeDocumentContainer?
    private(set) var characterSnapshot: NSImage?
    private var snapshotSize = NSSize.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.slider)
        updateAccessibilityLabels()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateAccessibilityLabels() {
        setAccessibilityLabel(Strings.Editor.bodyMinimap)
        setAccessibilityHelp(Strings.Editor.minimapHelp)
    }

    func invalidateSnapshot() { characterSnapshot = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.65).setFill()
        bounds.fill()
        guard let document, bounds.width > 0, bounds.height > 0 else { return }
        if characterSnapshot == nil || snapshotSize != bounds.size { rebuildSnapshot(document) }
        characterSnapshot?.draw(in: bounds)
        let range = CodeViewportGeometry.visibleRange(origin: document.scrollView.contentView.bounds.minY,
                                                      documentHeight: document.textView.bounds.height,
                                                      viewportHeight: document.scrollView.contentSize.height)
        let viewport = NSRect(x: 1, y: range.lowerBound * bounds.height, width: max(1, bounds.width - 2),
                              height: max(2, (range.upperBound - range.lowerBound) * bounds.height))
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        viewport.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
        NSBezierPath(rect: viewport.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    private func rebuildSnapshot(_ document: CodeDocumentContainer) {
        let view = document.textView
        guard let manager = view.layoutManager, let container = view.textContainer,
              bounds.width > 0, bounds.height > 0 else { return }
        manager.ensureLayout(for: container)
        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(true)
        let transform = NSAffineTransform()
        transform.scaleX(by: bounds.width / max(1, view.bounds.width), yBy: bounds.height / max(1, view.bounds.height))
        transform.concat()
        manager.drawGlyphs(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: view.textContainerOrigin)
        image.unlockFocus()
        characterSnapshot = image
        snapshotSize = bounds.size
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        navigate(to: convert(event.locationInWindow, from: nil).y)
    }
    override func mouseDragged(with event: NSEvent) { navigate(to: convert(event.locationInWindow, from: nil).y) }

    func navigate(to y: CGFloat) {
        guard let document else { return }
        let clip = document.scrollView.contentView
        let origin = CodeViewportGeometry.origin(at: y / max(1, bounds.height),
                                                 documentHeight: document.textView.bounds.height,
                                                 viewportHeight: document.scrollView.contentSize.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: origin))
        document.scrollView.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let document else { super.keyDown(with: event); return }
        let current = document.scrollView.contentView.bounds.minY
        let step = document.scrollView.contentSize.height * 0.8
        switch event.keyCode {
        case 126: scroll(to: current - step)
        case 125: scroll(to: current + step)
        case 115: scroll(to: 0)
        case 119: scroll(to: document.textView.bounds.height)
        default: super.keyDown(with: event)
        }
    }

    private func scroll(to origin: CGFloat) {
        guard let document else { return }
        navigate(to: (origin + document.scrollView.contentSize.height / 2) / max(1, document.textView.bounds.height) * bounds.height)
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard let document else { return false }
        scroll(to: document.scrollView.contentView.bounds.minY + document.scrollView.contentSize.height * 0.8)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard let document else { return false }
        scroll(to: document.scrollView.contentView.bounds.minY - document.scrollView.contentSize.height * 0.8)
        return true
    }
}
