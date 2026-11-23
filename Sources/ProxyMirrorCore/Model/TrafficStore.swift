import Foundation
import AppKit
import Combine
import NIOCore

// MARK: - 过滤器（对齐 Proxyman 语义：某类条件为空 = 不限制）

struct TrafficFilter: Equatable {
    var searchText: String = "" {
        didSet { searchNeedle = searchText.lowercased() }
    }
    private var searchNeedle = ""
    var schemes: Set<String> = []          // http / https / Tunnel
    var versions: Set<String> = []
    var methods: Set<String> = []          // GET POST PUT DELETE PATCH ...
    var statusBuckets: Set<String> = []    // success redirect clientError serverError error pending
    var bodyKinds: Set<BodyKind> = []      // JSON HTML Image ...
    var domains: Set<String> = []
    var showTunnels = true                 // 未解密隧道显示
    var conditions = TrafficConditionGroup()

    func matches(_ tx: Transaction) -> Bool {
        if !domains.isEmpty && !domains.contains(tx.host) { return false }
        if !schemes.isEmpty && !schemes.contains(tx.scheme) { return false }
        if !versions.isEmpty && !versions.contains(tx.requestVersion) { return false }
        if !methods.isEmpty && !methods.contains(tx.method) { return false }
        if !showTunnels && tx.isTunnel && !tx.isTLSIntercepted { return false }
        if !bodyKinds.isEmpty && !bodyKinds.contains(tx.bodyKind) { return false }

        if !statusBuckets.isEmpty {
            let bucket = statusBucket(of: tx)
            if !statusBuckets.contains(bucket) { return false }
        }

        if !searchText.isEmpty {
            let hay = "\(tx.host) \(tx.path) \(tx.query) \(tx.method) \(tx.statusCode)".lowercased()
            if !hay.contains(searchNeedle) { return false }
        }
        return true
    }

    private func statusBucket(of tx: Transaction) -> String {
        switch tx.state {
        case .failed: return "error"
        case .pending, .awaiting: return "pending"
        case .completed:
            switch tx.statusCode {
            case 200...299: return "success"
            case 300...399: return "redirect"
            case 400...499: return "clientError"
            case 500...599: return "serverError"
            default: return "pending"
            }
        }
    }

    var isEmptyActive: Bool {
        showTunnels && searchText.isEmpty && schemes.isEmpty && versions.isEmpty && methods.isEmpty && statusBuckets.isEmpty && bodyKinds.isEmpty && domains.isEmpty
    }
}

/// 侧栏过滤模式
enum TrafficFilterMode: Equatable {
    case all
    case pinned
    case saved
    case archive
    case client(String)
    case clientDomain(client: String, host: String)
    case domain(String)
    case folder(UUID)
}

/// 侧栏域名汇总条目
struct DomainSummary: Identifiable {
    let host: String
    let count: Int
    var id: String { host }
}

// MARK: - 流量仓库

