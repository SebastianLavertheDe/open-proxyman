import AppKit
import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkAppearanceDisplayEngine(_ test: CoreAssertions, settings: AppSettings) throws {
    test.equal(TrafficColumn.status.localizedTitle(language: "en"), "Status", "Built-in traffic headings use the selected UI language")
    var customColumn = CustomTrafficColumn()
    customColumn.title = "状态"
    test.equal(TrafficColumn.custom(customColumn).localizedTitle(language: "en"), "状态",
               "User-defined column names are preserved even when they match a built-in localized heading")
    settings.fontSize = 22
    test.equal(PresentationFonts.nsFont(settings: settings).pointSize, 22,
               "The configured size reaches real AppKit fonts")
    settings.useMonospacedFont = false
    test.expect(!PresentationFonts.nsFont(settings: settings).isFixedPitch,
                "Turning off monospace selects the proportional system font")
    settings.useMonospacedFont = true
    test.expect(PresentationFonts.nsFont(settings: settings).isFixedPitch,
                "Turning monospace back on restores the chosen fixed-pitch family")
    settings.fontSize = 12

    test.equal(CodeViewportGeometry.origin(at: 0, documentHeight: 1000, viewportHeight: 200), 0,
               "The first minimap point reaches the first line")
    test.equal(CodeViewportGeometry.origin(at: 1, documentHeight: 1000, viewportHeight: 200), 800,
               "The final minimap point reaches the last viewport")
    test.equal(CodeViewportGeometry.origin(at: 0.5, documentHeight: 1000, viewportHeight: 200), 400,
               "A minimap click centres the corresponding document position")
    test.equal(CodeViewportGeometry.origin(at: 1, documentHeight: 80, viewportHeight: 200), 0,
               "A short body never creates a negative scroll origin")
    test.equal(CodeViewportGeometry.visibleRange(origin: 400, documentHeight: 1000, viewportHeight: 200), 0.4...0.6,
               "The viewport overlay follows the same document coordinates as navigation")

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let document = CodeDocumentContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    window.contentView = document
    defer { window.orderOut(nil) }
    settings.showMinimap = true
    settings.scrollBeyondLastLine = false
    let text = (0..<250).map { "line \($0):\t{\"body\":\"selectable source\"}" }.joined(separator: "\n")
    func configure(_ source: String, wrap: Bool = true) {
        document.configure(text: source, attributed: nil, fontSize: 12, wordWrap: wrap,
                           showInvisibles: true, settings: settings)
        document.layoutSubtreeIfNeeded()
    }
    configure(text)
    test.equal(document.textView.string, text, "Body and Raw keep a continuous selectable source instead of page fragments")
    test.expect(document.textView.layoutManager?.showsInvisibleCharacters == true,
                "The native document renderer applies the invisibles switch")
    document.textView.setSelectedRange(NSRange(location: 5, length: 12))
    _ = document.minimap.dataWithPDF(inside: document.minimap.bounds)
    let snapshot = document.minimap.characterSnapshot
    test.expect(snapshot?.tiffRepresentation?.isEmpty == false,
                "The minimap rasterises actual document glyphs")
    document.minimap.navigate(to: document.minimap.bounds.height * 0.8)
    test.expect(document.scrollView.contentView.bounds.minY > document.scrollView.contentSize.height,
                "Clicking the minimap moves the actual text viewport beyond its first screen")
    test.equal(document.textView.selectedRange(), NSRange(location: 5, length: 12),
               "Minimap navigation preserves text selection for copying")
    _ = document.minimap.dataWithPDF(inside: document.minimap.bounds)
    test.expect(snapshot === document.minimap.characterSnapshot,
                "Scrolling reuses the character snapshot and only updates the viewport overlay")
    let height = document.textView.frame.height
    settings.scrollBeyondLastLine = true
    configure(text)
    test.expect(document.textView.frame.height > height + document.scrollView.contentSize.height * 0.7,
                "Scroll beyond last line adds real scrollable space after the final glyph")
    document.minimap.navigate(to: document.minimap.bounds.height)
    test.expect(abs(document.scrollView.contentView.bounds.maxY - document.textView.frame.height) < 1,
                "The minimap can reach the added trailing viewport")
    settings.fontSize = 22
    configure(text)
    test.equal(document.textView.font?.pointSize, 22, "An already open body applies a changed global font size")
    test.equal(document.textView.selectedRange(), NSRange(location: 5, length: 12),
               "Changing appearance preserves the underlying selectable body")
    settings.showMinimap = false
    configure(String(repeating: "W", count: 500), wrap: false)
    test.expect(document.minimap.isHidden && document.scrollView.hasHorizontalScroller
                && document.textView.bounds.width > document.scrollView.contentSize.width,
                "Turning off wrapping allows horizontal scrolling without discarding any characters")
    settings.fontSize = 12
    settings.scrollBeyondLastLine = false
    settings.showMinimap = false

    let icons = AppIconController.styles.compactMap { AppIconController.image(style: $0, size: 64).tiffRepresentation }
    test.expect(icons.count == 4 && Set(icons).count == 4,
                "All four original application icons produce distinct valid raster images")
}
