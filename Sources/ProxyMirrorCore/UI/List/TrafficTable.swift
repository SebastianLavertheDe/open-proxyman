import AppKit
import SwiftUI

@MainActor
struct TrafficTable: NSViewRepresentable {
    let rows: [Transaction]
    let revision: UInt64
    let workspaceID: UUID
    let columns: [(TrafficColumn, CGFloat)]
    let selectedIDs: Set<Transaction.ID>
    let selectedID: Transaction.ID?
    let followLatest: Bool
    let select: (Set<Transaction.ID>) -> Void
    let open: (Transaction.ID) -> Void
    let contextMenu: (Transaction, [Transaction]) -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = Table()
        table.headerView = nil
        table.style = .plain
        table.rowHeight = ProxymanTheme.rowHeight
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("request")))
        table.setAccessibilityLabel("请求列表")

        let coordinator = context.coordinator
        table.delegate = coordinator
        table.dataSource = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.openClickedRow(_:))
        table.makeMenu = { [weak coordinator] row in coordinator?.menu(for: row) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? Table else { return }
        context.coordinator.update(self, table: table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var rows: [Transaction] = []
        private var indexes: [Transaction.ID: Int] = [:]
        private var columns: [(TrafficColumn, CGFloat)] = []
        private var workspaceID: UUID?
        private var revision: UInt64?
        private var followedID: Transaction.ID?
        private var updating = false
        private weak var table: Table?
        private var select: ((Set<Transaction.ID>) -> Void)?
        private var open: ((Transaction.ID) -> Void)?
        private var contextMenu: ((Transaction, [Transaction]) -> NSMenu)?

        func update(_ input: TrafficTable, table: Table) {
            self.table = table
            select = input.select
            open = input.open
            contextMenu = input.contextMenu
            updating = true
            defer { updating = false }

            let workspaceChanged = workspaceID != input.workspaceID
            let columnsChanged = !columns.elementsEqual(input.columns, by: ==)
            columns = input.columns
            if workspaceChanged || revision != input.revision {
                updateRows(input.rows, table: table, preserveScroll: !workspaceChanged)
                workspaceID = input.workspaceID
                revision = input.revision
            }
            if columnsChanged {
                table.enumerateAvailableRowViews { _, row in
                    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell)?.setColumns(self.columns)
                }
            }

            let selected = IndexSet(input.selectedIDs.compactMap { indexes[$0] })
            if selected != table.selectedRowIndexes {
                table.selectRowIndexes(selected, byExtendingSelection: false)
            }

            let nextFollow = input.followLatest ? input.selectedID : nil
            if let nextFollow, nextFollow != followedID || workspaceChanged, let row = indexes[nextFollow] {
                table.scrollRowToVisible(row)
            }
            followedID = nextFollow
        }

        private func updateRows(_ incoming: [Transaction], table: Table, preserveScroll: Bool) {
            // Keep existing row views when new captures append, including when the retention limit drops old rows.
            let oldStart = incoming.first.flatMap { indexes[$0.id] }
            if preserveScroll, let oldStart, incoming.count >= rows.count - oldStart,
               zip(rows[oldStart...], incoming).allSatisfy({ $0 === $1 }) {
                updateCaptureRows(incoming, removing: oldStart, table: table)
                return
            }

            let top = table.visibleRect.minY
            let topIndex = table.row(at: CGPoint(x: table.visibleRect.midX, y: top))
            let anchor = preserveScroll && rows.indices.contains(topIndex) ? rows[topIndex].id : nil
            let offset = anchor == nil ? 0 : top - table.rect(ofRow: topIndex).minY
            rows = incoming
            rebuildIndexes()
            table.reloadData()
            if let anchor, let row = indexes[anchor] {
                table.scroll(NSPoint(x: 0, y: table.rect(ofRow: row).minY + offset))
            } else if !preserveScroll {
                table.scroll(.zero)
            }
        }

        private func updateCaptureRows(_ incoming: [Transaction], removing removed: Int, table: Table) {
            let firstAdded = rows.count - removed
            rows = incoming
            guard removed > 0 || incoming.count > firstAdded else { return }
            if removed > 0 {
                rebuildIndexes()
            } else {
                for index in firstAdded..<incoming.count { indexes[incoming[index].id] = index }
            }

            let previousTop = table.visibleRect.minY
            table.beginUpdates()
            if removed > 0 {
                table.removeRows(at: IndexSet(integersIn: 0..<removed), withAnimation: [])
            }
            if firstAdded < incoming.count {
                table.insertRows(at: IndexSet(integersIn: firstAdded..<incoming.count), withAnimation: [])
            }
            table.endUpdates()
            if removed > 0 {
                let top = max(0, previousTop - CGFloat(removed) * table.rowHeight)
                table.scroll(NSPoint(x: 0, y: top))
            }
        }

        private func rebuildIndexes() {
            indexes = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) },
                                 uniquingKeysWith: { first, _ in first })
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: Row.reuseIdentifier, owner: nil) as? Row ?? Row()
            view.identifier = Row.reuseIdentifier
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let view = tableView.makeView(withIdentifier: Cell.reuseIdentifier, owner: nil) as? Cell ?? Cell()
            view.identifier = Cell.reuseIdentifier
            view.configure(rows[row], columns: columns, selected: tableView.selectedRowIndexes.contains(row))
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            select?(ids)
        }

        @objc func openClickedRow(_ sender: NSTableView) {
            if rows.indices.contains(sender.clickedRow) { open?(rows[sender.clickedRow].id) }
        }

        func menu(for row: Int) -> NSMenu? {
            guard let table, rows.indices.contains(row) else { return nil }
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let targets = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            return contextMenu?(rows[row], targets)
        }
    }

    final class Table: NSTableView {
        var makeMenu: ((Int) -> NSMenu?)?

        override func menu(for event: NSEvent) -> NSMenu? {
            makeMenu?(row(at: convert(event.locationInWindow, from: nil)))
        }

        override func drawBackground(inClipRect clipRect: NSRect) {
            ProxymanTheme.tableBackgroundColor.setFill()
            clipRect.fill()
            ProxymanTheme.tableAlternateColor.setFill()
            let stride = rowHeight * 2
            guard stride > 0 else { return }
            var y = floor(clipRect.minY / stride) * stride + rowHeight
            while y < clipRect.maxY {
                NSRect(x: clipRect.minX, y: y, width: clipRect.width, height: rowHeight).intersection(clipRect).fill()
                y += stride
            }
        }
    }

    private final class Row: NSTableRowView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("traffic-row")

        override func drawSelection(in dirtyRect: NSRect) {
            guard isSelected else { return }
            ProxymanTheme.tableSelectionColor.setFill()
            bounds.intersection(dirtyRect).fill()
        }
    }

    private final class Cell: NSTableCellView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("traffic-cell")

        private var transaction: Transaction?
        private var columns: [(TrafficColumn, CGFloat)] = []
        private var selected = false
        private var host: NSHostingView<TrafficRow>?

        func configure(_ transaction: Transaction, columns: [(TrafficColumn, CGFloat)], selected: Bool) {
            self.transaction = transaction
            self.columns = columns
            self.selected = selected
            updateContent()
        }

        func setColumns(_ columns: [(TrafficColumn, CGFloat)]) {
            self.columns = columns
            updateContent()
        }

        func setSelected(_ selected: Bool) {
            guard self.selected != selected else { return }
            self.selected = selected
            updateContent()
        }

        private func updateContent() {
            guard let transaction else { return }
            let content = TrafficRow(tx: transaction, columns: columns, isSelected: selected)
            if let host {
                host.rootView = content
            } else {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                host.frame = bounds
                host.autoresizingMask = [.width, .height]
                addSubview(host)
                self.host = host
            }
        }

        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { setSelected(backgroundStyle == .emphasized) }
        }

        // The row content is display-only. Let the table handle selection, double-clicks and menus.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private final class TrafficMenuAction: NSObject {
    let invoke: () -> Void

    init(_ invoke: @escaping () -> Void) { self.invoke = invoke }

    @objc func perform(_ sender: NSMenuItem) { invoke() }
}

extension NSMenu {
    func addAction(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        autoenablesItems = false
        let target = TrafficMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(TrafficMenuAction.perform(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = enabled
        addItem(item)
    }

    func addSubmenu(_ title: String, enabled: Bool = true, content: (NSMenu) -> Void) {
        autoenablesItems = false
        let submenu = NSMenu(title: title)
        content(submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = enabled
        addItem(item)
    }
}
