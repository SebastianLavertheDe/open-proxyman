import SwiftUI

// MARK: - 工具窗口类型（对齐 Proxyman Tools 菜单）

enum ToolKind: String, Identifiable, CaseIterable {
    case compose, mapLocal, mapRemote, blockList, allowList, sslProxyingList
    case sslApplications, dnsMapping, reverseProxy, customCertificates
    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .compose: return Strings.Tools.composeRequest
        case .mapLocal: return Strings.Tools.mapLocal
        case .mapRemote: return Strings.Tools.mapRemote
        case .blockList: return Strings.Tools.blockList
        case .allowList: return Strings.Tools.allowList
        case .sslProxyingList: return Strings.Tools.sslProxyingList
        case .sslApplications: return Strings.Tools.sslByApplication
        case .dnsMapping: return Strings.Tools.dnsMapping
        case .reverseProxy: return Strings.Tools.reverseProxy
        case .customCertificates: return Strings.Tools.customServerCertificates
        }
    }
    var searchAliases: [String] {
        let key: String
        switch self {
        case .compose: key = "compose_request"
        case .mapLocal: key = "map_local"
        case .mapRemote: key = "map_remote"
        case .blockList: key = "block_list"
        case .allowList: key = "allow_list"
        case .sslProxyingList: key = "ssl_proxying_list"
        case .sslApplications: key = "ssl_by_application"
        case .dnsMapping: key = "dns_mapping"
        case .reverseProxy: key = "reverse_proxy"
        case .customCertificates: key = "custom_server_certificates"
        }
        return [rawValue,
                L10n.render(table: "Tools", key: key, englishFallback: rawValue, language: "en"),
                L10n.render(table: "Tools", key: key, englishFallback: rawValue, language: "zh-Hans")]
    }

}

