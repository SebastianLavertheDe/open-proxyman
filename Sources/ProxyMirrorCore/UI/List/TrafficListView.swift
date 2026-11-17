import AppKit
import SwiftUI

enum TrafficColumn: Hashable, Identifiable {
    case sequence, url, client, method, status, time, duration, request, response, ssl, edited, comment, tools
    case custom(CustomTrafficColumn)

    static let allCases: [Self] = [.sequence, .url, .client, .method, .status, .time, .duration, .request, .response, .ssl, .edited, .comment, .tools]

    var id: String {
        if case .custom(let field) = self { return field.id.uuidString }
        return title
    }

    var title: String {
        switch self {
        case .sequence: return "#"
        case .url: return "网址"
        case .client: return "客户端"
        case .method: return "方法"
        case .status: return "状态"
        case .time: return "时间"
        case .duration: return "持续时间"
        case .request: return "请求"
        case .response: return "响应"
        case .ssl: return "SSL"
        case .edited: return "已编辑"
        case .comment: return "备注"
        case .tools: return "工具"
        case .custom(let field): return field.title
        }
    }

    var preferredWidth: CGFloat {
        switch self {
        case .sequence: return 42
        case .url: return 506
        case .client: return 143
        case .method: return 70
        case .status: return 78
        case .time: return 93
        case .duration: return 72
        case .request, .response: return 73
        case .ssl: return 31
        case .edited: return 47
        case .comment: return 269
        case .tools: return 107
        case .custom: return 118
        }
    }

