import SwiftUI
import AppKit

struct ScriptingMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(Strings.Tools.scriptsExecutionLogs) { openWindow(id: "scripting") }
            .keyboardShortcut("i", modifiers: [.option, .command])
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
    @State private var ruleSearch = ""
    @State private var scriptingEnabled = RuleOrganizationStore.shared.isEnabled("rewrite")
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
            Toggle(Strings.Tools.ruleWindowEnable(Strings.Tools.scripting), isOn: Binding(
                get: { scriptingEnabled }, set: { value in
                    do { try RuleOrganizationStore.shared.setEnabled(value, tool: "rewrite"); scriptingEnabled = value }
                    catch { self.error = LocalizedErrorPresentation.message(for: error) }
                })).toggleStyle(.checkbox)
            HStack {
                Picker(Strings.Tools.scripting, selection: $tab) {
                    Text(Strings.Tools.scriptRules).tag(0)
                    Text(Strings.Tools.environmentNetwork).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
                Button(Strings.Tools.addons) { NSWorkspace.shared.open(ScriptingRuntimeSettings.addonsDirectory) }
                Button(Strings.Tools.scriptingApi) { showAPIHelp = true }
                Button(Strings.Tools.generateScriptWithMcp) { showMCPHelp = true }
                if tab == 0 {
                    Toggle(Strings.Tools.console, isOn: $showConsole).toggleStyle(.checkbox)
                    Menu(Strings.Tools.ruleWindowAdvanced) {
                        Toggle(Strings.Tools.ruleWindowStopAfterFirst, isOn: Binding(
                            get: { environment.stopAfterFirstMatch }, set: { value in
                                var current = ScriptingRuntimeSettings.configuration()
                                current.stopAfterFirstMatch = value
                                do { try ScriptingRuntimeSettings.save(current); environment.stopAfterFirstMatch = value }
                                catch { self.error = LocalizedErrorPresentation.message(for: error) }
                            }))
                    }
                }
            }
            if tab == 0 { rules } else { environmentEditor }
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 500)
        .searchable(text: $ruleSearch, prompt: Strings.Tools.ruleWindowSearch)
        .onAppear {
            acceptPrefill()
            if environmentJSON.isEmpty { environmentJSON = Self.json(environment.variables) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ruleOrganizationChanged)) { _ in
            scriptingEnabled = RuleOrganizationStore.shared.isEnabled("rewrite")
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
            VSplitView {
                HSplitView {
                    groupList.frame(minWidth: 155, idealWidth: 175)
                    ruleList.frame(minWidth: 155, idealWidth: 195)
                    if let group = selectedGroup, let index = selectedRule {
                        ruleEditor(group, index).frame(minWidth: 430)
                    } else {
                        Text(Strings.Tools.addAGroupAndRuleToGetStarted).foregroundStyle(.secondary)
                            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if showConsole {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(Strings.Tools.console).font(.caption.weight(.semibold))
                            Spacer()
                            Button(Strings.Tools.clearLogs) { activity.clear() }.disabled(activity.entries.isEmpty)
                        }
                        logs
                    }.frame(minHeight: 130, idealHeight: 170, maxHeight: 300)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text(Strings.Tools.scriptsRunInGroupAndListOrderEachStage)
                    .foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button(Strings.Tools.revert) {
                    groups = savedGroups
                    groupID = nil
                    ruleID = nil
                    error = nil
                }
                .disabled(groups == savedGroups)
                Button(Strings.Tools.saveRule, action: save).disabled(groups == savedGroups)
                Button(Strings.Tools.saveEnable) {
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

    private func matchesSearch(_ rule: RewriteRule) -> Bool {
        rule.rule.name.localizedCaseInsensitiveContains(ruleSearch) ||
            rule.rule.summary.localizedCaseInsensitiveContains(ruleSearch) ||
            rule.actions.contains { $0.summary.localizedCaseInsensitiveContains(ruleSearch) }
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Strings.Tools.group).font(.caption.weight(.semibold))
            List(selection: $groupID) {
                ForEach(groups.filter { group in
                    ruleSearch.isEmpty || group.name.localizedCaseInsensitiveContains(ruleSearch) || group.rules.contains(where: matchesSearch)
                }) { group in
                    Text(group.name.isEmpty ? Strings.Tools.untitledGroup : group.name).tag(group.id)
                }
            }
            if let index = selectedGroup {
                TextField(Strings.Tools.groupName, text: $groups[index].name)
                Toggle(Strings.Tools.enableGroup, isOn: $groups[index].enabled)
            }
            HStack {
                Button { appendGroup() } label: { Image(systemName: "plus") }.help(Strings.Tools.addGroup)
                Button {
                    groups.removeAll { $0.id == groupID }
                    groupID = groups.first?.id
                } label: { Image(systemName: "minus") }
                    .help(Strings.Tools.removeGroup).disabled(selectedGroup == nil)
                Spacer()
                Button { moveGroup(-1) } label: { Image(systemName: "arrow.up") }.help(Strings.Tools.moveGroupUp)
                    .disabled(selectedGroup.map { $0 == 0 } ?? true)
                Button { moveGroup(1) } label: { Image(systemName: "arrow.down") }.help(Strings.Tools.moveGroupDown)
                    .disabled(selectedGroup.map { $0 == groups.count - 1 } ?? true)
            }
        }
        .padding(.trailing, 8)
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Strings.Tools.rules).font(.caption.weight(.semibold))
            List(selection: $ruleID) {
                if let group = selectedGroup {
                    ForEach(groups[group].rules.filter { ruleSearch.isEmpty || groups[group].name.localizedCaseInsensitiveContains(ruleSearch) || matchesSearch($0) }) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.rule.name.isEmpty ? rule.rule.summary : rule.rule.name).lineLimit(1)
                            Text(rule.enabled ? Strings.Tools.stateEnabled : Strings.Tools.stateDisabled).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(rule.id)
                    }
                }
            }
            HStack {
                Button { appendRule() } label: { Image(systemName: "plus") }.help(Strings.Tools.addRule)
                Button {
                    guard let group = selectedGroup else { return }
                    groups[group].rules.removeAll { $0.id == ruleID }
                    ruleID = groups[group].rules.first?.id
                } label: { Image(systemName: "minus") }
                    .help(Strings.Tools.removeRule).disabled(selectedRule == nil)
                Spacer()
                Button { moveRule(-1) } label: { Image(systemName: "arrow.up") }.help(Strings.Tools.moveRuleUp)
                    .disabled(selectedRule.map { $0 == 0 } ?? true)
                Button { moveRule(1) } label: { Image(systemName: "arrow.down") }.help(Strings.Tools.moveRuleDown)
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
                TextField(Strings.Tools.ruleName, text: rule.rule.name)
                Toggle(Strings.Tools.enableThisRule, isOn: rule.enabled)
            }
            if rule.rule.matchMode.wrappedValue == .regex {
                TextField(Strings.Tools.urlRegularExpression, text: rule.rule.regexPattern)
            } else {
                HStack {
                    TextField(Strings.Tools.hostOrPattern, text: rule.rule.host)
                    TextField(Strings.Tools.path, text: rule.rule.path)
                }
            }
            HStack {
                TextField(Strings.Tools.methodAny, text: rule.rule.method)
                TextField(Strings.Tools.graphqlOperationNameExactMatch, text: rule.rule.graphqlQueryName)
            }
            HStack {
                Picker(Strings.Tools.scriptStage, selection: $phase) {
                    ForEach(ScriptingPhase.allCases, id: \.self) { item in Text(item.label).tag(item) }
                }
                Spacer()
                Button(Strings.Tools.loadTemplate) { source.wrappedValue = template(phase) }
                    .disabled(!source.wrappedValue.isEmpty)
                Menu(Strings.Tools.snippet) {
                    Button(Strings.Tools.sharedstateCounter) { source.wrappedValue += "\nsharedState.count = (sharedState.count || 0) + 1;\nconsole.info(sharedState.count);" }
                    Button("Lodash / Moment") { source.wrappedValue += "\nconst _ = require('lodash');\nconst moment = require('moment');\nconsole.log(_.get(message, 'url'), moment().format());" }
                    Button("Crypto SHA-256") { source.wrappedValue += "\nconsole.log(require('crypto').createHash('sha256').update(message.body || '').digest('hex'));" }
                    Button(Strings.Tools.networkFetch) { source.wrappedValue = networkTemplate }
                    Button(Strings.Tools.asyncHook) { source.wrappedValue = "async function " + (phase == .request ? "onRequest" : phase == .response ? "onResponse" : "onWebSocket") + "(message) {\n  console.info(message.url);\n  return message;\n}" }
                }
                Button(formatting ? Strings.Tools.formatting : "Beautify") { beautify(source) }
                    .keyboardShortcut("b", modifiers: .command).disabled(formatting || source.wrappedValue.isEmpty)
            }
            if phase == .request {
                Toggle(Strings.Tools.runAsMockApiLocalResponse, isOn: Binding {
                    source.wrappedValue.hasPrefix(ScriptingRuntimeSettings.mockDirective)
                } set: { enabled in
                    if enabled {
                        if source.wrappedValue.isEmpty { source.wrappedValue = "return { status: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({mock: true}) };" }
                        if !source.wrappedValue.hasPrefix(ScriptingRuntimeSettings.mockDirective) { source.wrappedValue = ScriptingRuntimeSettings.mockDirective + source.wrappedValue }
                    } else if source.wrappedValue.hasPrefix(ScriptingRuntimeSettings.mockDirective) {
                        source.wrappedValue.removeFirst(ScriptingRuntimeSettings.mockDirective.count)
                    }
                })
                .help(Strings.Tools.returnStatusHeadersBodyOrCallMockresponseToRespond)
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
                .accessibilityLabel(Strings.Tools.scriptContentAccessibility(String(describing: phase.label)))
            Text(phase == .webSocket
                 ? Strings.Tools.readDirectionFinOpcodeBodyAndPayloadbase64ReturnAn
                 : Strings.Tools.editMessageHeadersBodyOrTheResponseStatusThe)
                .font(.caption).foregroundStyle(.secondary)
            if phase == .webSocket {
                Text(Strings.Tools.supportsPermessageDeflateCompressionOtherExtensionsAreForwardedUnchanged)
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
                    Toggle(level.localizedTitle, isOn: Binding {
                        logLevels.contains(level)
                    } set: { enabled in if enabled { logLevels.insert(level) } else { logLevels.remove(level) } })
                    .toggleStyle(.checkbox)
                }
                TextField(Strings.Tools.filterConsole, text: $logSearch).frame(maxWidth: 200)
                Spacer()
                Toggle(Strings.Tools.follow, isOn: $followConsole).toggleStyle(.checkbox)
                Button(Strings.Tools.clear) { activity.clear() }.disabled(activity.entries.isEmpty)
            }.font(.caption)
            if filteredLogs.isEmpty {
                Text(Strings.Tools.scriptMatchesLogOutputAndExceptionsAppearHere)
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
            Text(Strings.Tools.variablesAreStoredAsAJsonObjectAndAccessed)
                .font(.callout).foregroundStyle(.secondary)
            Toggle(Strings.Tools.alsoInjectSystemEnvironmentVariablesFromTheCurrentApplication, isOn: $environment.includeSystemEnvironment)
            Text(Strings.Tools.systemEnvironmentVariablesMayContainCredentialsEnableOnlyWhen)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker(Strings.Tools.totalNetworkWait, selection: $environment.networkWallTimeMilliseconds) {
                    ForEach([1000, 5000, 10_000, 15_000, 30_000], id: \.self) { Text(Strings.Tools.step1Seconds(String(describing: $0 / 1000))).tag($0) }
                }
                .onChange(of: environment.networkWallTimeMilliseconds) { value in
                    environment.networkRequestTimeoutMilliseconds = min(value, environment.networkRequestTimeoutMilliseconds)
                }
                Picker(Strings.Tools.defaultRequestTimeout, selection: $environment.networkRequestTimeoutMilliseconds) {
                    ForEach([100, 500, 1000, 3000, 5000, 10_000, 15_000, 30_000], id: \.self) { Text("\($0) ms").tag($0) }
                }
            }
            Text(Strings.Tools.networkApisConnectDirectlyToTargetServicesEachScript)
                .font(.caption).foregroundStyle(.secondary)
            CodeTextEditor(text: $environmentJSON, fontSize: 12).border(.quaternary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(Strings.Tools.resetSharedstate) {
                    DispatchQueue.global(qos: .userInitiated).async {
                        ScriptingRuntimeSettings.resetSharedState()
                        DispatchQueue.main.async { activity.record(url: "", lines: [Strings.Tools.infoSharedstateReset]) }
                    }
                }
                Spacer()
                Button(Strings.Tools.saveEnvironmentNetworkSettings) {
                    do {
                        guard let data = environmentJSON.data(using: .utf8),
                              let values = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                            error = Strings.Tools.enterAJsonObjectWithStringKeysAndString; return
                        }
                        environment.variables = values
                        try ScriptingRuntimeSettings.save(environment)
                        error = nil
                    } catch { self.error = LocalizedErrorPresentation.message(for: error) }
                }
            }
        }
    }

    private var apiHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Strings.Tools.scriptingApi).font(.title2)
            ScrollView {
                Text(Strings.Tools.scriptingApiHelp).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(Strings.Tools.done) { showAPIHelp = false }.keyboardShortcut(.defaultAction) }
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
        else { target = Strings.Tools.firstUseQueryFlowsToFindTheRequestTo }
        return Strings.Tools.scriptingMcpTaskTemplate(String(describing: target), String(describing: phase.label))
    }

    private var mcpHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Tools.generateScriptsWithProxymirrorMcp).font(.title2)
            Text(Strings.Tools.startProxymirrorThenAddTheStdioConfigurationBelowTo)
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
                Button(Strings.Tools.copyStdioConfiguration) { CopyPaste.copy(configText) }
                Button(Strings.Tools.viewHttpConnectionConfiguration) {
                    showMCPHelp = false
                    DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("ProxyMirror.showMCPConfiguration"), object: nil) }
                }
                Button(Strings.Tools.copyTaskTemplate) { CopyPaste.copy(mcpTaskTemplate) }
                Spacer()
                Button(Strings.Tools.done) { showMCPHelp = false }.keyboardShortcut(.defaultAction)
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
                case .failure(let failure): error = LocalizedErrorPresentation.message(for: failure)
                }
            }
        }
    }

    private func appendGroup() {
        let group = RewriteRuleSet(name: Strings.Tools.group2(Int(groups.count + 1)))
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
                    error = Strings.Tools.theUrlRegularExpressionIsInvalid
                    groupID = candidate[group].id
                    ruleID = rule.id
                    return
                }
                for action in rule.actions {
                    if case .script(_, let source) = action, source.utf8.count > ScriptingService.sourceLimit {
                        error = Strings.Tools.anIndividualScriptExceeds256Kib
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
            error = Strings.Tools.theRulesHaveChangedReopenThisWindowBeforeEditing
            return
        }
        backup.rewrite = candidate
        do { try RulesStore.shared.install(backup) }
        catch { self.error = Strings.Tools.unableToSaveScriptRules1(String(describing: LocalizedErrorPresentation.message(for: error))); return }
        groups = candidate
        savedGroups = candidate
        error = nil
    }
}
