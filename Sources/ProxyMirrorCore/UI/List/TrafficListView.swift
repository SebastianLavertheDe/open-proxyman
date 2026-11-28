import AppKit
import SwiftUI

enum TrafficColumn: Hashable, Identifiable {
    case sequence, url, client, method, status, time, duration, request, response, ssl, edited, comment, tools, graphql, scheme, contentType
    case custom(CustomTrafficColumn)

    static let allCases: [Self] = [.sequence, .url, .client, .method, .status, .time, .duration, .request, .response, .ssl, .edited, .comment, .tools, .graphql, .scheme, .contentType]

    var id: String {
        if case .custom(let field) = self { return field.id.uuidString }
        switch self {
        case .sequence: return "sequence"
        case .url: return "url"
        case .client: return "client"
        case .method: return "method"
        case .status: return "status"
        case .time: return "time"
        case .duration: return "duration"
        case .request: return "request"
        case .response: return "response"
        case .ssl: return "ssl"
        case .edited: return "edited"
        case .comment: return "comment"
        case .tools: return "tools"
        case .graphql: return "graphql"
        case .scheme: return "scheme"
        case .contentType: return "contentType"
        case .custom: preconditionFailure("Custom column ID handled above")
        }
    }

    var title: String {
        switch self {
        case .sequence: return "#"
        case .url: return Strings.Traffic.url
        case .client: return Strings.Traffic.client
        case .method: return Strings.Traffic.method
        case .status: return Strings.Traffic.status
        case .time: return Strings.Traffic.time
        case .duration: return Strings.Traffic.duration
        case .request: return Strings.Traffic.request
        case .response: return Strings.Traffic.response
        case .ssl: return "SSL"
        case .edited: return Strings.Traffic.edited
        case .comment: return Strings.Traffic.comment
        case .tools: return Strings.Traffic.tools
        case .graphql: return Strings.Traffic.graphqlOperation
        case .scheme: return Strings.Traffic.scheme
        case .contentType: return Strings.Traffic.contentType
        case .custom(let field): return field.title
        }
    }

    /// Column IDs remain stable across languages, and custom names belong to the user.
    func localizedTitle(language: String? = nil) -> String {
        guard let language else { return title }
        let key: String
        switch self {
        case .sequence, .ssl, .custom: return title
        case .url: key = "url"
        case .client: key = "client"
        case .method: key = "method"
        case .status: key = "status"
        case .time: key = "time"
        case .duration: key = "duration"
        case .request: key = "request"
        case .response: key = "response"
        case .edited: key = "edited"
        case .comment: key = "comment"
        case .tools: key = "tools"
        case .graphql: key = "graphql_operation"
        case .scheme: key = "scheme"
        case .contentType: key = "content_type"
        }
        return L10n.render(table: "Traffic", key: key, arguments: [], englishFallback: title, language: language)
    }

    var preferredWidth: CGFloat {
        switch self {
        case .sequence: return 42
        case .url: return 506
        case .client: return 143
        case .method: return 70
        case .status: return 78
        case .time:
            let settings = AppSettings.shared
            let base: CGFloat = settings.showFullDate ? (settings.use24HourClock ? 245 : 275) : (settings.use24HourClock ? 100 : 128)
            return base * CGFloat(settings.fontSize) / 12
        case .duration: return 72
        case .request, .response: return 73
        case .ssl: return 31
        case .edited: return 47
        case .comment: return 269
        case .tools: return 107
        case .graphql: return 160
        case .scheme: return 64
        case .contentType: return 150
        case .custom: return 118
        }
    }

    var readsBody: Bool {
        switch self {
        case .request, .response: return true
        case .graphql: return true
        case .custom(let field): return field.source == .requestJSON || field.source == .responseJSON
        default: return false
        }
    }

    @MainActor func sortKey(_ tx: Transaction) -> String {
        switch self {
        case .sequence: return String(tx.seq)
        case .url: return tx.originalURL ?? tx.fullURL
        case .client: return tx.clientName ?? ""
        case .method: return tx.method
        case .status: return String(tx.statusCode)
        case .time: return String(tx.startedAt.timeIntervalSince1970)
        case .duration: return String(format: "%016.4f", tx.duration)
        case .request: return String(max(tx.requestBytes, tx.requestBody.count))
        case .response: return String(max(tx.responseBytes, tx.responseBody.count))
        case .ssl: return tx.isTLSIntercepted ? "1" : "0"
        case .edited: return tx.originalURL == nil ? "0" : "1"
        case .comment: return tx.comment
        case .tools: return tx.ruleMatches.joined()
        case .graphql: return CustomColumnValues.shared.graphqlValue(for: tx)
        case .scheme: return tx.scheme
        case .contentType: return tx.responseHeaders.value(of: "Content-Type") ?? ""
        case .custom(let field): return field.value(for: tx)
        }
    }