@MainActor
final class TrafficStore: ObservableObject {
    let id = UUID()
    private let data: TrafficData
    private var mutations: AnyCancellable?
    private var preferenceChanges: AnyCancellable?
    private var hideAppleTraffic = UserDefaults.standard.bool(forKey: "ui.hideAppleTraffic")
    // Cache Combine's synthesized publisher so manual notifications don't repeat
    // field discovery. This also keeps @Published properties on the same publisher.
    private lazy var changePublisher = objectWillChange
    private var workspaceVisible = true
    private var receivedWhileHidden = false
    private var visibleRows: [Transaction]? {
        didSet { sortedRows = nil }
    }
    private var visiblePins: [String]?
    private var sortedRows: (column: TrafficColumn, ascending: Bool, rows: [Transaction])?
    private var sortRevision: UInt64 = 0
    var sortsByCapturedBody = false
    private var pendingBodies: Set<UUID> = []
    var transactions: [Transaction] { data.transactions }
    var hasLiveTransactions: Bool { !data.live.isEmpty }
    var transferredBytes: (request: Int64, response: Int64) { data.transferredBytes }
    var saved: [Transaction] { data.saved }
    var sourceFolders: [SourceFolder] { data.sourceFolders }
    @Published private(set) var archive: [Transaction] = [] {
        didSet {
            archiveByID = Dictionary(archive.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            visibleRows = nil
        }
    }
    private var archiveByID: [UUID: Transaction] = [:]
    @Published var archiveName: String?
    var savedError: String? { data.savedError }
    private var savedPins: [String] = []
    private var matchesConditions: (Transaction) -> Bool = { _ in true }
    @Published var filter = TrafficFilter() {
        didSet {
            if oldValue.conditions != filter.conditions { matchesConditions = filter.conditions.compile() }
            visibilityChanged()
        }
    }
    /// 详情面板展示对象（最后点击的行；取消选择时保留详情）
    private var selectionHistory: [UUID] = []
    private var historyPosition = -1
    private var navigatingHistory = false
    @Published var selectedID: Transaction.ID? {
        didSet {
            guard !navigatingHistory, oldValue != selectedID, let selectedID else { return }
            if historyPosition + 1 < selectionHistory.count {
                selectionHistory.removeSubrange((historyPosition + 1)...)
            }
            selectionHistory.append(selectedID)
            if selectionHistory.count > 200 { selectionHistory.removeFirst() }
            historyPosition = selectionHistory.count - 1
        }
    }

    var canNavigateBackward: Bool { historyTarget(direction: -1) != nil }
    var canNavigateForward: Bool { historyTarget(direction: 1) != nil }

    func navigateSelectionHistory(_ direction: Int) {
        guard let index = historyTarget(direction: direction) else { return }
        navigatingHistory = true
        defer { navigatingHistory = false }
        followLatest = false
        historyPosition = index
        selectedIDs = [selectionHistory[index]]
        selectedID = selectionHistory[index]
    }

    private func historyTarget(direction: Int) -> Int? {
        guard direction == -1 || direction == 1 else { return nil }
        var index = historyPosition + direction
        while selectionHistory.indices.contains(index) {
            if let transaction = transactionInSource(selectionHistory[index]), isVisible(transaction) { return index }
            index += direction
        }
        return nil
    }
    /// 列表多选（⌘/Shift 点击）；变更时同步 selectedID 供详情面板使用
    @Published var selectedIDs: Set<Transaction.ID> = [] {
        didSet {
            let added = selectedIDs.subtracting(oldValue)
            if added.count == 1 {
                selectedID = added.first
            } else if !added.isEmpty {
                selectedID = lastInSource { added.contains($0.id) }?.id ?? added.first
            } else if let current = selectedID, !selectedIDs.contains(current) {
                selectedID = lastInSource { selectedIDs.contains($0.id) }?.id
            }
        }
    }
    /// 顶部筛选 chips（全部|HTTP|HTTPS|WebSocket|JSON|表单|XML|JS|CSS|GraphQL|文档|媒体|其他）
    @Published var activeChip: FilterChip = .all {
        didSet { visibilityChanged() }
    }
    @Published private var extraChips: Set<FilterChip> = [] {
        didSet { visibilityChanged() }
    }
    /// 侧栏过滤模式：全部 / 已固定 / 按客户端 / 按域名
    @Published var filterMode: TrafficFilterMode = .all {
        didSet { visibilityChanged() }
    }
    @Published var followLatest = false {
        didSet {
            if followLatest, let latest = lastInSource(where: isVisible) { selectedIDs = [latest.id] }
        }
    }

    var maxTransactions: Int {
        get { data.maxTransactions }
        set { data.maxTransactions = newValue }
    }

    init(sharing original: TrafficStore? = nil, sourceFolderFile: URL = SourceFolderArchive.defaultURL,
         savedFile: URL = CertificateAuthority.applicationSupport.appendingPathComponent("Saved.proxymirror")) {
        data = original?.data ?? TrafficData(sourceFolderFile: sourceFolderFile, savedFile: savedFile)
        mutations = data.changed.sink { [weak self] change in self?.refreshSharedData(change) }
        preferenceChanges = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                let hidden = UserDefaults.standard.bool(forKey: "ui.hideAppleTraffic")
                guard hidden != self.hideAppleTraffic else { return }
                self.hideAppleTraffic = hidden
                self.visibilityChanged()
                self.changePublisher.send()
            }
    }

    func setWorkspaceVisible(_ visible: Bool) {
        guard workspaceVisible != visible else { return }
        workspaceVisible = visible
        visibleRows = nil
        if visible {
            refreshSharedData()
            if receivedWhileHidden, followLatest, filterMode != .saved, filterMode != .archive,
               let latest = lastInSource(where: isVisible) {
                selectedIDs = [latest.id]
            }
            receivedWhileHidden = false
        }
    }