    var readsBody: Bool {
        switch self {
        case .request, .response: return true
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
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ui.hiddenTrafficColumns") private var hiddenColumns = ""
    @AppStorage("ui.trafficColumnWidths") private var storedWidths = ""
    @AppStorage(CustomTrafficColumn.defaultsKey) private var customData = Data()
    @State private var resizing: (column: TrafficColumn, original: CGFloat)?
    @State private var sortColumn: TrafficColumn = .sequence
    @State private var ascending = true
    @State private var showFilterEditor = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.showCABanner { caBanner }
            filters
            GeometryReader { geometry in
                let columns = visibleColumns(in: geometry.size.width)
                let display = store.displayedRows(sortedBy: sortColumn, ascending: ascending)
                VStack(spacing: 0) {
                    header(columns)
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
                        contextMenu: rowContextMenu
                    )
                    .overlay { if display.rows.isEmpty { emptyState } }
                }
            }
        }
        .sheet(isPresented: $showFilterEditor) { TrafficFilterEditor(store: store) }
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
        let custom = fields.map(TrafficColumn.custom)
        var columns = (TrafficColumn.allCases + custom).filter { !hidden.contains($0.id) || $0 == .url }
        let priorities: [TrafficColumn] = [.tools, .comment, .edited, .ssl, .time, .request, .response, .duration, .client]
            + Array(custom.reversed())
        let minimumURL = width < 400 ? 100 : minimumWidth(for: .url)
        func size(_ column: TrafficColumn) -> CGFloat {
            if column == .url { return minimumURL }
            return min(max(saved[column.id] ?? column.preferredWidth, minimumWidth(for: column)), 640)
        }
        let available = max(0, width - 38)
        var occupied = columns.reduce(CGFloat.zero) { $0 + size($1) }
        for column in priorities where occupied > available && columns.contains(column) {
            columns.removeAll { $0 == column }
            occupied -= size(column)
        }
        let urlWidth = min(saved[TrafficColumn.url.id] ?? TrafficColumn.url.preferredWidth,
                           minimumURL + available - occupied)
        return columns.map { ($0, $0 == .url ? max(72, urlWidth) : size($0)) }
    }

    private func minimumWidth(for column: TrafficColumn) -> CGFloat {
        switch column {
        case .url: return 175
        case .ssl: return 29
        default: return 40
        }
    }

    private func header(_ columns: [(TrafficColumn, CGFloat)]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 22, height: 26)
            ForEach(columns, id: \.0) { column, width in
                Button {
                    if sortColumn == column { ascending.toggle() } else { sortColumn = column; ascending = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(column.title).lineLimit(1)
                        if sortColumn == column {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: width, height: 26)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.20))
                        .frame(width: 1, height: 15)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { event in
                                if resizing?.column != column { resizing = (column, width) }
                                var sizes = columnWidths
                                let proposed = (resizing?.original ?? width) + event.translation.width
                                sizes[column.id] = min(max(proposed, minimumWidth(for: column)), 640)
                                if let data = try? JSONEncoder().encode(sizes) {
                                    storedWidths = String(decoding: data, as: UTF8.self)
                                }
                            }
                            .onEnded { _ in resizing = nil })
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .font(.system(size: 11, weight: .semibold))
        .frame(height: 27)
        .background(ProxymanTheme.headerBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
        .contextMenu {
            ForEach(TrafficColumn.allCases.filter { $0 != .url }) { column in
                Toggle(column.title, isOn: Binding(get: {
                    !hiddenColumns.split(separator: "|").contains(Substring(column.id))
                }, set: { visible in
                    var hidden = Set(hiddenColumns.split(separator: "|").map(String.init))
                    if visible { hidden.remove(column.id) } else { hidden.insert(column.id) }
                    hiddenColumns = hidden.sorted().joined(separator: "|")
                }))
            }
            Button("自定义流量列…") { appState.showColumnEditor = true }
            Button("恢复默认列宽") { storedWidths = ""; hiddenColumns = "" }
        }
    }

    private var caBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.max").foregroundStyle(.yellow)
            Text("安装并信任 ProxyMirror CA 后可以查看 HTTPS 正文。").font(.caption)
            Spacer()
            Button("安装 CA 证书") { appState.installCACertificate() }
            Button { appState.dismissCABanner() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭证书提示")
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
                        filterButton(chip.rawValue, selected: store.isChipSelected(chip)) {
                            store.toggleChip(chip, additive: NSEvent.modifierFlags.contains(.command))
                        }
                    }
                    filterDivider
                    protocolFilter("h1", versions: ["HTTP/1.0", "HTTP/1.1"])
                    protocolFilter("h2", versions: ["HTTP/2"])
                }
                .padding(.leading, 11)
                .frame(height: 27)
            }
            Menu {
                Button("搜索当前请求…") {
                    NotificationCenter.default.post(name: .focusTrafficFilter, object: nil)
                }
                Button("高级过滤…") { showFilterEditor = true }
                Menu("状态") {
                    ForEach([("2xx", "success"), ("3xx", "redirect"), ("4xx", "clientError"), ("5xx", "serverError"),
                             ("传输失败", "error"), ("进行中", "pending")], id: \.1) { label, value in
                        Toggle(label, isOn: Binding(get: { store.filter.statusBuckets.contains(value) }, set: { enabled in
                            if enabled { store.filter.statusBuckets.insert(value) } else { store.filter.statusBuckets.remove(value) }
                        }))
                    }
                }
                Menu("协议") {
                    ForEach(["HTTP/1.0", "HTTP/1.1", "HTTP/2"], id: \.self) { version in
                        Toggle(version, isOn: Binding(get: { store.filter.versions.contains(version) }, set: { selected in
                            if selected { store.filter.versions.insert(version) } else { store.filter.versions.remove(version) }
                        }))
                    }
                }
                Button("清除筛选") { store.resetFilters() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(store.filter.statusBuckets.isEmpty ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 14)
            .accessibilityLabel("筛选选项")
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
                Text("没有符合当前筛选条件的请求")
                Button("清除筛选") { store.resetFilters() }
            } else {
                Text(appState.proxyRunning ? "等待流量 · \(ProxyEngine.shared.listenAddress)" : "启动监听后可抓取请求")
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
        menu.addAction("重发", enabled: canReplay) { targets.forEach { appState.repeatRequest($0) } }
        menu.addAction("直连重发", enabled: canReplay) { targets.forEach { appState.repeatRequest($0, direct: true) } }
        menu.addAction("编辑并重发…", enabled: tx.canReplay) { appState.openTool(.compose, transaction: tx) }
        menu.addAction("打开详情窗口") { openDetails(tx.id) }
        menu.addSubmenu("从请求创建规则") { submenu in
            submenu.addAction("脚本规则…") {
                ScriptingActivity.shared.prefill(tx)
                openWindow(id: "scripting")
            }
            for tool in [ToolKind.mapLocal, .mapRemote, .blockList, .allowList, .sslProxyingList] {
                submenu.addAction(tool.rawValue) { appState.openTool(tool, transaction: tx) }
            }
        }
        menu.addAction("为此域启用 SSL 代理") { appState.enableSSLProxying(for: tx) }
        if tx.clientBundle != nil, tx.isTunnel || tx.scheme.lowercased() == "https" {
            menu.addAction("为来源应用配置 SSL…") { appState.openTool(.sslApplications, transaction: tx) }
        }
        menu.addItem(.separator())
        menu.addSubmenu("导出") { submenu in
            submenu.addAction("HAR") { ExportService.exportHAR(targets) }
            submenu.addAction("CSV") { ExportService.exportCSV(targets) }
        }
        menu.addAction("添加备注…") { appState.openComment(targets) }
        menu.addAction(appState.diffPool.contains(where: { $0 === tx }) ? "从对比池移除" : "加入对比池") {
            appState.toggleDiffCandidate(tx)
        }
        menu.addSubmenu("高亮") { submenu in
            for name in ProxymanTheme.highlightNames {
                submenu.addAction(name) {
                    for tx in targets { tx.highlightName = name }
                    store.update(targets)
                }
            }
            submenu.addAction("重置") {
                for tx in targets { tx.highlightName = nil }
                store.update(targets)
            }
        }
        menu.addAction("复制 URL") { CopyPaste.copy(targets.map(\.fullURL).joined(separator: "\n")) }
        menu.addAction("复制为 cURL") { CopyPaste.copy(targets.map(ExportService.curlCommand).joined(separator: "\n")) }
        menu.addSubmenu(targets.count > 1 ? "复制此请求为代码" : "复制为代码", enabled: tx.canReplay) { submenu in
            submenu.addAction("Python requests") { CopyPaste.copy(RequestCode.pythonRequests(tx)) }
            submenu.addAction("JavaScript fetch", enabled: RequestCode.supportsFetch(tx)) {
                CopyPaste.copy(RequestCode.javascriptFetch(tx))
            }
        }
        menu.addItem(.separator())
        menu.addAction("删除") { store.remove(Set(targets.map(\.id))) }
        return menu
    }
}

