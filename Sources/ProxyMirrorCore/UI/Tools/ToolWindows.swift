import SwiftUI

// MARK: - 工具窗口类型（对齐 Proxyman Tools 菜单）

enum ToolKind: String, Identifiable, CaseIterable {
    case compose = "Compose Request"
    case mapLocal = "Map Local"
    case mapRemote = "Map Remote"
    case blockList = "Block List"
    case allowList = "Allow List"
    case sslProxyingList = "SSL Proxying List"
    case sslApplications = "按应用配置 SSL"
    case dnsMapping = "DNS 映射"
    case reverseProxy = "反向代理"
    case customCertificates = "自定义服务端证书"
    var id: String { rawValue }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(transaction == nil ? "构建请求" : "编辑并重发").font(.headline)
                Spacer()
                Toggle("直连", isOn: $direct).help("关闭时请求经过 ProxyMirror 的规则。")
                Button(task == nil ? "关闭" : "取消请求") {
                    if let task { task.cancel() } else { dismiss() }
                }
                Button("发送") { execute() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(task != nil)
            }

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("编辑方式", selection: Binding(get: { rawMode }, set: changeMode)) {
                            Text("表单").tag(false)
                            Text("Raw").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Menu("模板") {
                            Button("GET") { load(.init(method: "GET", url: "", headers: [], body: nil)) }
                            Button("POST JSON") {
                                load(.init(method: "POST", url: "",
                                           headers: [("Content-Type", "application/json")], body: Data("{}".utf8)))
                            }
                            Button("导入 cURL…") { importingCurl = true }
                        }
                        Menu("历史") {
                            ForEach(appState.composeHistory.indices, id: \.self) { index in
                                let item = appState.composeHistory[index]
                                Button("\(item.method) \(item.url)") { load(item) }
                            }
                        }
                        .disabled(appState.composeHistory.isEmpty)
                    }
                    if rawMode {
                        editor("HTTP 报文", text: $rawText)
                    } else {
                        HStack {
                            TextField("方法", text: $method).frame(width: 74)
                            TextField("https://example.com/path", text: $url)
                        }
                        .textFieldStyle(.roundedBorder)
                        TextField("查询参数（例如 tag=a&tag=b）", text: $query).textFieldStyle(.roundedBorder)
                        editor("请求头", text: $headers).frame(minHeight: 100)
                        if let binaryBody {
                            HStack {
                                Text("已保留 \(binaryBody.count) 字节二进制正文")
                                Button("替换为文本") { self.binaryBody = nil }
                            }
                        } else {
                            editor("正文", text: $bodyText).frame(minHeight: 100)
                        }
                    }
                }
                .frame(minWidth: 350)

                VStack(alignment: .leading, spacing: 8) {
                    Text("响应").font(.headline)
                    if let result {
                        Text(result.state == .failed ? result.errorText ?? "发送失败" : result.statusText)
                            .font(.system(.body, design: .monospaced))
                        BodyContentView(data: result.responseBody, contentType: result.contentType, pretty: true,
                                        complete: result.responseBodyComplete, truncated: result.responseTruncated,
                                        revision: result.responseBodyRevision)
                            .id(ObjectIdentifier(result))
                    } else if task != nil {
                        ProgressView("等待响应…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("尚无响应").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let transaction {
                if let request = ComposeService.replayRequest(from: transaction) {
                    load(request)
                } else {
                    error = "请求正文不完整，无法预填编辑器。"
                }
            }
        }
        .onDisappear { task?.cancel() }
        .sheet(isPresented: $importingCurl) {
            VStack(alignment: .leading, spacing: 10) {
                editor("cURL 命令", text: $curlText)
                HStack {
                    Spacer()
                    Button("取消") { importingCurl = false }
                    Button("导入") {
                        if let parsed = ComposeService.parseCurl(curlText) {
                            load(parsed)
                            error = nil
                        } else {
                            error = "无法解析 cURL。可导入 URL、方法、请求头和内联正文。"
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
        if rawMode { return ComposeService.parse(rawText) }
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
        return request
    }

    private func changeMode(_ raw: Bool) {
        if raw {
            guard binaryBody == nil else {
                error = "二进制正文请在表单模式中保留，或先替换为文本。"
                return
            }
            if let request = parsed() { rawText = ComposeService.rawText(from: request) }
        } else if let request = parsed() {
            load(request)
        } else if !rawText.isEmpty {
            error = "请先修正 Raw 报文，再切换到表单。"
            return
        }
        error = nil
        rawMode = raw
    }

    private func execute() {
        guard let request = parsed() else { error = "请输入有效的 HTTP 方法和 URL。"; return }
        if !direct && !appState.proxyRunning { appState.startProxy(automaticallyTakeOver: false) }
        guard direct || appState.proxyRunning else { error = appState.proxyStartError; return }
        error = nil
        result = nil
        let proxyPort = direct ? nil : ProxyEngine.shared.port
        appState.composeHistory.insert(request, at: 0)
        if appState.composeHistory.count > 20 { appState.composeHistory.removeLast() }
        task = ComposeService.execute(request, proxyPort: proxyPort) { tx in
            task = nil
            result = tx
            if proxyPort == nil || tx.state == .failed { appState.store.add(tx) }
        }
        if task == nil { error = "URL 必须使用 http 或 https。" }
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

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(kind.rawValue).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("编辑") { if let currentRule { edit(currentRule) } }.disabled(currentRule == nil)
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .help("提前执行").disabled(currentIndex == nil || currentIndex == 0)
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .help("延后执行").disabled(currentIndex == nil || currentIndex == rules.count - 1)
                Button("移除所选") { removeSelected() }
                    .disabled(selection.isEmpty)
            }
            table
            addRow
            if kind == .mapLocal {
                HStack {
                    TextField("状态码", text: $newStatus).frame(width: 72)
                    TextField("额外响应头（每行一项）", text: $newHeaders, axis: .vertical).lineLimit(1...3)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text(kind == .sslProxyingList ? "主机名支持 *.example.com，通配符匹配子域" :
                     (kind == .mapLocal ? "目录映射按请求路径查找文件" : "按列表顺序应用首条匹配规则"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if canAdd { addRule() }
                    do { try commit(); dismiss() }
                    catch { self.error = error.localizedDescription }
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
        }
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
                    Toggle("", isOn: Binding(
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
            TextField("pattern (e.g. https://api.example.com/*)", text: $newPattern)
                .textFieldStyle(.roundedBorder)
            if kind == .mapLocal {
                Button("Choose File…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { newTarget = url.path }
                }
                TextField("local file path", text: $newTarget)
                    .textFieldStyle(.roundedBorder)
            } else if kind == .mapRemote {
                TextField("target (https://newhost/base)", text: $newTarget)
                    .textFieldStyle(.roundedBorder)
            }
            Button(editing == nil ? "添加" : "更新规则") { addRule() }.disabled(!canAdd)
            if editing != nil { Button("结束编辑") { clearEditor() } }
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
        try RulesStore.shared.install(config)
    }
}