    func noteBodyCaptureUpdate(_ tx: Transaction) {
        guard workspaceVisible, filterMode != .saved, filterMode != .archive,
              data.transaction(id: tx.id) === tx,
              sortsByCapturedBody || filter.conditions.readsBody else { return }
        let schedule = pendingBodies.isEmpty
        pendingBodies.insert(tx.id)
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self else { return }
            let ids = self.pendingBodies
            self.pendingBodies.removeAll(keepingCapacity: true)
            self.refreshSharedData(.live(ids: ids, captures: [], reset: false))
        }
    }

    private func refreshSharedData(_ change: TrafficData.Change? = nil) {
        switch change {
        case .appended(let transaction, let evicted):
            if filterMode != .saved && filterMode != .archive {
                guard workspaceVisible else {
                    visibleRows = nil
                    receivedWhileHidden = true
                    return
                }
                if visibleRows != nil {
                    var ids: Set<UUID> = []
                    if let transaction { ids.insert(transaction.id) }
                    if let evicted { ids.insert(evicted) }
                    refreshLiveRows(ids)
                }
                if followLatest, let transaction, isVisible(transaction) {
                    if selectedIDs != [transaction.id] { selectedIDs = [transaction.id] }
                } else {
                    reconcileSelection()
                }
            }
            if workspaceVisible { changePublisher.send() }
            return
        case .live(let ids, let captures, let reset):
            if filterMode != .saved && filterMode != .archive {
                if !workspaceVisible {
                    if reset || !ids.isEmpty { visibleRows = nil }
                    if !captures.isEmpty { receivedWhileHidden = true }
                    return
                }
                if reset { visibleRows = nil }
                else { refreshLiveRows(ids) }
                if followLatest, let latest = captures.reversed().lazy
                    .compactMap({ self.data.transaction(id: $0) }).first(where: isVisible) {
                    if selectedIDs != [latest.id] { selectedIDs = [latest.id] }
                } else if !ids.isEmpty || reset {
                    reconcileSelection()
                }
            }
            // A workspace browsing Saved or an archive still shows live sidebar and byte totals.
            if workspaceVisible { changePublisher.send() }
            return
        case .saved:
            if filterMode == .saved { visibleRows = nil; reconcileSelection() }
            if workspaceVisible { changePublisher.send() }
            return
        case .folders:
            if case .folder = filterMode { visibleRows = nil }
        case nil:
            visibleRows = nil
        }
        guard workspaceVisible else { return }
        if case .folder(let id) = filterMode, data.foldersByID[id] == nil {
            filterMode = .all
        } else {
            reconcileSelection()
        }
        changePublisher.send()
    }

    private func refreshLiveRows(_ ids: Set<UUID>) {
        guard !ids.isEmpty, let previous = visibleRows else { return }
        let additions = ids.compactMap { data.transaction(id: $0) }.filter(isVisible).sorted { $0.seq < $1.seq }
        let priorSort = sortedRows
        let retained = previous.filter { !ids.contains($0.id) }
        guard retained.count != previous.count || !additions.isEmpty else { return }
        visibleRows = merging(retained, additions) { $0.seq < $1.seq }
        // Body changes can be pending in the longer refresh window, so the retained keys
        // may already differ from the values used to sort them.
        if let priorSort, !priorSort.column.readsBody && priorSort.column != .tools {
            let remaining = priorSort.rows.filter { !ids.contains($0.id) }
            let column = priorSort.column
            let ordered = merging(remaining, column.sorted(additions, ascending: priorSort.ascending)) {
                column.precedes($0, $1, ascending: priorSort.ascending)
            }
            sortedRows = (column, priorSort.ascending, ordered)
            sortRevision &+= 1
        }
    }

    private func merging(_ existing: [Transaction], _ incoming: [Transaction],
                         precedes: (Transaction, Transaction) -> Bool) -> [Transaction] {
        guard !incoming.isEmpty else { return existing }
        var result: [Transaction] = []
        result.reserveCapacity(existing.count + incoming.count)
        var start = 0
        for transaction in incoming {
            var lower = start
            var upper = existing.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if precedes(existing[middle], transaction) { lower = middle + 1 }
                else { upper = middle }
            }
            result.append(contentsOf: existing[start..<lower])
            result.append(transaction)
            start = lower
        }
        result.append(contentsOf: existing[start...])
        return result
    }

    private func visibilityChanged() {
        visibleRows = nil
        reconcileSelection()
    }

    private var source: [Transaction] {
        switch filterMode {
        case .saved: return saved
        case .archive: return archive
        default: return transactions
        }
    }

    private func lastInSource(where predicate: (Transaction) -> Bool) -> Transaction? {
        switch filterMode {
        case .saved: return saved.last(where: predicate)
        case .archive: return archive.last(where: predicate)
        default: return data.live.last(where: predicate)
        }
    }

    /// UI 展示（已过滤）列表
    var visible: [Transaction] {
        let pins = filterMode == .pinned ? AppState.shared.pinnedDomains : nil
        if let visibleRows, visiblePins == pins { return visibleRows }
        let rows: [Transaction]
        switch filterMode {
        case .saved: rows = saved.filter(isVisible)
        case .archive: rows = archive.filter(isVisible)
        default: rows = data.live.filter(isVisible)
        }
        visiblePins = pins
        visibleRows = rows
        return rows
    }

    func displayedRows(sortedBy column: TrafficColumn, ascending: Bool) -> (rows: [Transaction], revision: UInt64) {
        let rows = visible
        if let sortedRows, sortedRows.column == column, sortedRows.ascending == ascending {
            return (sortedRows.rows, sortRevision)
        }
        let ordered = column.sorted(rows, ascending: ascending)
        sortedRows = (column, ascending, ordered)
        sortRevision &+= 1
        return (ordered, sortRevision)
    }

    private func isVisible(_ tx: Transaction) -> Bool {
        if hideAppleTraffic {
            let host = tx.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let appleDomains = ["apple.com", "icloud.com", "icloud-content.com", "mzstatic.com", "aaplimg.com", "apple-dns.net"]
            if appleDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        }
        guard !tx.hideFromList,
              extraChips.isEmpty ? tx.matches(chip: activeChip) : extraChips.contains(where: { tx.matches(chip: $0) })
        else { return false }
        switch filterMode {
        case .all, .saved, .archive: break
        case .pinned:
            guard AppState.shared.pinnedDomains.contains(tx.host) else { return false }
        case .client(let name):
            guard tx.clientName == name else { return false }
        case .clientDomain(let client, let host):
            guard tx.clientName == client, tx.host == host else { return false }
        case .domain(let host):
            guard tx.host == host else { return false }
        case .folder(let id):
            guard data.foldersByID[id]?.matches(tx) == true else { return false }
        }
        return (filter.isEmptyActive || filter.matches(tx)) && matchesConditions(tx)
    }

    func isChipSelected(_ chip: FilterChip) -> Bool {
        extraChips.isEmpty ? chip == activeChip : extraChips.contains(chip)
    }

    func toggleChip(_ chip: FilterChip, additive: Bool) {
        if !additive || chip == .all {
            extraChips = []
            activeChip = chip
        } else {
            var chips = extraChips
            if chips.isEmpty, activeChip != .all { chips.insert(activeChip) }
            if chips.contains(chip) { chips.remove(chip) } else { chips.insert(chip) }
            activeChip = .all
            extraChips = chips
        }
    }

    func resetFilters() {
        filter = TrafficFilter()
        filterMode = .all
        toggleChip(.all, additive: false)
    }

    @discardableResult
    func saveSourceFolder(id: UUID? = nil, name: String, members: Set<SourceFolderMember>) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SourceFolderError.blankName }
        var updated = sourceFolders
        guard !updated.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw SourceFolderError.duplicateName
        }
        let folder = SourceFolder(id: id ?? UUID(), name: name, members: Set(members.map(\.normalized)))
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { throw SourceFolderError.missing }
            updated[index] = folder
        } else {
            updated.append(folder)
        }
        try data.replaceSourceFolders(updated)
        return folder.id
    }

    func removeSourceFolder(_ id: UUID) throws {
        guard sourceFolders.contains(where: { $0.id == id }) else { return }
        try data.replaceSourceFolders(sourceFolders.filter { $0.id != id })
    }

    func toggleSourceFolderMembership(_ member: SourceFolderMember, folderID: UUID) throws {
        guard let folder = sourceFolders.first(where: { $0.id == folderID }) else { throw SourceFolderError.missing }
        var members = folder.members
        let member = member.normalized
        if !members.insert(member).inserted { members.remove(member) }
        try saveSourceFolder(id: folderID, name: folder.name, members: members)
    }

    var sourceFolderCounts: [UUID: Int] {
        guard !sourceFolders.isEmpty else { return [:] }
        if let cached = data.folderCounts { return cached }
        var membership: [SourceFolderMember: Set<UUID>] = [:]
        for folder in sourceFolders {
            for member in folder.members { membership[member, default: []].insert(folder.id) }
        }
        var counts: [UUID: Int] = [:]
        for tx in data.live where !tx.hideFromList {
            var matched = Set<UUID>()
            for member in SourceFolderMember.captured(tx) {
                if let ids = membership[member] { matched.formUnion(ids) }
            }
            for id in matched { counts[id, default: 0] += 1 }
        }
        data.folderCounts = counts
        return counts
    }

    /// 应用程序按首次出现的顺序展示。
    var clientApps: [(name: String, count: Int, icon: NSImage?)] {
        if let cached = data.clientApps { return cached }
        var groups: [String: (name: String, count: Int, icon: NSImage?)] = [:]
        var encountered: [String] = []
        for tx in data.live {
            guard let name = tx.clientName, !name.isEmpty else { continue }
            if groups[name] == nil { encountered.append(name) }
            var app = groups[name] ?? (name, 0, nil)
            app.count += 1
            if app.icon == nil { app.icon = tx.clientIcon }
            groups[name] = app
        }
        let apps = data.clientOrder.rows(groups, encountered: encountered) { _, app in app }
        data.clientApps = apps
        return apps
    }

    var domainsByClient: [String: [String]] {
        if let cached = data.domainsByClient { return cached }
        var seen: [String: Set<String>] = [:]
        var result: [String: [String]] = [:]
        for tx in data.live {
            guard let client = tx.clientName, !client.isEmpty,
                  seen[client, default: []].insert(tx.host).inserted else { continue }
            result[client, default: []].append(tx.host)
        }
        data.domainsByClient = result
        return result
    }

    /// 列表 # 列序号
    func seqNumber(of tx: Transaction) -> Int {
        tx.seq == 0 ? 1 : tx.seq
    }

    /// 域名按首次出现的顺序展示。
    var domainSummary: [DomainSummary] {
        if let cached = data.domainSummary { return cached }
        if data.rebuildPendingDomainOrder {
            for tx in data.live where data.pendingDomains[tx.host] != nil {
                data.pendingDomains[tx.host] = min(data.pendingDomains[tx.host]!, tx.seq)
            }
            data.rebuildPendingDomainOrder = false
        }
        let encountered = data.pendingDomains.sorted { $0.value < $1.value }.map(\.key)
        let result = data.domainOrder.rows(data.domainCounts, encountered: encountered) { host, count in
            DomainSummary(host: host, count: count)
        }
        data.pendingDomains.removeAll(keepingCapacity: true)
        data.domainSummary = result
        return result
    }

    var selectedTransaction: Transaction? {
        selectedID.flatMap(transactionInSource)
    }

    var selectedTransactions: [Transaction] {
        source.filter { selectedIDs.contains($0.id) }
    }

    func transaction(id: UUID) -> Transaction? {
        transactionInSource(id) ?? archiveByID[id] ?? data.transaction(id: id) ?? data.savedByID[id]
    }

    private func transactionInSource(_ id: UUID) -> Transaction? {
        switch filterMode {
        case .saved: return data.savedByID[id]
        case .archive: return archiveByID[id]
        default: return data.transaction(id: id)
        }
    }

    func selectManually(_ ids: Set<Transaction.ID>) {
        if ids.isEmpty, followLatest, let current = selectedTransaction, isVisible(current) { return }
        guard ids != selectedIDs else { return }
        if followLatest { followLatest = false }
        selectedIDs = ids
    }

    func reconcileSelection() {
        if !selectedIDs.isEmpty || selectedID != nil {
            let remaining = selectedIDs.filter { transactionInSource($0).map(isVisible) == true }
            if remaining != selectedIDs { selectedIDs = remaining }
            if let selectedID, !remaining.contains(selectedID),
               transactionInSource(selectedID).map(isVisible) != true { self.selectedID = nil }
        }
        if followLatest, selectedIDs.isEmpty, let latest = lastInSource(where: isVisible) {
            selectedIDs = [latest.id]
        }
    }

    func add(_ tx: Transaction) {
        data.add(tx)
    }

    func ingestCaptured(_ tx: Transaction) {
        data.add(tx, batch: true)
    }

    func ingestUpdated(_ tx: Transaction) {
        data.updateLive(tx, batch: true)
    }

    func recordBodyBytes(_ tx: Transaction) {
        data.updateLive(tx, batch: true, bytesOnly: true)
    }

    func update(_ tx: Transaction) {
        update([tx])
    }

    func update(_ records: [Transaction]) {
        let changesSaved = records.contains { data.savedByID[$0.id] === $0 }
        if changesSaved {
            data.persistSaved()
            data.changed.send(.saved)
        }
        for record in records { data.updateLive(record, batch: true) }
        data.publishLive()
        if records.contains(where: { archiveByID[$0.id] === $0 }) {
            refreshSharedData()
        }
    }

    func clear() {
        switch filterMode {
        case .saved:
            data.editSaved { $0.removeAll() }
        case .archive: archive.removeAll()
        default: data.clear()
        }
        selectedIDs.removeAll()
        selectedID = nil
        changePublisher.send()
    }

    func remove(_ ids: Set<Transaction.ID>) {
        switch filterMode {
        case .saved:
            data.editSaved { $0.removeAll { ids.contains($0.id) } }
        case .archive: archive.removeAll { ids.contains($0.id) }
        default: data.remove(ids)
        }
        reconcileSelection()
    }

    func saveSelection() {
        guard filterMode != .saved else { return }
        let records = selectedTransactions
        guard !records.isEmpty else { return }
        let snapshots = records.map { SessionRecord($0).transaction() }
        let ids = Set(snapshots.map(\.id))
        data.editSaved { current in
            current.removeAll { ids.contains($0.id) }
            current.append(contentsOf: snapshots)
        }
    }

    func finishSaving(_ completion: @escaping (Bool) -> Void) -> Bool {
        data.finishSaving(completion)
    }

    func loadArchive(_ records: [Transaction], name: String, pins: [String] = [], selection: [UUID] = []) {
        resetFilters()
        followLatest = false
        archive = records
        archiveName = name
        savedPins = pins
        filterMode = .archive
        let available = Set(records.map(\.id))
        selectedIDs = Set(selection).intersection(available)
        if selectedIDs.isEmpty, let first = records.first { selectedIDs = [first.id] }
    }

    func session(onlySelection: Bool, pinned: [String]) -> SessionFile {
        let active = filterMode == .saved || filterMode == .archive ? source : transactions
        return SessionFile(transactions: onlySelection ? selectedTransactions : active,
                           pinnedDomains: filterMode == .archive ? savedPins : pinned, selected: selectedIDs)
    }

    // MARK: - 示例数据（演示用）

    func addSampleData() {
        let samples: [(String, String, String, Int, String, String)] = [
            ("GET", "https", "api.github.com", 200, "application/json", "/repos/apple/swift"),
            ("GET", "https", "images.example.com", 200, "image/png", "/static/logo.png"),
            ("POST", "https", "api.example.com", 201, "application/json", "/v1/users"),
            ("GET", "http", "example.com", 301, "text/html", "/"),
            ("GET", "https", "api.example.com", 404, "application/json", "/v1/missing"),
            ("PUT", "https", "api.example.com", 422, "application/json", "/v1/users/42"),
            ("GET", "https", "cdn.example.com", 500, "text/html", "/error"),
            ("GET", "https", "fonts.example.com", 200, "font/woff2", "/Inter.woff2"),
            ("DELETE", "https", "api.example.com", 204, "", "/v1/users/7"),
            ("GET", "https", "example.com", 200, "text/html", "/index.html"),
        ]
        for (i, s) in samples.enumerated() {
            let tx = Transaction()
            tx.method = s.0
            tx.scheme = s.1
            tx.host = s.2
            tx.port = s.1 == "https" ? 443 : 80
            let (p, q) = splitQueryPath(s.5)
            tx.path = p
            tx.query = q
            tx.statusCode = s.3
            tx.statusReason = Self.reason(for: s.3)
            tx.contentType = s.4
            tx.state = .completed
            tx.responseHeaders = HTTPHeaders([("Content-Type", s.4), ("Server", "sample")])
            tx.requestHeaders = HTTPHeaders([("Host", s.2), ("User-Agent", "ProxyMirror/1.0")])
            tx.duration = 0.04 + Double(i) * 0.03
            tx.responseBody = Data(Self.sampleBody(for: s.4).utf8)
            tx.responseBodyComplete = true
            tx.isTLSIntercepted = s.1 == "https"
            tx.requestBodyComplete = true
            add(tx)
        }
        changePublisher.send()
    }

    nonisolated static func reason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 404: return "Not Found"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        default: return "Status \(code)"
        }
    }

    static func sampleBody(for contentType: String) -> String {
        if contentType.contains("json") {
            return """
            {"ok": true, "data": {"id": 42, "name": "ProxyMirror", "tags": ["proxy", "debug"], "meta": {"version": 1.0, "count": 3}}}
            """
        }
        if contentType.contains("html") {
            return "<!DOCTYPE html>\n<html>\n<head><title>Sample</title></head>\n<body><h1>Hello ProxyMirror</h1></body>\n</html>"
        }
        return "Sample text body."
    }
}