struct ComposeRequestView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction?

    @State private var method = "GET"
    @State private var url = ""
    @State private var headers = ""
    @State private var query = ""
    @State private var bodyText = ""
    @State private var binaryBody: Data?
    @State private var rawText = ""
    @State private var rawMode = false
    @State private var direct = false
    @State private var error: String?
    @State private var result: Transaction?
    @State private var task: ComposeService.RequestTask?
    @State private var importingCurl = false
    @State private var curlText = ""
    @State private var timeoutSeconds = 60
    @State private var followRedirects = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(transaction == nil ? Strings.Tools.composeRequest : Strings.Tools.editAndResend).font(.headline)
                Spacer()
                Toggle(Strings.Tools.direct, isOn: $direct).help(Strings.Tools.whenDisabledRequestsPassThroughProxymirrorRules)
                Button(task == nil ? Strings.Tools.close : Strings.Tools.cancelRequest) {
                    if let task { task.cancel() } else { dismiss() }
                }
                Button(Strings.Tools.send) { execute() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(task != nil)
            }

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker(Strings.Tools.editor, selection: Binding(get: { rawMode }, set: changeMode)) {
                            Text(Strings.Tools.form).tag(false)
                            Text(Strings.Tools.raw).tag(true)
                        }
                        .pickerStyle(.segmented)
                        Menu(Strings.Tools.template) {
                            ForEach(ComposeService.Template.allCases) { template in
                                Button(template.localizedTitle) { load(template.request(url: url)) }
                            }
                            Button(Strings.Tools.importCurl) { importingCurl = true }
                        }
                        Menu(Strings.Tools.history) {
                            ForEach(appState.composeHistory.indices, id: \.self) { index in
                                let item = appState.composeHistory[index]
                                Button("\(item.method) \(item.url)") { load(item) }
                            }
                        }
                        .disabled(appState.composeHistory.isEmpty)
                    }
                    HStack {
                        Picker(Strings.Tools.timeout, selection: $timeoutSeconds) {
                            Text(Strings.Tools.unlimited).tag(0); Text(Strings.Tools.step15Seconds).tag(15); Text(Strings.Tools.step30Seconds).tag(30); Text(Strings.Tools.step60Seconds).tag(60)
                            if ![0, 15, 30, 60].contains(timeoutSeconds) { Text(Strings.Tools.seconds(Int(timeoutSeconds))).tag(timeoutSeconds) }
                        }.frame(width: 165)
                        Toggle(Strings.Tools.followRedirects, isOn: $followRedirects)
                    }
                    if url.hasPrefix("ws://") || url.hasPrefix("wss://") {
                        Text(Strings.Tools.websocketSendsTheBodyAsTheFirstMessageThen)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if rawMode {
                        editor(Strings.Tools.httpMessage, text: $rawText)
                    } else {
                        HStack {
                            TextField(Strings.Tools.method, text: $method).frame(width: 74)
                            TextField("https://example.com/path", text: $url)
                        }
                        .textFieldStyle(.roundedBorder)
                        TextField(Strings.Tools.queryParametersForExampleTagATagB, text: $query).textFieldStyle(.roundedBorder)
                        editor(Strings.Tools.requestHeaders, text: $headers).frame(minHeight: 100)
                        if let binaryBody {
                            HStack {
                                Text(Strings.Tools.retainedBytesOfBinaryBody(Int(binaryBody.count)))
                                Button(Strings.Tools.replaceWithText) { self.binaryBody = nil }
                            }
                        } else {
                            editor(Strings.Tools.body, text: $bodyText).frame(minHeight: 100)
                        }
                    }
                }
                .frame(minWidth: 350)

                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.Tools.response).font(.headline)
                    if let result {
                        Text(result.state == .failed ? result.localizedErrorText ?? Strings.Tools.sendFailed : result.statusText)
                            .font(.system(.body, design: .monospaced))
                        BodyContentView(data: result.responseBody, contentType: result.contentType, pretty: true,
                                        complete: result.responseBodyComplete, truncated: result.responseTruncated,
                                        revision: result.responseBodyRevision)
                            .id(ObjectIdentifier(result))
                    } else if task != nil {
                        ProgressView(Strings.Tools.waitingForResponse).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(Strings.Tools.noResponseYet).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.leading, 8)
                .frame(minWidth: 270)
            }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(16)
        .frame(width: 780, height: 520)
        .onAppear {
            if appState.composeHistory.isEmpty { appState.composeHistory = ComposeService.loadHistory() }
            if let transaction {
                if let request = ComposeService.replayRequest(from: transaction) {
                    load(request)
                } else {
                    error = Strings.Tools.theRequestBodyIsIncompleteAndCannotPrefillThe
                }
            }
        }
        .onDisappear { task?.cancel() }
        .sheet(isPresented: $importingCurl) {
            VStack(alignment: .leading, spacing: 10) {
                editor(Strings.Tools.curlCommand, text: $curlText)
                HStack {
                    Spacer()
                    Button(Strings.Tools.cancel) { importingCurl = false }
                    Button(Strings.Tools.import) {
                        if let parsed = ComposeService.parseCurl(curlText) {
                            load(parsed)
                            error = nil
                        } else {
                            error = Strings.Tools.unableToParseCurlImportSupportsAUrlMethod
                        }
                        importingCurl = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 520, height: 250)
        }
    }

    private func editor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel(title)
                .overlay(Rectangle().strokeBorder(.quaternary))
        }
    }

    private func load(_ request: ComposeService.ParsedRequest) {
        method = request.method
        timeoutSeconds = request.timeoutSeconds
        followRedirects = request.followRedirects
        if var components = URLComponents(string: request.url) {
            query = components.percentEncodedQuery ?? ""
            components.percentEncodedQuery = nil
            url = components.string ?? request.url
        } else {
            url = request.url
            query = ""
        }
        headers = request.headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        bodyText = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        binaryBody = bodyText.isEmpty && request.body?.isEmpty == false ? request.body : nil
        rawText = ComposeService.rawText(from: request)
    }

    private func parsed() -> ComposeService.ParsedRequest? {
        if rawMode {
            var request = ComposeService.parse(rawText)
            request?.timeoutSeconds = timeoutSeconds
            request?.followRedirects = followRedirects
            return request
        }
        guard var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil else { return nil }
        if !query.isEmpty {
            guard let parsedQuery = URLComponents(string: "https://localhost/?" + query), parsedQuery.fragment == nil else { return nil }
            components.percentEncodedQuery = parsedQuery.percentEncodedQuery
        }
        guard let target = components.string else { return nil }
        let raw = "\(method) \(target) HTTP/1.1\n\(headers)\n\n\(bodyText)"
        guard var request = ComposeService.parse(raw) else { return nil }
        if let binaryBody { request.body = binaryBody }
        request.timeoutSeconds = timeoutSeconds
        request.followRedirects = followRedirects
        return request
    }

    private func changeMode(_ raw: Bool) {
        if raw {
            guard binaryBody == nil else {
                error = Strings.Tools.keepTheBinaryBodyInFormModeOrReplace
                return
            }
            if let request = parsed() { rawText = ComposeService.rawText(from: request) }
        } else if let request = parsed() {
            load(request)
        } else if !rawText.isEmpty {
            error = Strings.Tools.correctTheRawMessageBeforeSwitchingToFormMode
            return
        }
        error = nil
        rawMode = raw
    }

    private func execute() {
        guard let request = parsed() else { error = Strings.Tools.enterAValidHttpMethodAndUrl; return }
        if !direct && !appState.proxyRunning { appState.startProxy(automaticallyTakeOver: false) }
        guard direct || appState.proxyRunning else { error = appState.proxyStartError; return }
        error = nil
        result = nil
        let proxyPort = direct ? nil : ProxyEngine.shared.port
        appState.composeHistory.insert(request, at: 0)
        if appState.composeHistory.count > 20 { appState.composeHistory.removeLast() }
        ComposeService.saveHistory(appState.composeHistory)
        task = ComposeService.execute(request, proxyPort: proxyPort) { tx in
            task = nil
            result = tx
            if proxyPort == nil || tx.state == .failed { appState.store.add(tx) }
        }
        if task == nil { error = Strings.Tools.theUrlMustUseHttpHttpsWsOrWss }
    }
}

