import AppKit
@testable import ProxyMirrorCore

@MainActor
func checkTrafficMenu(_ test: CoreAssertions) throws {
    _ = NSApplication.shared
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    test.expect(CopyPaste.copy("previous clipboard", to: pasteboard), "Pasteboard accepts text")
    test.expect(!CopyPaste.copy("", to: pasteboard), "Empty selection reports copy failure")
    test.equal(pasteboard.string(forType: .string), "previous clipboard",
               "Empty selection preserves the previous clipboard")

    let request = Transaction()
    request.method = "POST"
    request.scheme = "https"
    request.host = "example.test"
    request.port = 443
    request.path = "/telemetry"
    request.query = "q=1"
    request.requestHeaders = HTTPHeaders([("Content-Type", "application/json")])
    request.requestBody = Data("{\"event\":\"测试\"}".utf8)

    var copied: Bool?
    var submenuInvocations = 0
    autoreleasepool {
        let menu = NSMenu()
        menu.addAction("复制为 cURL") {
            copied = CopyPaste.copy(ExportService.curlCommand(request), to: pasteboard)
        }
        menu.addSubmenu("复制为代码") { submenu in
            submenu.addAction("Python requests") { submenuInvocations += 1 }
        }
        menu.performActionForItem(at: 0)
        menu.item(at: 1)?.submenu?.performActionForItem(at: 0)
    }

    // AppKit dispatches the selector; the action must survive the temporary menu
    // and execute when the main run loop returns to its normal mode.
    let deadline = Date().addingTimeInterval(2)
    while (copied == nil || submenuInvocations == 0) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    test.equal(copied, true, "AppKit menu action writes to the pasteboard")
    test.equal(submenuInvocations, 1, "Submenu action executes once after menu release")
    let command = pasteboard.string(forType: .string) ?? ""
    test.expect(command.hasPrefix("curl 'https://example.test/telemetry?q=1'"),
                "Copied cURL includes the selected request URL")
    test.expect(command.contains("-X POST"), "Copied cURL includes the request method")
    test.expect(command.contains("-H 'Content-Type: application/json'"),
                "Copied cURL includes the request headers")
    test.expect(command.contains("--data-raw '{\"event\":\"测试\"}'"),
                "Copied cURL includes the UTF-8 request body")

    try checkTableSelection(test, pasteboard: pasteboard)
}

@MainActor
private func checkTableSelection(_ test: CoreAssertions, pasteboard: NSPasteboard) throws {
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TrafficStore(sourceFolderFile: directory.appendingPathComponent("folders.json"),
                             savedFile: directory.appendingPathComponent("saved.proxymirror"))
    let first = Transaction()
    first.host = "first.example.test"
    let second = Transaction()
    second.host = "second.example.test"
    store.add(first)
    store.add(second)

    let table = TrafficTable.Table()
    table.allowsMultipleSelection = true
    table.allowsEmptySelection = true
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("request")))
    let coordinator = TrafficTable.Coordinator()
    defer { withExtendedLifetime(coordinator) {} }
    coordinator.attach(to: table)
    var menuTargets: [UUID] = []
    var copiedIDs: [UUID] = []
    let input = TrafficTable(rows: [first, second], revision: 1, workspaceID: store.id,
        columns: [], selectedIDs: [], selectedID: nil, followLatest: false,
        select: store.selectManually, open: { _ in }, copyAsCurl: { targets in
            copiedIDs = targets.map(\.id)
            CopyPaste.copy(targets.map(ExportService.curlCommand).joined(separator: "\n"), to: pasteboard)
        }, contextMenu: { _, targets in
            menuTargets = targets.map(\.id)
            return NSMenu()
        })
    coordinator.update(input, table: table)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = table
    defer { window.close() }
    test.expect(window.makeFirstResponder(table), "Request table becomes the keyboard target")

    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    test.equal(store.selectedIDs, [first.id], "Native row selection reaches the request store")
    test.equal(store.selectedTransactions.map(\.id), [first.id], "Menu commands resolve the selected request")

    // A row may already be selected in AppKit while a model update is pending.
    // Opening its context menu must explicitly synchronize the command selection.
    store.selectedIDs = []
    _ = coordinator.menu(for: 0)
    test.equal(menuTargets, [first.id], "Context menu receives the clicked request")
    test.equal(store.selectedIDs, [first.id], "Context menu repairs stale command selection")

    _ = coordinator.menu(for: 1)
    test.equal(menuTargets, [second.id], "Right-clicking another row changes the action target")
    test.equal(store.selectedIDs, [second.id], "Right-clicking another row updates menu commands")

    table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    store.selectedIDs = []
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
        timestamp: 0, windowNumber: 0, context: nil, characters: "C", charactersIgnoringModifiers: "c",
        isARepeat: false, keyCode: 8)
    guard let event else { test.expect(false, "Create the copy-as-cURL keyboard event"); return }
    test.expect(table.performKeyEquivalent(with: event), "Request table handles Shift-Command-C")
    test.equal(copiedIDs, [first.id, second.id], "Keyboard action copies every selected native row")
    test.equal(store.selectedIDs, [first.id, second.id], "Keyboard action synchronizes command selection")
    let commands = pasteboard.string(forType: .string) ?? ""
    test.expect(commands.contains("first.example.test") && commands.contains("second.example.test"),
                "Keyboard action writes cURL commands for both requests")

    copiedIDs = []
    window.makeFirstResponder(nil)
    _ = table.performKeyEquivalent(with: event)
    test.expect(copiedIDs.isEmpty, "Unfocused request table does not intercept another view's shortcut")

    window.makeFirstResponder(table)
    table.deselectAll(nil)
    _ = table.performKeyEquivalent(with: event)
    test.expect(copiedIDs.isEmpty, "Keyboard action does not copy an empty selection")
    test.equal(pasteboard.string(forType: .string), commands, "Empty table selection preserves the clipboard")
}