private struct SidebarSourceOrder {
    private var keys: [String] = []

    mutating func rows<Value, Row>(
        _ groups: [String: Value], encountered: [String], makeRow: (String, Value) -> Row
    ) -> [Row] {
        // Preserve surviving groups even when their oldest request is removed or evicted.
        keys.removeAll { groups[$0] == nil }
        let existing = Set(keys)
        keys.append(contentsOf: encountered.filter { !existing.contains($0) })
        return keys.compactMap { key in groups[key].map { makeRow(key, $0) } }
    }
}

@MainActor
private final class TrafficData {
    enum Change {
        case appended(Transaction?, evicted: UUID?)
        case live(ids: Set<UUID>, captures: [UUID], reset: Bool)
        case saved
        case folders
    }

    private struct LiveSummary {
        let request: Int64
        let response: Int64
        let host: String
        let client: String?
        let bundle: String?
        let hidden: Bool

        init(_ tx: Transaction) {
            request = Int64(max(tx.requestBytes, tx.requestBody.count))
            response = Int64(max(tx.responseBytes, tx.responseBody.count))
            host = tx.host
            client = tx.clientName
            bundle = tx.clientBundle
            hidden = tx.hideFromList
        }
    }

    private(set) var live = CircularBuffer<Transaction>()
    var transactions: [Transaction] { Array(live) }
    private struct LiveEntry {
        let transaction: Transaction
        let summary: LiveSummary
    }

