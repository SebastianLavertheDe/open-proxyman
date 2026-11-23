import AppKit
import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkPresentationSettings(_ test: CoreAssertions) throws {
    let suite = "pm-presentation-check-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { throw NSError(domain: "PresentationChecks", code: 1) }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    for query in ["字体", "Tab 宽度", "24小时", "日期", "斑马纹"] {
        test.expect(SettingsSearchTarget.results(for: query).contains(.displayBehavior),
                    "Presentation settings search finds \(query)")
    }
    test.expect(SettingsSearchTarget.results(for: "默认复制").contains(.copyBehavior),
                "Settings search finds the default copy format")
    test.expect(settings.monospacedFontFamily.isEmpty && settings.codeTabWidth == 4 && settings.use24HourClock
        && !settings.showFullDate && settings.showAlternatingRows && settings.defaultCopyFormat == .curl,
                "Presentation defaults preserve system monospace, four-column tabs, 24-hour times, zebra rows and cURL")
    settings.monospacedFontFamily = "unavailable-test-font"
    settings.codeTabWidth = 8
    settings.use24HourClock = false
    settings.showFullDate = true
    settings.showAlternatingRows = false
    settings.defaultCopyFormat = .python
    let reloaded = AppSettings(defaults: defaults)
    test.expect(reloaded.monospacedFontFamily == "unavailable-test-font" && reloaded.codeTabWidth == 8
        && !reloaded.use24HourClock && reloaded.showFullDate && !reloaded.showAlternatingRows
        && reloaded.defaultCopyFormat == .python, "Presentation settings persist and reload through UserDefaults")
    test.expect(PresentationFonts.nsFont(size: 12, settings: reloaded).isFixedPitch,
                "Unavailable font families fall back to an actual fixed-pitch system font")
    if let family = PresentationFonts.availableFamilies.first {
        settings.monospacedFontFamily = family
        let selected = PresentationFonts.nsFont(size: 12, settings: settings)
        test.expect(selected.isFixedPitch && selected.familyName == family,
                    "Font chooser uses installed fixed-pitch families and applies the selected family")
    }
    defaults.set(0, forKey: "ui.codeTabWidth")
    test.equal(reloaded.codeTabWidth, 1, "Invalid low tab widths are bounded")
    defaults.set(999, forKey: "ui.codeTabWidth")
    test.equal(reloaded.codeTabWidth, 16, "Invalid high tab widths are bounded")
    defaults.set("unknown-generator", forKey: "export.defaultCopyFormat")
    test.equal(reloaded.defaultCopyFormat, .curl, "Unknown persisted copy formats fall back to cURL")

    let date = Date(timeIntervalSince1970: 13 * 3600 + 4 * 60 + 5.123)
    let utc = TimeZone(secondsFromGMT: 0)!
    settings.use24HourClock = true; settings.showFullDate = false
    test.equal(PresentationTime.string(from: date, settings: settings, timeZone: utc), "13:04:05.123",
               "Shared traffic and WebSocket formatter honors 24-hour time")
    settings.use24HourClock = false
    test.equal(PresentationTime.string(from: date, settings: settings, timeZone: utc), "01:04:05.123 PM",
               "Changing clock preferences invalidates the formatter cache key")
    settings.showFullDate = true
    test.equal(PresentationTime.string(from: date, settings: settings, timeZone: utc), "1970-01-01 01:04:05.123 PM",
               "Full-date timestamps include the date with the selected clock style")
    test.equal(PresentationTime.string(from: date, uses24HourClock: true, includesDate: false,
                                       timeZone: TimeZone(secondsFromGMT: 8 * 3600)!), "21:04:05.123",
               "Formatter cache keys include time zone changes")
    test.equal(PresentationTime.string(from: date, uses24HourClock: true, includesDate: false, timeZone: utc), "13:04:05.123",
               "Reusing an earlier format retrieves the correctly keyed formatter")

    _ = NSApplication.shared
    settings.codeTabWidth = 4
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    editor.string = "a\tb"
    editor.textContainerInset = .zero
    editor.textContainer?.lineFragmentPadding = 0
    editor.textContainer?.containerSize = NSSize(width: 500, height: 500)
    CodeTextStyle.apply(to: editor, settings: settings, fontSize: 12)
    let font = PresentationFonts.nsFont(size: 12, settings: settings)
    let four = (editor.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.defaultTabInterval ?? 0
    let space = (" " as NSString).size(withAttributes: [.font: font]).width
    test.expect(abs(four - 4 * space) < 0.1 && editor.defaultParagraphStyle?.tabStops.isEmpty == true,
                "Code paragraph styles use repeated four-column tab intervals instead of system tab stops")
    let firstPosition: CGFloat
    if let layout = editor.layoutManager, let container = editor.textContainer {
        layout.ensureLayout(for: container)
        firstPosition = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: 2)).x
    } else { firstPosition = 0 }
    settings.codeTabWidth = 8
    CodeTextStyle.apply(to: editor, settings: settings, fontSize: 12)
    if let layout = editor.layoutManager, let container = editor.textContainer {
        layout.ensureLayout(for: container)
        let secondPosition = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: 2)).x
        test.expect(secondPosition > firstPosition + space * 2,
                    "Changing tab width moves the following glyph in NSTextView's real layout")
    } else { test.expect(false, "Code editor provides an AppKit layout manager") }
    test.equal(editor.string, "a\tb", "Tab preferences preserve the original selectable text")

    let selected = TrafficRowPresentation.background(selected: true, highlight: .red, alternate: true)
    test.equal(selected, ProxymanTheme.tableSelectionColor, "Selection color has priority over highlights and zebra rows")
    test.equal(TrafficRowPresentation.background(selected: false, highlight: .red, alternate: true),
               TrafficRowPresentation.background(selected: false, highlight: .red, alternate: false),
               "Highlighted rows keep the same background on both stripe positions")
    test.equal(TrafficRowPresentation.background(selected: false, highlight: nil, alternate: false),
               ProxymanTheme.tableBackgroundColor, "Disabling stripes uses the base row color")

    settings.defaultCopyFormat = .python
    let tx = Transaction(); tx.host = "copy.example.test"; tx.path = "/sample"; tx.requestBodyComplete = true
    test.expect(RequestCode.generate(tx, format: settings.defaultCopyFormat).contains("import requests"),
                "Default copy format generates the configured client code")
    test.expect(RequestCode.generate(tx, format: .curl).hasPrefix("curl "),
                "Explicit Copy as cURL remains independent from the default format")
    test.equal(TrafficCopyShortcut.resolve(characters: "c", modifiers: [.command]), .preferred,
               "Command-C routes to the configured copy format")
    test.equal(TrafficCopyShortcut.resolve(characters: "C", modifiers: [.command, .shift]), .curl,
               "Shift-Command-C routes to fixed cURL generation")
    test.expect(TrafficCopyShortcut.resolve(characters: "c", modifiers: [.command, .option]) == nil,
                "Unrelated copy key combinations remain with the responder chain")
    try checkDefaultCopyKeyboard(test, settings: settings)
}


