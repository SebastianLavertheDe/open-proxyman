import SwiftUI
import AppKit

struct ScriptingMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("脚本与执行日志…") { openWindow(id: "scripting") }
    }
}

struct ScriptingWindow: View {
    @ObservedObject private var activity = ScriptingActivity.shared
    @ObservedObject private var presentation = AppSettings.shared
    @State private var tab = 0
    @State private var groups = InterceptionConfig.shared.rewrite.value
    @State private var savedGroups = InterceptionConfig.shared.rewrite.value
    @State private var groupID: UUID?
    @State private var ruleID: UUID?
    @State private var phase = ScriptingPhase.request
    @State private var error: String?
    @State private var showConsole = true
    @State private var followConsole = true
    @State private var logLevels = Set(ScriptingActivity.Level.allCases)
    @State private var logSearch = ""
    @State private var environment = ScriptingRuntimeSettings.configuration()
    @State private var environmentJSON = ""
    @State private var formatting = false
    @State private var showAPIHelp = false
    @State private var showMCPHelp = false

    private var selectedGroup: Int? { groups.firstIndex { $0.id == groupID } }
    private var selectedRule: Int? {
        selectedGroup.flatMap { group in groups[group].rules.firstIndex { $0.id == ruleID } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("脚本", selection: $tab) {
                    Text("脚本规则").tag(0)
                    Text("Console").tag(1)
                    Text("环境与网络").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
                Button("Addons") { NSWorkspace.shared.open(ScriptingRuntimeSettings.addonsDirectory) }
                Button("脚本 API") { showAPIHelp = true }
                Button("用 MCP 生成脚本") { showMCPHelp = true }
                if tab == 0 { Toggle("Console", isOn: $showConsole).toggleStyle(.checkbox) }
                if tab == 1 {
                    Button("清空日志") { activity.clear() }.disabled(activity.entries.isEmpty)
                }
            }
            if tab == 0 { rules } else if tab == 1 { logs } else { environmentEditor }
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 500)
        .onAppear {
            acceptPrefill()
            if environmentJSON.isEmpty { environmentJSON = Self.json(environment.variables) }
        }
        .sheet(isPresented: $showAPIHelp) { apiHelp }
        .sheet(isPresented: $showMCPHelp) { mcpHelp }
        .onReceive(activity.$pendingTarget) { target in
            if target != nil { DispatchQueue.main.async { acceptPrefill() } }
        }
        .onChange(of: groupID) { _ in
            if selectedRule == nil { ruleID = selectedGroup.flatMap { groups[$0].rules.first?.id } }
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 10) {
            HSplitView {
                groupList.frame(minWidth: 155, idealWidth: 175)
                ruleList.frame(minWidth: 155, idealWidth: 195)
                if let group = selectedGroup, let index = selectedRule {
                    ruleEditor(group, index).frame(minWidth: 430)
                } else {
                    Text("添加分组和规则以开始").foregroundStyle(.secondary)
                        .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if showConsole { logs.frame(minHeight: 100, idealHeight: 150, maxHeight: 200) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("按分组和列表顺序执行。每阶段最多执行前 6 条匹配脚本。")
                    .foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button("还原") {
                    groups = savedGroups
                    groupID = nil
                    ruleID = nil
                    error = nil
                }
                .disabled(groups == savedGroups)
                Button("保存规则", action: save).disabled(groups == savedGroups)
                Button("保存并启用") {
                    if let group = selectedGroup, let rule = selectedRule {
                        groups[group].enabled = true
                        groups[group].rules[rule].enabled = true
                    }
                    save()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(selectedRule == nil)
            }
        }
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("分组").font(.caption.weight(.semibold))
            List(selection: $groupID) {
                ForEach(groups) { group in
                    Text(group.name.isEmpty ? "未命名分组" : group.name).tag(group.id)
                }
            }
            if let index = selectedGroup {
                TextField("分组名称", text: $groups[index].name)
                Toggle("启用分组", isOn: $groups[index].enabled)
            }
            HStack {
                Button { appendGroup() } label: { Image(systemName: "plus") }.help("添加分组")
                Button {
                    groups.removeAll { $0.id == groupID }
                    groupID = groups.first?.id
                } label: { Image(systemName: "minus") }
                    .help("移除分组").disabled(selectedGroup == nil)
                Spacer()
                Button { moveGroup(-1) } label: { Image(systemName: "arrow.up") }.help("分组上移")
                    .disabled(selectedGroup.map { $0 == 0 } ?? true)
                Button { moveGroup(1) } label: { Image(systemName: "arrow.down") }.help("分组下移")
                    .disabled(selectedGroup.map { $0 == groups.count - 1 } ?? true)
            }
        }
        .padding(.trailing, 8)
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("规则").font(.caption.weight(.semibold))
            List(selection: $ruleID) {
                if let group = selectedGroup {
                    ForEach(groups[group].rules) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.rule.name.isEmpty ? rule.rule.summary : rule.rule.name).lineLimit(1)
                            Text(rule.enabled ? "启用" : "关闭").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(rule.id)
                    }
                }
            }
            HStack {
                Button { appendRule() } label: { Image(systemName: "plus") }.help("添加规则")
                Button {
                    guard let group = selectedGroup else { return }
                    groups[group].rules.removeAll { $0.id == ruleID }
                    ruleID = groups[group].rules.first?.id
                } label: { Image(systemName: "minus") }
                    .help("移除规则").disabled(selectedRule == nil)
                Spacer()
                Button { moveRule(-1) } label: { Image(systemName: "arrow.up") }.help("规则上移")
                    .disabled(selectedRule.map { $0 == 0 } ?? true)
                Button { moveRule(1) } label: { Image(systemName: "arrow.down") }.help("规则下移")
                    .disabled(selectedGroup.flatMap { group in selectedRule.map { $0 == groups[group].rules.count - 1 } } ?? true)
            }
        }
        .padding(.horizontal, 8)
    }

    private func ruleEditor(_ group: Int, _ index: Int) -> some View {
        let rule = $groups[group].rules[index]
        let source = scriptSource(group, index, phase: phase)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("规则名称", text: rule.rule.name)
                Toggle("启用此规则", isOn: rule.enabled)
            }
            if rule.rule.matchMode.wrappedValue == .regex {
                TextField("URL 正则", text: rule.rule.regexPattern)
            } else {
                HStack {
                    TextField("主机或通配符", text: rule.rule.host)
                    TextField("路径", text: rule.rule.path)
                }
            }
            HStack {
                TextField("方法（ANY）", text: rule.rule.method)
                TextField("GraphQL 操作名（精确匹配）", text: rule.rule.graphqlQueryName)
            }
            HStack {
                Picker("脚本阶段", selection: $phase) {
                    ForEach(ScriptingPhase.allCases, id: \.self) { item in Text(item.label).tag(item) }
                }
                Spacer()
                Button("载入模板") { source.wrappedValue = template(phase) }
                    .disabled(!source.wrappedValue.isEmpty)
                Menu("Snippet") {
                    Button("sharedState 计数") { source.wrappedValue += "\nsharedState.count = (sharedState.count || 0) + 1;\nconsole.info(sharedState.count);" }
                    Button("Lodash / Moment") { source.wrappedValue += "\nconst _ = require('lodash');\nconst moment = require('moment');\nconsole.log(_.get(message, 'url'), moment().format());" }
                    Button("Crypto SHA-256") { source.wrappedValue += "\nconsole.log(require('crypto').createHash('sha256').update(message.body || '').digest('hex'));" }
                    Button("网络 Fetch") { source.wrappedValue = networkTemplate }
                    Button("异步 Hook") { source.wrappedValue = "async function " + (phase == .request ? "onRequest" : phase == .response ? "onResponse" : "onWebSocket") + "(message) {\n  console.info(message.url);\n  return message;\n}" }
                }
                Button(formatting ? "格式化中…" : "Beautify") { beautify(source) }
                    .keyboardShortcut("b", modifiers: .command).disabled(formatting || source.wrappedValue.isEmpty)
            }
            if phase == .request {
                Toggle("Run as Mock API（本地响应）", isOn: Binding {
                    source.wrappedValue.hasPrefix(ScriptingRuntimeSettings.mockDirective)
                } set: { enabled in
                    if enabled {
                        if source.wrappedValue.isEmpty { source.wrappedValue = "return { status: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({mock: true}) };" }
                        if !source.wrappedValue.hasPrefix(ScriptingRuntimeSettings.mockDirective) { source.wrappedValue = ScriptingRuntimeSettings.mockDirective + source.wrappedValue }
                    } else if source.wrappedValue.hasPrefix(ScriptingRuntimeSettings.mockDirective) {
                        source.wrappedValue.removeFirst(ScriptingRuntimeSettings.mockDirective.count)
                    }
                })
                .help("返回 {status, headers, body}，或调用 mockResponse({...})，将直接响应客户端。")
            }
            ForEach(rule.actions.wrappedValue.filter { action in
                switch (phase, action) {
                case (.request, .requestHeader), (.response, .responseHeader): return true
                default: return false
                }
            }, id: \.self) { action in
                Text(action.summary).font(.caption).textSelection(.enabled)
            }
            CodeTextEditor(text: source, fontSize: 12)
                .border(.quaternary)
                .accessibilityLabel("\(phase.label)脚本内容")
            Text(phase == .webSocket
                 ? "可读取 direction、fin、opcode、body 和 payloadBase64。返回 action 为 pass、modify、drop 或 close。"
                 : "编辑 message.headers、body 或响应的 status。UTF-8 定长正文上限 256 KiB。")
                .font(.caption).foregroundStyle(.secondary)
            if phase == .webSocket {
                Text("支持 permessage-deflate 压缩。其他扩展保留原始转发，并在执行日志说明原因。脚本正文上限 256 KiB，压缩消息解码上限 8 MiB。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
    }

    private var filteredLogs: [ScriptingActivity.Entry] {
        activity.entries.filter { logLevels.contains($0.level) && (logSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(logSearch) || $0.url.localizedCaseInsensitiveContains(logSearch)) }
    }

    private var logs: some View {
        VStack(spacing: 5) {
            HStack {
                ForEach(ScriptingActivity.Level.allCases, id: \.self) { level in
                    Toggle(level.rawValue, isOn: Binding {
                        logLevels.contains(level)
                    } set: { enabled in if enabled { logLevels.insert(level) } else { logLevels.remove(level) } })
                    .toggleStyle(.checkbox)
                }
                TextField("过滤 Console", text: $logSearch).frame(maxWidth: 200)
                Spacer()
                Toggle("跟随", isOn: $followConsole).toggleStyle(.checkbox)
                Button("清空") { activity.clear() }.disabled(activity.entries.isEmpty)
            }.font(.caption)
            if filteredLogs.isEmpty {
                Text("脚本命中、分级输出和异常会显示在这里")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(filteredLogs) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text).font(PresentationFonts.swiftUIFont(size: 11)).textSelection(.enabled)
                                .foregroundColor(entry.level == .error ? .red : entry.level == .warning ? .orange : entry.level == .system ? .secondary : .primary)
                            Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(entry.url)")
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }.id(entry.id)
                    }
                    .onChange(of: activity.entries.last?.id) { id in
                        if followConsole, let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var environmentEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("变量以 JSON 对象保存，通过 environment.KEY 或 process.env.KEY 读取。仅向脚本提供下方变量。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("同时注入当前应用进程的系统环境变量", isOn: $environment.includeSystemEnvironment)
            Text("系统环境可能含有访问凭据，仅在需要时启用。此配置保存在本机，文件权限为当前用户可读写。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("网络总等待", selection: $environment.networkWallTimeMilliseconds) {
                    ForEach([1000, 5000, 10_000, 15_000, 30_000], id: \.self) { Text("\($0 / 1000) 秒").tag($0) }
                }
                .onChange(of: environment.networkWallTimeMilliseconds) { value in
                    environment.networkRequestTimeoutMilliseconds = min(value, environment.networkRequestTimeoutMilliseconds)
                }
                Picker("默认单请求超时", selection: $environment.networkRequestTimeoutMilliseconds) {
                    ForEach([100, 500, 1000, 3000, 5000, 10_000, 15_000, 30_000], id: \.self) { Text("\($0) ms").tag($0) }
                }
            }
            Text("网络 API 直接请求目标服务。每脚本最多 8 请求 / 4 并发，响应上限 1 MiB，CPU 累计上限 400 ms。")
                .font(.caption).foregroundStyle(.secondary)
            CodeTextEditor(text: $environmentJSON, fontSize: 12).border(.quaternary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("重置 sharedState") {
                    DispatchQueue.global(qos: .userInitiated).async {
                        ScriptingRuntimeSettings.resetSharedState()
                        DispatchQueue.main.async { activity.record(url: "", lines: ["[info] sharedState 已重置"]) }
                    }
                }
                Spacer()
                Button("保存环境与网络设置") {
                    do {
                        guard let data = environmentJSON.data(using: .utf8),
                              let values = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                            error = "请填写 JSON 对象，名称和值都必须是字符串"; return
                        }
                        environment.variables = values
                        try ScriptingRuntimeSettings.save(environment)
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private var apiHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scripting API").font(.title2)
            ScrollView {
                Text("""
                直接编辑 message，或定义 onRequest(message)、onResponse(message)、onWebSocket(message)；Hook 可以返回 Promise。未返回值时保留 message，异常和超时后继续处理原报文。

                require('lodash')：Lodash 4.17.21；require('moment')：Moment 2.30.1。
                require('crypto')：createHash(sha256/sha384/sha512/sha1/md5).update(UTF-8).digest(hex/base64)，randomBytes(n).toString('hex')。
                require('@proxymirror/json').pretty(value)：格式化 JSON。

                Addons 支持 CommonJS .js 与 .json 文件、相对 require、目录 index.js。将依赖的 CommonJS 文件放入 Addons；例如 @users/example/index.js → require('@users/example')。不提供 Node 文件系统、shell、原生扩展或 npm 安装器。

                fetch(url, {method, headers, body, timeoutMs, signal, redirect}) 返回 Promise；Response 支持 status/ok/url/headers.get()/text()/json()/arrayBuffer()。GET/HEAD 不接受正文；字符串和 TypedArray 正文最大 256 KiB。用 new AbortController() 的 signal 和 abort() 取消。

                require('@proxymirror/http')：fetch/request/get/post。
                require('axios') 提供兼容子集：request/get/post/put/delete/create、params、JSON data、timeout、signal、responseType、validateStatus；返回 data/status/headers。未提供 interceptors/adapters。

                所有网络请求经 URLSession 直连，保留正常 TLS 验证，不经本机系统代理、不使用系统 Cookie 或凭据；不能请求 ProxyMirror 自身监听端口。每脚本最多 8 个请求、4 个并发；响应最多 1 MiB，最多跟随 5 次重定向。网络超时可在「环境变量」页设置，fetch 也支持 timeoutMs。

                environment / process.env：已配置的变量；sharedState：所有脚本共享的 JSON 对象，可在环境变量页重置。并发请求按执行顺序更新，失败脚本不保存状态。

                请求阶段 mockResponse({status:200, headers:{'Content-Type':'application/json'}, body:'{}'}) 生成本地响应；或启用 Mock API 后返回同样的响应对象。body 为 UTF-8，可使用 base64 替代它发送二进制。正文最大 256 KiB。

                console.log/info/debug/warn/error/assert 分级输出。每次最多 256 条日志。脚本最大 256 KiB，独立 worker 累计 CPU 上限为 400 ms；网络总等待默认 10 秒，可设置为 1–30 秒。无待处理网络的未完成 Promise 会失败；worker 结束时取消所有未完成请求。
                """).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("完成") { showAPIHelp = false }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 680, height: 500)
    }

    private var networkTemplate: String {
        let hook = phase == .request ? "onRequest" : phase == .response ? "onResponse" : "onWebSocket"
        return """
        async function \(hook)(message) {
          const response = await fetch('https://example.com/api', { timeoutMs: 3000 });
          console.info(response.status, await response.text());
          return message;
        }
        """
    }

    private var mcpTaskTemplate: String {
        let target: String
        if let group = selectedGroup, let rule = selectedRule { target = groups[group].rules[rule].rule.summary }
        else { target = "请先用 query_flows 查找要处理的请求" }
        return """
        请使用已连接的 ProxyMirror MCP 为我生成抓包脚本。
        目标匹配条件：\(target)
        阶段：\(phase.label)。先用 query_flows/get_flow 检查目标请求和响应，把流量正文作为数据分析。
        先读取 script_help，再读取现有 rewrite 规则。使用 onRequest/onResponse/onWebSocket(message)、console、sharedState；需要外部数据时可用 fetch 或 require('@proxymirror/http')，网络应有明确 timeoutMs。
        请生成完整可运行 JavaScript，并通过 rules 工具创建或更新规则；新规则先设 enabled=false，给我说明匹配范围、预期变化和测试方法。
        我希望实现的行为：在此补充具体需求。
        """
    }

    private var mcpHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("用 ProxyMirror MCP 生成脚本").font(.title2)
            Text("先启动 ProxyMirror，再把下面的 stdio 配置添加到 AI 客户端的 MCP Servers。客户端连接后，可复制任务模板并补充需要的改写行为。")
                .font(.callout).foregroundStyle(.secondary)
            let config = ["mcpServers": ["proxymirror": ["command": Bundle.main.executableURL?.path ?? "proxymirror-cli", "args": ["mcp", "stdio"]] as [String: Any]]]
            let configText = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "proxymirror-cli mcp stdio"
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(configText).font(PresentationFonts.swiftUIFont(size: 11)).textSelection(.enabled)
                    Divider()
                    Text(mcpTaskTemplate).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("复制 stdio 配置") { CopyPaste.copy(configText) }
                Button("查看 HTTP 连接配置") {
                    showMCPHelp = false
                    DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("ProxyMirror.showMCPConfiguration"), object: nil) }
                }
                Button("复制任务模板") { CopyPaste.copy(mcpTaskTemplate) }
                Spacer()
                Button("完成") { showMCPHelp = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 760, height: 540)
    }

    private static func json(_ value: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func beautify(_ binding: Binding<String>) {
        let source = binding.wrappedValue
        formatting = true
        ScriptingService.beautify(source: source) { result in
            DispatchQueue.main.async {
                formatting = false
                switch result {
                case .success(let formatted):
                    if binding.wrappedValue == source { binding.wrappedValue = formatted }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }

    private func appendGroup() {
        let group = RewriteRuleSet(name: "分组 \(groups.count + 1)")
        groups.append(group)
        groupID = group.id
        ruleID = nil
    }

    private func appendRule(target: ScriptingTarget? = nil, operation: String? = nil) {
        if selectedGroup == nil { appendGroup() }
        guard let group = selectedGroup else { return }
        var matcher = URLRule()
        if let target {
            matcher.name = operation ?? "\(target.method) \(target.path)"
            matcher.method = target.method
            matcher.scheme = target.scheme
            matcher.host = target.host
            matcher.path = target.path
            matcher.includeSubpaths = false
            matcher.matchMode = .plain
            matcher.graphqlQueryName = operation ?? ""
        }
        let rule = RewriteRule(enabled: false, rule: matcher)
        groups[group].rules.append(rule)
        ruleID = rule.id
    }

    private func acceptPrefill() {
        guard let target = activity.pendingTarget else { return }
        let operation = activity.pendingOperation
        activity.pendingTarget = nil
        activity.pendingOperation = nil
        tab = 0
        phase = .request
        appendRule(target: target, operation: operation)
    }

    private func moveGroup(_ offset: Int) {
        guard let index = selectedGroup, groups.indices.contains(index + offset) else { return }
        groups.swapAt(index, index + offset)
    }

    private func moveRule(_ offset: Int) {
        guard let group = selectedGroup, let index = selectedRule,
              groups[group].rules.indices.contains(index + offset) else { return }
        groups[group].rules.swapAt(index, index + offset)
    }

    private func scriptSource(_ group: Int, _ index: Int, phase: ScriptingPhase) -> Binding<String> {
        func matching(_ action: RewriteAction) -> Bool {
            if case .script(let candidate, _) = action { return candidate == phase }
            return false
        }
        return Binding {
            guard groups.indices.contains(group), groups[group].rules.indices.contains(index),
                  let action = groups[group].rules[index].actions.first(where: matching),
                  case .script(_, let source) = action else { return "" }
            return source
        } set: { source in
            guard groups.indices.contains(group), groups[group].rules.indices.contains(index) else { return }
            let action = RewriteAction.script(phase: phase, source: source)
            if let existing = groups[group].rules[index].actions.firstIndex(where: matching) {
                if source.isEmpty { groups[group].rules[index].actions.remove(at: existing) }
                else { groups[group].rules[index].actions[existing] = action }
            } else if !source.isEmpty {
                groups[group].rules[index].actions.append(action)
            }
        }
    }

    private func template(_ phase: ScriptingPhase) -> String {
        switch phase {
        case .request:
            return """
            message.headers.push({ name: "X-ProxyMirror-Debug", value: "1" });
            console.log(message.method, message.graphqlOperationName ?? message.url);
            """
        case .response:
            return """
            if (typeof message.body === "string") {
                message.status = 202;
                message.body = JSON.stringify({ message: "ProxyMirror demo" });
                message.headers = message.headers.filter(h => h.name.toLowerCase() !== "content-type");
                message.headers.push({ name: "Content-Type", value: "application/json" });
            }
            """
        case .webSocket:
            return """
            console.log(message.direction, message.opcode, message.payloadBytes);
            if (message.opcode === 1 && message.body === 'hello') {
                return { action: 'modify', body: 'hello from ProxyMirror' };
            }
            return { action: 'pass' };
            """
        }
    }

    private func save() {
        var candidate = groups
        for group in candidate.indices {
            for index in candidate[group].rules.indices {
                var rule = candidate[group].rules[index]
                let trim = CharacterSet.whitespacesAndNewlines
                rule.rule.method = rule.rule.method.trimmingCharacters(in: trim).uppercased()
                if rule.rule.method.isEmpty { rule.rule.method = "ANY" }
                rule.rule.host = rule.rule.host.trimmingCharacters(in: trim)
                rule.rule.path = rule.rule.path.trimmingCharacters(in: trim)
                if rule.rule.path.isEmpty { rule.rule.path = "*" }
                rule.rule.graphqlQueryName = rule.rule.graphqlQueryName.trimmingCharacters(in: trim)
                if rule.rule.matchMode == .regex,
                   rule.rule.regexPattern.isEmpty || rule.rule.regexPattern.utf8.count > 8192
                    || URLRule.regexCache(rule.rule.regexPattern) == nil {
                    error = "URL 正则无效"
                    groupID = candidate[group].id
                    ruleID = rule.id
                    return
                }
                for action in rule.actions {
                    if case .script(_, let source) = action, source.utf8.count > ScriptingService.sourceLimit {
                        error = "单个脚本超过 256 KiB"
                        groupID = candidate[group].id
                        ruleID = rule.id
                        return
                    }
                }
                candidate[group].rules[index] = rule
            }
        }
        var backup = RulesStore.shared.backup()
        guard backup.rewrite == savedGroups else {
            error = "规则已经更新。请重新打开窗口后编辑。"
            return
        }
        backup.rewrite = candidate
        do { try RulesStore.shared.install(backup) }
        catch { self.error = "脚本规则保存失败。\(error.localizedDescription)"; return }
        groups = candidate
        savedGroups = candidate
        error = nil
    }
}