    private var liveByID: [UUID: LiveEntry] = [:]
    private(set) var transferredBytes: (request: Int64, response: Int64) = (0, 0)
    private(set) var saved: [Transaction] = []
    private(set) var savedByID: [UUID: Transaction] = [:]
    private(set) var savedError: String?
    private(set) var sourceFolders: [SourceFolder] = []
    private(set) var foldersByID: [UUID: SourceFolder] = [:]
    var folderCounts: [UUID: Int]?
    var clientApps: [(name: String, count: Int, icon: NSImage?)]?
    var domainsByClient: [String: [String]]?
    var domainSummary: [DomainSummary]?
    var clientOrder = SidebarSourceOrder()
    var domainOrder = SidebarSourceOrder()
    private(set) var domainCounts: [String: Int] = [:]
    var pendingDomains: [String: Int] = [:]
    var rebuildPendingDomainOrder = false
    let changed = PassthroughSubject<Change, Never>()
    private var pendingIDs: Set<UUID> = []
    private var pendingCaptures: [UUID] = []
    private var pendingLiveChange = false
    private var livePublicationScheduled = false
    var maxTransactions = 5000
    private var sequence = 0
    private let sourceFolderFile: URL
    private var sourceFolderReadError: Error?
    private let savedFile: URL
    private let savedQueue = DispatchQueue(label: "proxymirror.saved-traffic", qos: .utility)
    private enum SavedState { case loading, ready, unavailable }
    private var savedState = SavedState.loading
    private var queuedEdits: [(inout [Transaction]) -> Void] = []
    private var writingSaved = false
    private var nextWrite: SessionFile?
    private var saveWaiters: [(Bool) -> Void] = []

