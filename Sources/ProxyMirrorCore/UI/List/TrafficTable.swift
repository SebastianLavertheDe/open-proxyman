import AppKit
import SwiftUI
import Combine
import ProxyMirrorFoundation

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
    let copyAsCurl: ([Transaction]) -> Void
    let contextMenu: (Transaction, [Transaction]) -> NSMenu
    var copyUsingDefaultFormat: (([Transaction]) -> Void)?
    var sortColumn: TrafficColumn = .sequence
    var ascending = true
    var sort: ((TrafficColumn, Bool) -> Void)?
    @ObservedObject private var presentationSettings = AppSettings.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = Table()
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.style = .plain
        table.rowHeight = ProxymanTheme.rowHeight
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel(Strings.Traffic.requestList)

        let coordinator = context.coordinator
        coordinator.attach(to: table)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? Table else { return }
        table.setAccessibilityLabel(Strings.Traffic.requestList)
        if table.rowHeight != ProxymanTheme.rowHeight {
            table.rowHeight = ProxymanTheme.rowHeight
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
        table.showsAlternatingRows = presentationSettings.showAlternatingRows
        table.needsDisplay = true
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
        private var copyAsCurl: (([Transaction]) -> Void)?
        private var copyUsingDefaultFormat: (([Transaction]) -> Void)?
        private var contextMenu: ((Transaction, [Transaction]) -> NSMenu)?
        private var sort: ((TrafficColumn, Bool) -> Void)?
        private var presentation: Presentation?

        /// 仅呈现偏好改变时刷新整屏单元格；抓包增量由可见记录订阅处理。
        private struct Presentation: Equatable {
            let fontSize: Double
            let useMonospacedFont: Bool
            let monospacedFontFamily: String
            let truncationStyle: String
            let use24HourClock: Bool
            let showFullDate: Bool

            init(_ settings: AppSettings) {
                fontSize = settings.fontSize
                useMonospacedFont = settings.useMonospacedFont
                monospacedFontFamily = settings.monospacedFontFamily
                truncationStyle = settings.truncationStyle
                use24HourClock = settings.use24HourClock
                showFullDate = settings.showFullDate
            }
        }

        func attach(to table: Table) {
            self.table = table
            table.delegate = self
            table.dataSource = self
            table.target = self
            table.action = #selector(selectionAction(_:))
            table.doubleAction = #selector(openClickedRow(_:))
            table.makeMenu = { [weak self] row in self?.menu(for: row) }
            table.copySelectionAsCurl = { [weak self] in self?.copySelectedRowsAsCurl() ?? false }
            table.copySelectionUsingDefaultFormat = { [weak self] in self?.copySelectedRowsUsingDefaultFormat() ?? false }
        }

        func update(_ input: TrafficTable, table: Table) {
            self.table = table
            select = input.select
            open = input.open
            copyAsCurl = input.copyAsCurl
            copyUsingDefaultFormat = input.copyUsingDefaultFormat
            contextMenu = input.contextMenu
            sort = input.sort
            updating = true
            defer { updating = false }

            let nextPresentation = Presentation(AppSettings.shared)
            let presentationChanged = presentation != nextPresentation
            presentation = nextPresentation
            let workspaceChanged = workspaceID != input.workspaceID
            let columnsChanged = !columns.elementsEqual(input.columns, by: ==)
            columns = input.columns
            synchronizeColumns(table, changed: columnsChanged)
            table.sortDescriptors = [NSSortDescriptor(key: input.sortColumn.id, ascending: input.ascending)]
            if workspaceChanged || revision != input.revision {
                updateRows(input.rows, table: table, preserveScroll: !workspaceChanged)
                workspaceID = input.workspaceID
                revision = input.revision
            }
            if columnsChanged { table.reloadData() }

            let selected = IndexSet(input.selectedIDs.compactMap { indexes[$0] })
            if selected != table.selectedRowIndexes {
                table.selectRowIndexes(selected, byExtendingSelection: false)
            }

            let nextFollow = input.followLatest ? input.selectedID : nil
            if let nextFollow, nextFollow != followedID || workspaceChanged, let row = indexes[nextFollow] {
                table.scrollRowToVisible(row)
            }
            followedID = nextFollow
            if presentationChanged { refreshVisibleCells(table) }
        }

        private func refreshVisibleCells(_ table: NSTableView) {
            table.enumerateAvailableRowViews { view, row in
                view.needsDisplay = true
                for column in table.tableColumns.indices {
                    (table.view(atColumn: column, row: row, makeIfNecessary: false) as? Cell)?.refresh()
                }
            }
        }

        private func synchronizeColumns(_ table: NSTableView, changed: Bool) {
            let requested = Set(columns.map { $0.0.id })
            for native in table.tableColumns where !requested.contains(native.identifier.rawValue) {
                table.removeTableColumn(native)
            }
            let savedOrder = UserDefaults.standard.stringArray(forKey: "ui.trafficColumnOrder") ?? []
            let ordered = columns.sorted { left, right in
                (savedOrder.firstIndex(of: left.0.id) ?? (savedOrder.count + (columns.firstIndex { $0.0 == left.0 } ?? 0)))
                    < (savedOrder.firstIndex(of: right.0.id) ?? (savedOrder.count + (columns.firstIndex { $0.0 == right.0 } ?? 0)))
            }
            for (column, width) in ordered {
                let identifier = NSUserInterfaceItemIdentifier(column.id)
                let native = table.tableColumn(withIdentifier: identifier) ?? {
                    let created = NSTableColumn(identifier: identifier)
                    created.minWidth = column == .url ? 100 : column == .ssl ? 29 : 40
                    created.resizingMask = .userResizingMask
                    table.addTableColumn(created)
                    return created
                }()
                native.title = column.localizedTitle()
                native.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
                if changed { native.width = width }
            }
            for (index, entry) in ordered.enumerated() {
                let current = table.column(withIdentifier: NSUserInterfaceItemIdentifier(entry.0.id))
                if current >= 0, current != index { table.moveColumn(current, toColumn: index) }
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first,
                  let column = columns.first(where: { $0.0.id == descriptor.key })?.0 else { return }
            sort?(column, descriptor.ascending)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard !updating, let table else { return }
            let previous = UserDefaults.standard.stringArray(forKey: "ui.trafficColumnOrder") ?? TrafficColumn.allCases.map(\.id)
            let merged = TrafficColumnOrder.merging(visibleOrder: table.tableColumns.map { $0.identifier.rawValue }, previousOrder: previous)
            UserDefaults.standard.set(merged, forKey: "ui.trafficColumnOrder")
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !updating, let table else { return }
            let sizes = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, Double($0.width)) })
            if let data = try? JSONEncoder().encode(sizes) {
                UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "ui.trafficColumnWidths")
            }
            table.enumerateAvailableRowViews { _, row in
                for index in table.tableColumns.indices {
                    (table.view(atColumn: index, row: row, makeIfNecessary: false) as? Cell)?.resizeContent()
                }
            }
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
            if rows.indices.contains(row) { view.configure(rows[row]) }
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn,
                  let column = columns.first(where: { $0.0.id == tableColumn.identifier.rawValue })?.0 else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("traffic-cell-" + column.id)
            let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell ?? Cell()
            view.identifier = identifier
            view.configure(rows[row], columns: [(column, tableColumn.width)], selected: tableView.selectedRowIndexes.contains(row))
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            synchronizeSelection()
        }

        @objc func selectionAction(_ sender: NSTableView) {
            synchronizeSelection()
        }

        private var selectedRows: [Transaction] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        }

        private func synchronizeSelection() {
            guard !updating, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            select?(ids)
        }

        private func copySelectedRowsAsCurl() -> Bool {
            guard let copyAsCurl else { return false }
            let targets = selectedRows
            guard !targets.isEmpty else { return false }
            select?(Set(targets.map(\.id)))
            copyAsCurl(targets)
            return true
        }

        private func copySelectedRowsUsingDefaultFormat() -> Bool {
            guard let copyUsingDefaultFormat else { return false }
            let targets = selectedRows
            guard !targets.isEmpty else { return false }
            select?(Set(targets.map(\.id)))
            copyUsingDefaultFormat(targets)
            return true
        }

        @objc func openClickedRow(_ sender: NSTableView) {
            if rows.indices.contains(sender.clickedRow) { open?(rows[sender.clickedRow].id) }
        }

        func menu(for row: Int) -> NSMenu? {
            guard let table, rows.indices.contains(row) else { return nil }
            let clicked = rows[row]
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let targets = selectedRows
            let menuTargets = targets.isEmpty ? [clicked] : targets
            select?(Set(menuTargets.map(\.id)))
            return contextMenu?(clicked, menuTargets)
        }
    }

    final class Table: NSTableView {
        var makeMenu: ((Int) -> NSMenu?)?
        var copySelectionAsCurl: (() -> Bool)?
        var copySelectionUsingDefaultFormat: (() -> Bool)?
        var showsAlternatingRows = true

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            switch TrafficCopyShortcut.resolve(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) {
            case .preferred where copySelectionUsingDefaultFormat?() == true: return true
            case .curl where copySelectionAsCurl?() == true: return true
            default: break
            }
            return super.performKeyEquivalent(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            window?.makeFirstResponder(self)
            return makeMenu?(row(at: convert(event.locationInWindow, from: nil)))
        }

        override func drawBackground(inClipRect clipRect: NSRect) {
            ProxymanTheme.tableBackgroundColor.setFill()
            clipRect.fill()
            guard showsAlternatingRows else { return }
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

    @MainActor
    private final class Row: NSTableRowView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("traffic-row")
        private var transaction: Transaction?
        private var transactionChanges: AnyCancellable?
        private var paletteChanges: AnyCancellable?

        func configure(_ transaction: Transaction) {
            if self.transaction !== transaction {
                self.transaction = transaction
                transactionChanges = transaction.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
                    self?.needsDisplay = true
                }
            }
            if paletteChanges == nil {
                paletteChanges = TrafficFilterPalette.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
                    self?.needsDisplay = true
                }
            }
            needsDisplay = true
        }

        override var isSelected: Bool {
            didSet { subviews.compactMap { $0 as? Cell }.forEach { $0.setSelected(isSelected) } }
        }

        override func drawBackground(in dirtyRect: NSRect) {
            guard !isSelected, let transaction,
                  let name = transaction.highlightName ?? TrafficFilterPalette.shared.highlight(for: transaction) else { return }
            let color = NSColor(ProxymanTheme.highlightColor(name))
            TrafficRowPresentation.background(selected: false, highlight: color, alternate: false).setFill()
            bounds.intersection(dirtyRect).fill()
        }

        override func drawSelection(in dirtyRect: NSRect) {
            guard isSelected else { return }
            ProxymanTheme.tableSelectionColor.setFill()
            bounds.intersection(dirtyRect).fill()
        }
    }

    @MainActor
    private final class Cell: NSTableCellView {
        private let badgeBackground = NSView()
        private let label = NSTextField(labelWithString: "")
        private let icon = NSImageView()
        private var transaction: Transaction?
        private var column: TrafficColumn?
        private var selected = false
        private var transactionChanges: AnyCancellable?
        private var derivedChanges: AnyCancellable?
        private var refreshScheduled = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            badgeBackground.wantsLayer = true
            badgeBackground.layer?.cornerRadius = 4
            badgeBackground.isHidden = true
            badgeBackground.setAccessibilityElement(false)
            label.isSelectable = false
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.setAccessibilityElement(false)
            addSubview(badgeBackground)
            addSubview(label)
            addSubview(icon)
            textField = label
            imageView = icon
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ transaction: Transaction, columns: [(TrafficColumn, CGFloat)], selected: Bool) {
            if self.transaction !== transaction {
                self.transaction = transaction
                transactionChanges = transaction.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.scheduleRefresh() }
            }
            column = columns.first?.0
            let usesDerivedValues: Bool
            switch column { case .custom, .graphql: usesDerivedValues = true; default: usesDerivedValues = false }
            if usesDerivedValues, derivedChanges == nil {
                derivedChanges = CustomColumnValues.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.scheduleRefresh() }
            } else if !usesDerivedValues { derivedChanges = nil }
            self.selected = selected
            refresh()
        }

        func setSelected(_ selected: Bool) {
            guard self.selected != selected else { return }
            self.selected = selected
            refresh()
        }

        private func scheduleRefresh() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            RunLoop.main.perform { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }

        func refresh() {
            guard let transaction, let column else { return }
            let settings = AppSettings.shared
            let content = TrafficColumnPresentation.text(column, transaction: transaction)
            let isBadge = column == .method || column == .status
            label.font = PresentationFonts.nsFont(size: isBadge ? 11 : 12, weight: isBadge ? .semibold : .regular)
            label.alignment = isBadge ? .center : column == .sequence ? .right : .left
            switch settings.truncationStyle {
            case "head": label.lineBreakMode = .byTruncatingHead
            case "tail": label.lineBreakMode = .byTruncatingTail
            default: label.lineBreakMode = .byTruncatingMiddle
            }
            let color: NSColor = column == .status ? transaction.statusColor : column == .method ? transaction.methodColor : .labelColor
            let foreground: NSColor = selected ? .white : color
            let attributes: [NSAttributedString.Key: Any] = [
                .font: label.font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: foreground,
                .strikethroughStyle: column == .url && transaction.strikethrough ? NSUnderlineStyle.single.rawValue : 0
            ]
            label.attributedStringValue = NSAttributedString(string: content, attributes: attributes)
            badgeBackground.isHidden = !isBadge
            badgeBackground.layer?.backgroundColor = isBadge ? color.withAlphaComponent(selected ? 0.28 : 0.16).cgColor : nil
            icon.image = nil
            switch column {
            case .client: icon.image = transaction.clientIcon ?? NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
            case .ssl where transaction.isTLSIntercepted: icon.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: Strings.Traffic.decrypted)
            case .edited where transaction.originalURL != nil: icon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: Strings.Traffic.edited)
            case .url where transaction.suspectedPinning: icon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: Strings.Traffic.possibleSslCertificatePinning)
            default: break
            }
            icon.contentTintColor = selected ? .white : column == .url ? .systemOrange : .secondaryLabelColor
            toolTip = TrafficColumnPresentation.tooltip(column, transaction: transaction)
            setAccessibilityLabel(content.isEmpty ? toolTip : content)
            needsLayout = true
        }

        func resizeContent() { needsLayout = true }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let hasIcon = icon.image != nil
            icon.isHidden = !hasIcon
            icon.frame = backingAlignedRect(
                NSRect(x: 6, y: (bounds.height - 15) / 2, width: 15, height: 15),
                options: [.alignAllEdgesNearest])
            let inset: CGFloat = hasIcon ? 26 : 6
            // 字体包围盒覆盖所有字形，不能当作单行控件高度；居中后按实际屏幕像素对齐。
            let contentSize = label.fittingSize
            let height = min(bounds.height, ceil(contentSize.height))
            let availableWidth = max(0, bounds.width - inset - 6)
            var textX = inset
            var textWidth = availableWidth
            if column == .method || column == .status {
                // 徽章按文字加留白收紧，列宽只限制最大宽度，不拉伸背景。
                let padding: CGFloat = 5
                let badgeWidth = min(availableWidth, ceil(contentSize.width) + padding * 2)
                let badgeHeight = min(bounds.height, max(17, CGFloat(AppSettings.shared.fontSize) + 5))
                badgeBackground.frame = backingAlignedRect(
                    NSRect(x: inset, y: max(0, (bounds.height - badgeHeight) / 2),
                           width: badgeWidth, height: badgeHeight),
                    options: [.alignAllEdgesNearest])
                textX = badgeBackground.frame.minX + padding
                textWidth = max(0, badgeBackground.frame.width - padding * 2)
            } else {
                badgeBackground.frame = .zero
            }
            label.frame = backingAlignedRect(
                NSRect(x: textX, y: max(0, (bounds.height - height) / 2),
                       width: textWidth, height: height),
                options: [.alignAllEdgesNearest])
        }

        override var backgroundStyle: NSView.BackgroundStyle {
            didSet {
                var ancestor = superview
                while let view = ancestor {
                    if let row = view as? NSTableRowView { setSelected(row.isSelected); return }
                    ancestor = view.superview
                }
                setSelected(backgroundStyle == .emphasized)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

}

private final class TrafficMenuAction: NSObject {
    static let shared = TrafficMenuAction()

    @objc func invokeTrafficMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? () -> Void else { return }
        // Keep the action alive after menu tracking ends, and open sheets or write
        // to the pasteboard from the normal main run loop.
        RunLoop.main.perform(inModes: [.default]) { action() }
    }
}

extension NSMenu {
    func addAction(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        autoenablesItems = false
        let item = NSMenuItem(title: title, action: #selector(TrafficMenuAction.invokeTrafficMenuAction(_:)), keyEquivalent: "")
        item.target = TrafficMenuAction.shared
        item.representedObject = action
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