// MARK: - 规则列表编辑器（Map Local / Map Remote / Block / Allow / SSL Proxying）

struct RulesEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let kind: ToolKind
    var initialPattern = ""

    @State private var rules: [ProxyRule] = []
    @State private var selection: Set<ProxyRule.ID> = []
    @State private var newPattern = ""
    @State private var newTarget = ""
    @State private var newStatus = "200"
    @State private var newHeaders = ""
    @State private var editing: ProxyRule?
    @State private var error: String?
    @State private var folders: [RuleFolder] = []
    @State private var folderAssignments: [UUID: String] = [:]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(kind.localizedTitle).font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu(Strings.Tools.moveToFolder) {
                    Button(Strings.Tools.ungrouped) { for id in selection { folderAssignments[id] = "" } }
                    ForEach(folders) { folder in
                        Button(folderPath(folder)) { for id in selection { folderAssignments[id] = folder.id.uuidString } }
                    }
                }.disabled(selection.isEmpty)
                Button(Strings.Tools.edit) { if let currentRule { edit(currentRule) } }.disabled(currentRule == nil)
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .help(Strings.Tools.runEarlier).disabled(currentIndex == nil || currentIndex == 0)
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .help(Strings.Tools.runLater).disabled(currentIndex == nil || currentIndex == rules.count - 1)
                Button(Strings.Tools.removeSelected) { removeSelected() }
                    .disabled(selection.isEmpty)
            }
            table
            addRow
            if kind == .blockList || kind == .allowList {
                Text(Strings.Tools.httpsTunnelsAreMatchedByDomainAndPortMatching)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if kind == .mapLocal {
                HStack {
                    TextField(Strings.Tools.statusCode, text: $newStatus).frame(width: 72)
                    TextField(Strings.Tools.extraResponseHeadersOnePerLine, text: $newHeaders, axis: .vertical).lineLimit(1...3)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text(kind == .sslProxyingList ? Strings.Tools.hostnamesSupportExampleComWildcardsMatchSubdomains :
                     (kind == .mapLocal ? Strings.Tools.directoryMappingsFindFilesUsingTheRequestPath : Strings.Tools.theFirstMatchingRuleInListOrderApplies))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button(Strings.Tools.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Tools.save) {
                    if canAdd { addRule() }
                    do { try commit(); dismiss() }
                    catch { self.error = LocalizedErrorPresentation.message(for: error) }
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(editing != nil && !canAdd)
            }
        }
        .padding(14)
        .frame(width: 680, height: 380)
        .onAppear {
            rules = bindingRules.wrappedValue
            newPattern = initialPattern
            if let toolKey { folders = RuleOrganizationStore.shared.folders(tool: toolKey) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ruleOrganizationChanged)) { _ in
            if let toolKey { folders = RuleOrganizationStore.shared.folders(tool: toolKey) }
        }
    }

    private var toolKey: String? {
        switch kind {
        case .mapLocal: return RuleBackup.Section.mapLocal.rawValue
        case .mapRemote: return RuleBackup.Section.mapRemote.rawValue
        case .blockList: return RuleBackup.Section.blockList.rawValue
        case .allowList: return RuleBackup.Section.allowList.rawValue
        case .sslProxyingList: return RuleBackup.Section.sslProxyingList.rawValue
        default: return nil
        }
    }

    private func folderID(for rule: ProxyRule) -> UUID? {
        if let pending = folderAssignments[rule.id] { return UUID(uuidString: pending) }
        guard let toolKey else { return nil }
        return RuleOrganizationStore.shared.folderID(ruleID: rule.id.uuidString, tool: toolKey)
    }

    private func folderPath(_ folder: RuleFolder) -> String {
        var names = [folder.name], parent = folder.parentID, seen: Set<UUID> = [folder.id]
        while let id = parent, let ancestor = folders.first(where: { $0.id == id }), seen.insert(id).inserted {
            names.insert(ancestor.name, at: 0); parent = ancestor.parentID
        }
        return names.joined(separator: " / ")
    }

    private var bindingRules: Binding<[ProxyRule]> {
        switch kind {
        case .mapLocal: return Binding(get: { RulesStore.shared.mapLocal }, set: { RulesStore.shared.mapLocal = $0 })
        case .mapRemote: return Binding(get: { RulesStore.shared.mapRemote }, set: { RulesStore.shared.mapRemote = $0 })
        case .blockList: return Binding(get: { RulesStore.shared.blockList }, set: { RulesStore.shared.blockList = $0 })
        case .allowList: return Binding(get: { RulesStore.shared.allowList }, set: { RulesStore.shared.allowList = $0 })
        case .sslProxyingList: return Binding(get: { RulesStore.shared.sslProxyingList }, set: { RulesStore.shared.sslProxyingList = $0 })
        case .compose, .dnsMapping, .reverseProxy, .sslApplications, .customCertificates: return .constant([])
        }
    }

    @ViewBuilder
    private var table: some View {
        List(selection: $selection) {
            ForEach(rules) { rule in
                HStack(spacing: 8) {
                    Toggle(Strings.Tools.enableRule, isOn: Binding(
                        get: { rule.enabled },
                        set: { on in
                            if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                                rules[idx].enabled = on
                            }
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.pattern.isEmpty ? "*" : rule.pattern)
                            .font(.system(size: 12, design: .monospaced))
                        if !rule.target.isEmpty {
                            Text("→ \(rule.target)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let id = folderID(for: rule), let folder = folders.first(where: { $0.id == id }) {
                        Label(folderPath(folder), systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    }
                    if !rule.comment.isEmpty {
                        Text(rule.comment).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                .tag(rule.id)
            }
        }
        .listStyle(.inset)
        .border(Color.gray.opacity(0.25))
    }

    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: 6) {
            TextField(Strings.Tools.patternEGHttpsApiExampleCom, text: $newPattern)
                .textFieldStyle(.roundedBorder)
            if kind == .mapLocal {
                Button(Strings.Tools.chooseFile) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { newTarget = url.path }
                }
                TextField(Strings.Tools.localFilePath, text: $newTarget)
                    .textFieldStyle(.roundedBorder)
            } else if kind == .mapRemote {
                TextField(Strings.Tools.targetHttpsNewhostBase, text: $newTarget)
                    .textFieldStyle(.roundedBorder)
            }
            Button(editing == nil ? Strings.Tools.add : Strings.Tools.updateRule) { addRule() }.disabled(!canAdd)
            if editing != nil { Button(Strings.Tools.finishEditing) { clearEditor() } }
        }
    }

    private var canAdd: Bool {
        guard !newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .mapLocal:
            return FileManager.default.isReadableFile(atPath: newTarget)
                && Int(newStatus).map { (200...599).contains($0) } == true
                && parsedHeaders != nil
        case .mapRemote:
            let candidate = ProxyRule(pattern: "*", target: newTarget)
            return RulesSnapshot(mapRemote: [candidate]).mapRemoteTarget(for: "http://example.invalid/") != nil
        default: return true
        }
    }

    private func addRule() {
        guard canAdd else { return }
        var rule = rules.first { $0.id == editing?.id } ?? ProxyRule(pattern: newPattern)
        let pattern = kind == .sslProxyingList ? RulesSnapshot.sslHostPattern(newPattern) : newPattern
        if rule.pattern != pattern { rule.urlRegex = nil }
        rule.pattern = pattern
        rule.target = kind == .mapLocal || kind == .mapRemote ? newTarget : ""
        if kind == .mapLocal {
            rule.responseStatus = Int(newStatus)
            rule.responseHeaders = parsedHeaders
        }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        clearEditor()
    }

    private var parsedHeaders: HTTPHeaders? {
        let lines = newHeaders.split(whereSeparator: \.isNewline).joined(separator: "\n")
        return ComposeService.parse("GET http://localhost/ HTTP/1.1\n" + lines).map { HTTPHeaders($0.headers) }
    }

    private var currentIndex: Int? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rules.firstIndex { $0.id == id }
    }

    private var currentRule: ProxyRule? { currentIndex.map { rules[$0] } }

    private func move(_ offset: Int) {
        guard let index = currentIndex, rules.indices.contains(index + offset) else { return }
        rules.swapAt(index, index + offset)
    }

    private func edit(_ rule: ProxyRule) {
        editing = rule
        newPattern = rule.pattern
        newTarget = rule.target
        newStatus = String(rule.responseStatus ?? 200)
        newHeaders = rule.responseHeaders?.pairs.map { "\($0.name): \($0.value)" }.joined(separator: "\n") ?? ""
    }

    private func clearEditor() {
        editing = nil
        newPattern = ""
        newTarget = ""
        newStatus = "200"
        newHeaders = ""
    }

    private func removeSelected() {
        if let editing, selection.contains(editing.id) { clearEditor() }
        rules.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private func commit() throws {
        var config = RulesStore.shared.backup()
        switch kind {
        case .mapLocal: config.mapLocal = rules
        case .mapRemote: config.mapRemote = rules
        case .blockList: config.blockList = rules
        case .allowList: config.allowList = rules
        case .sslProxyingList: config.sslProxyingList = rules
        case .compose, .dnsMapping, .reverseProxy, .sslApplications, .customCertificates: return
        }
        if let toolKey {
            var organization = config.organization ?? RuleOrganizationStore.shared.snapshot()
            let existing = Set(rules.map { $0.id.uuidString })
            organization.assignments = organization.assignments.filter { key, _ in
                !key.hasPrefix(toolKey + ":") || existing.contains(String(key.dropFirst(toolKey.count + 1)))
            }
            for (ruleID, folderID) in folderAssignments where existing.contains(ruleID.uuidString) {
                let key = toolKey + ":" + ruleID.uuidString
                if folderID.isEmpty { organization.assignments.removeValue(forKey: key) }
                else { organization.assignments[key] = folderID }
            }
            config.organization = organization
        }
        try RulesStore.shared.install(config)
    }
}