    init(sourceFolderFile: URL, savedFile: URL) {
        self.sourceFolderFile = sourceFolderFile
        self.savedFile = savedFile
        do { setSourceFolders(try SourceFolderArchive.read(sourceFolderFile)) }
        catch { sourceFolderReadError = error }
        savedQueue.async { [weak self] in
            let result = Result {
                do {
                    return try SessionFile.decode(Data(contentsOf: savedFile)).records
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    return []
                }
            }
            DispatchQueue.main.async { [weak self] in self?.loadedSaved(result) }
        }
    }

    func replaceSourceFolders(_ folders: [SourceFolder]) throws {
        if let sourceFolderReadError { throw sourceFolderReadError }
        try SourceFolderArchive.write(folders, to: sourceFolderFile)
        setSourceFolders(folders)
        changed.send(.folders)
    }

    private func setSourceFolders(_ folders: [SourceFolder]) {
        sourceFolders = folders
        foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        folderCounts = nil
    }

    private func invalidateSidebar() {
        folderCounts = nil
        clientApps = nil
        domainsByClient = nil
        domainSummary = nil
    }

    func transaction(id: UUID) -> Transaction? {
        liveByID[id]?.transaction
    }

    func add(_ tx: Transaction, batch: Bool = false) {
        let limit = max(0, maxTransactions)
        // A synchronous append normally evicts at most one row. Pending capture
        // changes or a reduced capacity still use the shared batch publication.
        let needsBatch = batch || pendingLiveChange || live.count > limit
        sequence += 1
        tx.seq = sequence
        live.append(tx)
        replaceEntry(for: tx)
        invalidateSidebar()

        if needsBatch {
            pendingIDs.insert(tx.id)
            pendingCaptures.append(tx.id)
            while live.count > limit, let evicted = live.popFirst() {
                removeFromIndex(evicted.id)
                pendingIDs.insert(evicted.id)
            }
            liveChanged(batch: batch)
        } else {
            let evicted = live.count > limit ? live.popFirst()?.id : nil
            if let evicted { removeFromIndex(evicted) }
            changed.send(.appended(limit > 0 ? tx : nil, evicted: evicted))
        }
    }