@MainActor
private func checkDefaultCopyKeyboard(_ test: CoreAssertions, settings: AppSettings) throws {
    let first = Transaction(); first.host = "first.copy.test"; first.requestBodyComplete = true
    let second = Transaction(); second.host = "second.copy.test"; second.requestBodyComplete = true
    let table = TrafficTable.Table()
    table.allowsMultipleSelection = true
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("request")))
    let coordinator = TrafficTable.Coordinator()
    coordinator.attach(to: table)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally(); withExtendedLifetime(coordinator) {} }
    var preferredCalls = 0
    var curlCalls = 0
    let input = TrafficTable(rows: [first, second], revision: 1, workspaceID: UUID(), columns: [],
        selectedIDs: [], selectedID: nil, followLatest: false, select: { _ in }, open: { _ in },
        copyAsCurl: { targets in
            curlCalls += 1
            CopyPaste.copy(targets.map(ExportService.curlCommand).joined(separator: "\n"), to: pasteboard)
        }, contextMenu: { _, _ in NSMenu() }, copyUsingDefaultFormat: { targets in
            preferredCalls += 1
            CopyPaste.copy(targets.map { RequestCode.generate($0, format: settings.defaultCopyFormat) }.joined(separator: "\n\n"), to: pasteboard)
        })
    coordinator.update(input, table: table)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = table
    defer { window.close() }
    test.expect(window.makeFirstResponder(table), "Default-copy regression table becomes first responder")
    table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    settings.defaultCopyFormat = .python
    let preferred = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
        isARepeat: false, keyCode: 8)
    let explicitCurl = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "C", charactersIgnoringModifiers: "c",
        isARepeat: false, keyCode: 8)
    guard let preferred, let explicitCurl else { test.expect(false, "Copy keyboard events can be created"); return }
    test.expect(table.performKeyEquivalent(with: preferred) && preferredCalls == 1 && curlCalls == 0,
                "Native table Command-C invokes the configured formatter for selected rows")
    let code = pasteboard.string(forType: .string) ?? ""
    test.expect(code.contains("import requests") && code.contains("first.copy.test") && code.contains("second.copy.test"),
                "Native default copy writes code for every selected row")
    test.expect(table.performKeyEquivalent(with: explicitCurl) && curlCalls == 1 && preferredCalls == 1,
                "Native table Shift-Command-C keeps its explicit cURL action")
    test.expect(pasteboard.string(forType: .string)?.hasPrefix("curl ") == true,
                "Explicit cURL action writes a cURL command despite a Python default")
    window.makeFirstResponder(nil)
    _ = table.performKeyEquivalent(with: preferred)
    test.equal(preferredCalls, 1, "An unfocused request table preserves text editors' normal Command-C")
}