    @MainActor func sorted(_ rows: [Transaction], ascending: Bool) -> [Transaction] {
        if self == .sequence { return ascending ? rows : Array(rows.reversed()) }
        switch self {
        case .status, .time, .duration, .request, .response:
            return rows.sorted { precedes($0, $1, ascending: ascending) }
        default: break
        }
        return rows.map { ($0, sortKey($0)) }.sorted { lhs, rhs in
            let order = lhs.1.localizedStandardCompare(rhs.1)
            if order == .orderedSame { return lhs.0.seq < rhs.0.seq }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map { $0.0 }
    }

    @MainActor func precedes(_ lhs: Transaction, _ rhs: Transaction, ascending: Bool) -> Bool {
        func compare<T: Comparable>(_ left: T, _ right: T) -> Bool {
            if left == right { return lhs.seq < rhs.seq }
            return ascending ? left < right : right < left
        }
        switch self {
        case .sequence: return compare(lhs.seq, rhs.seq)
        case .status: return compare(lhs.statusCode, rhs.statusCode)
        case .time: return compare(lhs.startedAt, rhs.startedAt)
        case .duration: return compare(lhs.duration, rhs.duration)
        case .request: return compare(max(lhs.requestBytes, lhs.requestBody.count),
                                      max(rhs.requestBytes, rhs.requestBody.count))
        case .response: return compare(max(lhs.responseBytes, lhs.responseBody.count),
                                       max(rhs.responseBytes, rhs.responseBody.count))
        default:
            let order = sortKey(lhs).localizedStandardCompare(sortKey(rhs))
            if order == .orderedSame { return lhs.seq < rhs.seq }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

@MainActor
struct TrafficListView: View {
    @ObservedObject var store: TrafficStore
    @EnvironmentObject var appState: AppState
    @ObservedObject private var presentationSettings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ui.hiddenTrafficColumns") private var hiddenColumns = ""
    @AppStorage("ui.trafficColumnWidths") private var storedWidths = ""
    @AppStorage(CustomTrafficColumn.defaultsKey) private var customData = Data()
    @State private var sortColumn: TrafficColumn = .sequence
    @State private var ascending = true

    var body: some View {
        VStack(spacing: 0) {
            if appState.showCABanner { caBanner }
            filters
            GeometryReader { geometry in
                let columns = visibleColumns(in: geometry.size.width)
                let display = store.displayedRows(sortedBy: sortColumn, ascending: ascending)
                VStack(spacing: 0) {
                    if store.sortingBodyValues || store.filteringCapturedValues {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(store.filteringCapturedValues ? Strings.Traffic.filteringCapturedValues : Strings.Traffic.sortingBodyValues)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }.padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    TrafficTable(
                        rows: display.rows,
                        revision: display.revision,
                        workspaceID: store.id,
                        columns: columns,
                        selectedIDs: store.selectedIDs,
                        selectedID: store.selectedID,
                        followLatest: store.followLatest,
                        select: store.selectManually,
                        open: openDetails,
                        copyAsCurl: appState.copyRequestsAsCurl,
                        contextMenu: rowContextMenu,
                        copyUsingDefaultFormat: appState.copyRequestsUsingDefaultFormat,
                        sortColumn: sortColumn,
                        ascending: ascending,
                        sort: { sortColumn = $0; ascending = $1 }
                    )
                    .overlay { if display.rows.isEmpty { emptyState } }
                }
            }
        }
        .onAppear { store.sortsByCapturedBody = sortColumn.readsBody }
        .onChange(of: sortColumn) { store.sortsByCapturedBody = $0.readsBody }
        .onChange(of: store.id) { _ in store.sortsByCapturedBody = sortColumn.readsBody }
    }

    private var columnWidths: [String: Double] {
        (try? JSONDecoder().decode([String: Double].self, from: Data(storedWidths.utf8))) ?? [:]
    }

    private func visibleColumns(in width: CGFloat) -> [(TrafficColumn, CGFloat)] {
        let hidden = Set(hiddenColumns.split(separator: "|").map(String.init))
        let saved = columnWidths
        let fields = (try? JSONDecoder().decode([CustomTrafficColumn].self, from: customData)) ?? []
        CustomColumnValues.shared.configure(fields)
        return (TrafficColumn.allCases + fields.map(TrafficColumn.custom))
            .filter { !hidden.contains($0.id) || $0 == .url }
            .map { column in (column, max(minimumWidth(for: column), CGFloat(saved[column.id] ?? Double(column.preferredWidth)))) }
    }

    private func minimumWidth(for column: TrafficColumn) -> CGFloat {
        switch column {
        case .url: return 100
        case .ssl: return 29
        default: return 40
        }
    }

    private var caBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.max").foregroundStyle(.yellow)
            Text(Strings.Traffic.installAndTrustTheProxymirrorCaToInspectHttpsBodies).font(.caption)
            Spacer()
            Button(Strings.Traffic.installCaCertificate) { appState.installCACertificate() }
            Button { appState.dismissCABanner() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.Traffic.dismissCertificateNotice)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12))
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(FilterChip.allCases) { chip in
                        if chip == .json { filterDivider }
                        filterButton(chip.localizedTitle, selected: store.isChipSelected(chip)) {
                            store.toggleChip(chip, additive: NSEvent.modifierFlags.contains(.command))
                        }
                    }
                    filterDivider
                    protocolFilter("h1", versions: ["HTTP/1.0", "HTTP/1.1"])
                    protocolFilter("h2", versions: ["HTTP/2"])
                    filterDivider
                    ForEach([("2xx", "success"), ("3xx", "redirect"), ("4xx", "clientError"), ("5xx", "serverError")], id: \.1) { title, bucket in
                        filterButton(title, selected: store.filter.statusBuckets.contains(bucket)) {
                            if store.filter.statusBuckets.contains(bucket) { store.filter.statusBuckets.remove(bucket) }
                            else { store.filter.statusBuckets.insert(bucket) }
                        }
                    }
                }
                .padding(.leading, 11)
                .frame(height: 27)
            }
            Menu(Strings.Traffic.columns) {
                ForEach(TrafficColumn.allCases.filter { $0 != .url }) { column in
                    Toggle(column.localizedTitle(), isOn: Binding(get: {
                        !hiddenColumns.split(separator: "|").contains(Substring(column.id))
                    }, set: { visible in
                        var hidden = Set(hiddenColumns.split(separator: "|").map(String.init))
                        if visible { hidden.remove(column.id) } else { hidden.insert(column.id) }
                        hiddenColumns = hidden.sorted().joined(separator: "|")
                    }))
                }
                Button(Strings.Traffic.customTrafficColumns) { appState.showColumnEditor = true }
                Button(Strings.Traffic.resetColumnWidths) { storedWidths = ""; hiddenColumns = ""; UserDefaults.standard.removeObject(forKey: "ui.trafficColumnOrder") }
            }.menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button(Strings.Traffic.searchCurrentRequests) {
                    NotificationCenter.default.post(name: .focusTrafficFilter, object: nil)
                }
                Button(Strings.Traffic.advancedFilters) { NotificationCenter.default.post(name: .toggleAdvancedTrafficFilter, object: nil) }
                Menu(Strings.Traffic.status) {
                    ForEach([("2xx", "success"), ("3xx", "redirect"), ("4xx", "clientError"), ("5xx", "serverError"),
                             (Strings.Traffic.transportFailed, "error"), (Strings.Traffic.inProgress, "pending")], id: \.1) { label, value in
                        Toggle(label, isOn: Binding(get: { store.filter.statusBuckets.contains(value) }, set: { enabled in
                            if enabled { store.filter.statusBuckets.insert(value) } else { store.filter.statusBuckets.remove(value) }
                        }))
                    }
                }
                Menu(Strings.Traffic.protocol) {
                    ForEach(["HTTP/1.0", "HTTP/1.1", "HTTP/2"], id: \.self) { version in
                        Toggle(version, isOn: Binding(get: { store.filter.versions.contains(version) }, set: { selected in
                            if selected { store.filter.versions.insert(version) } else { store.filter.versions.remove(version) }
                        }))
                    }
                }
                Button(Strings.Traffic.clearFilters) { store.resetFilters() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(store.filter.statusBuckets.isEmpty ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 14)
            .accessibilityLabel(Strings.Traffic.filterOptions)
        }
        .frame(height: 28)
        .background(ProxymanTheme.toolbarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(ProxymanTheme.paneDivider).frame(height: 1) }
    }

    private var filterDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.32)).frame(width: 1, height: 14).padding(.horizontal, 4)
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(selected ? ProxymanTheme.controlBackground : .clear, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func protocolFilter(_ title: String, versions: Set<String>) -> some View {
        let selected = versions.isSubset(of: store.filter.versions)
        return filterButton(title, selected: selected) {
            if selected {
                store.filter.versions.subtract(versions)
            } else if NSEvent.modifierFlags.contains(.command) {
                store.filter.versions.formUnion(versions)
            } else {
                store.filter.versions = versions
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 26))
            if store.hasLiveTransactions {
                Text(Strings.Traffic.noRequestsMatchTheCurrentFilters)
                Button(Strings.Traffic.clearFilters) { store.resetFilters() }
            } else {
                Text(appState.proxyRunning ? Strings.Traffic.waitingForTraffic(ProxyEngine.shared.listenAddress)
                     : Strings.Traffic.startListeningToCaptureRequests)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openDetails(_ id: Transaction.ID) {
        openWindow(id: "request-detail", value: "\(store.id.uuidString):\(id.uuidString)")
    }

    private func rowContextMenu(_ tx: Transaction, _ targets: [Transaction]) -> NSMenu {
        let menu = NSMenu()
        let canReplay = targets.contains(where: \.canReplay)
        menu.addAction(Strings.Traffic.messageRepeat, enabled: canReplay) { targets.forEach { appState.repeatRequest($0) } }
        menu.addAction(Strings.Traffic.repeatDirectly, enabled: canReplay) { targets.forEach { appState.repeatRequest($0, direct: true) } }
        menu.addAction(Strings.Traffic.editRepeat, enabled: tx.canReplay) { appState.openTool(.compose, transaction: tx) }
        menu.addAction(Strings.Traffic.openDetailWindow) { openDetails(tx.id) }
        menu.addSubmenu(Strings.Traffic.createRuleFromRequest) { submenu in
            submenu.addAction(Strings.Traffic.scriptRule) {
                ScriptingActivity.shared.prefill(tx)
                openWindow(id: "scripting")
            }
            for tool in [ToolKind.mapLocal, .mapRemote, .blockList, .allowList, .sslProxyingList] {
                submenu.addAction(tool.localizedTitle) { appState.openTool(tool, transaction: tx) }
            }
        }
        menu.addAction(Strings.Traffic.enableSslProxyingForThisDomain) { appState.enableSSLProxying(for: tx) }
        if tx.clientBundle != nil, tx.isTunnel || tx.scheme.lowercased() == "https" {
            menu.addAction(Strings.Traffic.configureSslForSourceApplication) { appState.openTool(.sslApplications, transaction: tx) }
        }
        menu.addItem(.separator())
        menu.addSubmenu(Strings.Traffic.export) { submenu in
            submenu.addAction("HAR") { ExportService.exportHAR(targets) }
            submenu.addAction("CSV") { ExportService.exportCSV(targets) }
            submenu.addAction(Strings.Export.asOpenapi) { ExportService.exportOpenAPI(targets) }
            submenu.addAction(Strings.Export.asPostman) { ExportService.exportPostman(targets) }
        }
        SavedRequestMenu.add(to: menu, store: store, transactions: targets, reportError: { appState.systemProxyMessage = $0 })
        menu.addAction(Strings.Traffic.addComment) { appState.openComment(targets) }
        menu.addAction(appState.diffPool.contains(where: { $0 === tx }) ? Strings.Traffic.removeFromComparisonPool : Strings.Traffic.addToComparisonPool) {
            appState.toggleDiffCandidate(tx)
        }
        menu.addSubmenu(Strings.Traffic.highlight) { submenu in
            for (index, name) in ProxymanTheme.highlightNames.enumerated() {
                submenu.addAction(ProxymanTheme.localizedHighlightName(name)) {
                    for tx in targets { tx.highlightName = name }
                    store.update(targets)
                }
                if index < 6 {
                    submenu.items.last?.keyEquivalent = String(index + 1)
                    submenu.items.last?.keyEquivalentModifierMask = [.command]
                }
            }
            submenu.addAction(Strings.Traffic.reset) {
                for tx in targets { tx.highlightName = nil }
                store.update(targets)
            }
        }
        menu.addAction(Strings.Menus.strikethrough) {
            let value = !targets.allSatisfy(\.strikethrough)
            targets.forEach { $0.strikethrough = value }
            store.update(targets)
        }
        menu.addAction(Strings.Traffic.copyUrl) { appState.copyText(targets.map(\.fullURL).joined(separator: "\n")) }
        menu.addAction(Strings.Traffic.copy(presentationSettings.defaultCopyFormat.title)) { appState.copyRequestsUsingDefaultFormat(targets) }
        menu.addAction(Strings.Traffic.copyAsCurl) { appState.copyRequestsAsCurl(targets) }
        menu.addSubmenu(targets.count > 1 ? Strings.Traffic.copyThisRequestAsCode : Strings.Traffic.copyAsCode, enabled: tx.canReplay) { submenu in
            for format in RequestCode.Format.allCases {
                submenu.addAction(format.title, enabled: RequestCode.supported(format, for: tx)) {
                    appState.copyText(RequestCode.generate(tx, format: format, runtime: appState.runtimeContext))
                }
            }
        }
        menu.addItem(.separator())
        menu.addAction(Strings.Traffic.delete) { store.remove(Set(targets.map(\.id))) }
        return menu
    }
}