    func updateLive(_ tx: Transaction, batch: Bool, bytesOnly: Bool = false) {
        guard liveByID[tx.id]?.transaction === tx else { return }
        replaceEntry(for: tx)
        if !bytesOnly { pendingIDs.insert(tx.id) }
        liveChanged(batch: batch)
    }

    private func replaceEntry(for tx: Transaction) {
        let summary = LiveSummary(tx)
        let entry = LiveEntry(transaction: tx, summary: summary)
        let old = liveByID.updateValue(entry, forKey: tx.id)?.summary
        transferredBytes.request += summary.request - (old?.request ?? 0)
        transferredBytes.response += summary.response - (old?.response ?? 0)
        if old?.host != summary.host {
            if let old { removeDomain(old.host, sequence: tx.seq) }
            if domainCounts[summary.host] == nil {
                pendingDomains[summary.host] = tx.seq
            } else if let pending = pendingDomains[summary.host] {
                pendingDomains[summary.host] = min(pending, tx.seq)
            }
            domainCounts[summary.host, default: 0] += 1
            domainSummary = nil
        }
        if old?.host != summary.host || old?.client != summary.client { domainsByClient = nil }
        if old?.client != summary.client || old?.bundle != summary.bundle { clientApps = nil }
        if old?.host != summary.host || old?.client != summary.client || old?.hidden != summary.hidden {
            folderCounts = nil
        }
    }