@MainActor
struct TrafficRow: View {
    @ObservedObject var tx: Transaction
    let columns: [(TrafficColumn, CGFloat)]

    var isSelected = false

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color(nsColor: tx.statusColor))
                .frame(width: 9, height: 9)
                .frame(width: 22)
                .accessibilityHidden(true)
            ForEach(columns, id: \.0) { column, width in
                cell(column)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(width: width, alignment: .leading)
                    .clipped()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: ProxymanTheme.rowHeight)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.87))
        .contentShape(Rectangle())
        .background(tx.highlightName.map { ProxymanTheme.highlightColor($0).opacity(0.28) } ?? .clear)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func cell(_ column: TrafficColumn) -> some View {
        switch column {
        case .sequence:
            Text("\(tx.seq)").frame(maxWidth: .infinity, alignment: .trailing)
        case .url:
            HStack(spacing: 5) {
                Text(tx.originalURL ?? tx.fullURL).truncationMode(.middle).strikethrough(tx.strikethrough)
                    .help(tx.originalURL ?? tx.fullURL)
                if tx.suspectedPinning {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(isSelected ? Color.white : Color.orange)
                        .accessibilityLabel("疑似 SSL 证书锁定")
                        .help("客户端拒绝了代理证书")
                }
                if tx.isGRPCWeb {
                    badge("gRPC-Web", color: .accentColor).fixedSize()
                }
            }
        case .client:
            HStack(spacing: 6) {
                ClientIconView(image: tx.clientIcon)
                Text(tx.clientName ?? "未知").foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
        case .method:
            badge(tx.method, color: tx.method == "CONNECT" ? .secondary : Color(nsColor: tx.methodColor))
        case .status:
            badge(tx.state == .failed ? (tx.statusCode > 0 ? "\(tx.statusCode) · 失败" : "失败")
                  : tx.statusCode == 0 ? "进行中" : String(tx.statusCode),
                  color: Color(nsColor: tx.statusColor))
                .help(tx.errorText ?? tx.statusText)
        case .time: Text(tx.timeText).font(.system(size: 10.5, design: .monospaced))
        case .duration: Text(tx.state == .pending || tx.state == .awaiting ? "–" : tx.durationText)
        case .request: Text(size(max(tx.requestBytes, tx.requestBody.count)))
        case .response: Text(size(max(tx.responseBytes, tx.responseBody.count)))
        case .ssl:
            if tx.isTLSIntercepted {
                Image(systemName: "lock.open").accessibilityLabel("已解密")
            }
        case .edited:
            if tx.originalURL != nil {
                Image(systemName: "pencil").accessibilityLabel("已编辑")
            }
        case .comment: Text(tx.comment).help(tx.comment)
        case .tools: Text(tx.ruleMatches.joined(separator: ", ")).help(tx.ruleMatches.joined(separator: ", "))
        case .custom(let field):
            let value = field.value(for: tx)
            Text(value.isEmpty ? "–" : value).help(value)
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(isSelected ? Color.white : color)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(isSelected ? Color.black.opacity(0.26) : color.opacity(0.19),
                        in: RoundedRectangle(cornerRadius: 4))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func size(_ bytes: Int) -> String {
        bytes == 0 ? "–" : Self.byteFormatter.string(fromByteCount: Int64(bytes))
    }
}