    private func removeDomain(_ host: String, sequence: Int) {
        guard let count = domainCounts[host] else { return }
        if count == 1 {
            domainCounts.removeValue(forKey: host)
            pendingDomains.removeValue(forKey: host)
        } else {
            domainCounts[host] = count - 1
            if pendingDomains[host] == sequence {
                pendingDomains[host] = .max
                rebuildPendingDomainOrder = true
            }
        }
        domainSummary = nil
    }

    private func removeFromIndex(_ id: UUID) {
        guard let evicted = liveByID.removeValue(forKey: id) else { return }
        transferredBytes.request -= evicted.summary.request
        transferredBytes.response -= evicted.summary.response
        removeDomain(evicted.summary.host, sequence: evicted.transaction.seq)
    }

    private func liveChanged(batch: Bool) {
        pendingLiveChange = true
        guard batch else { publishLive(); return }
        guard !livePublicationScheduled else { return }
        livePublicationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
            guard let self else { return }
            self.livePublicationScheduled = false
            self.publishLive()
        }
    }

    func publishLive(reset: Bool = false) {
        guard pendingLiveChange || reset else { return }
        let change = Change.live(ids: pendingIDs, captures: pendingCaptures, reset: reset)
        pendingIDs = []
        pendingCaptures = []
        pendingLiveChange = false
        changed.send(change)
    }

    func remove(_ ids: Set<UUID>) {
        live = CircularBuffer(live.filter { !ids.contains($0.id) })
        for id in ids { removeFromIndex(id) }
        pendingIDs.formUnion(ids)
        invalidateSidebar()
        liveChanged(batch: false)
    }

    func clear() {
        live.removeAll()
        liveByID.removeAll()
        transferredBytes = (0, 0)
        pendingIDs.removeAll()
        pendingCaptures.removeAll()
        clientOrder = SidebarSourceOrder()
        domainOrder = SidebarSourceOrder()
        domainCounts.removeAll()
        pendingDomains.removeAll()
        rebuildPendingDomainOrder = false
        invalidateSidebar()
        publishLive(reset: true)
    }

    func editSaved(_ edit: @escaping (inout [Transaction]) -> Void) {
        switch savedState {
        case .loading:
            queuedEdits.append(edit)
        case .ready:
            edit(&saved)
            reindexSaved()
            persistSaved()
            changed.send(.saved)
        case .unavailable:
            changed.send(.saved)
        }
    }

    private func loadedSaved(_ result: Result<[SessionRecord], Error>) {
        let edits = queuedEdits
        queuedEdits.removeAll()
        switch result {
        case .success(let records):
            saved = records.map { $0.transaction() }
            for edit in edits { edit(&saved) }
            reindexSaved()
            savedState = .ready
            if !edits.isEmpty { persistSaved() }
        case .failure(let error):
            savedState = .unavailable
            savedError = "无法加载已保存流量：\(error.localizedDescription)"
            completeSaveWaiters(false)
        }
        changed.send(.saved)
    }

    private func reindexSaved() {
        savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func persistSaved() {
        guard savedState == .ready else { return }
        nextWrite = SessionFile(transactions: saved, pinnedDomains: [], selected: [])
        writeNextSaved()
    }

    private func writeNextSaved() {
        guard !writingSaved, let snapshot = nextWrite else { return }
        nextWrite = nil
        writingSaved = true
        let destination = savedFile
        savedQueue.async { [weak self] in
            let result = Result {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try snapshot.write(to: destination)
            }
            DispatchQueue.main.async { [weak self] in self?.savedWriteFinished(result) }
        }
    }

    private func savedWriteFinished(_ result: Result<Void, Error>) {
        writingSaved = false
        if nextWrite != nil { writeNextSaved(); return }
        switch result {
        case .success:
            savedError = nil
            completeSaveWaiters(true)
        case .failure(let error):
            savedError = "保存流量失败：\(error.localizedDescription)"
            completeSaveWaiters(false)
        }
        changed.send(.saved)
    }

    func finishSaving(_ completion: @escaping (Bool) -> Void) -> Bool {
        guard writingSaved || !queuedEdits.isEmpty else { return false }
        saveWaiters.append(completion)
        return true
    }

    private func completeSaveWaiters(_ success: Bool) {
        let waiters = saveWaiters
        saveWaiters.removeAll()
        for waiter in waiters { waiter(success) }
    }
}
