import SwiftUI

struct ScriptingMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("脚本与执行日志…") { openWindow(id: "scripting") }
    }
}

struct ScriptingWindow: View {
    @ObservedObject private var activity = ScriptingActivity.shared
    @State private var tab = 0
    @State private var groups = InterceptionConfig.shared.rewrite.value
    @State private var savedGroups = InterceptionConfig.shared.rewrite.value
    @State private var groupID: UUID?
    @State private var ruleID: UUID?
    @State private var phase = ScriptingPhase.request
    @State private var error: String?

    private var selectedGroup: Int? { groups.firstIndex { $0.id == groupID } }
    private var selectedRule: Int? {
        selectedGroup.flatMap { group in groups[group].rules.firstIndex { $0.id == ruleID } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("脚本", selection: $tab) {
                    Text("脚本规则").tag(0)
                    Text("执行日志").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                if tab == 1 {
                    Button("清空日志") { activity.clear() }.disabled(activity.entries.isEmpty)
                }
            }
            if tab == 0 { rules } else { logs }
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 500)
        .onAppear { acceptPrefill() }
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
            }
            ForEach(rule.actions.wrappedValue.filter { action in
                switch (phase, action) {
                case (.request, .requestHeader), (.response, .responseHeader): return true
                default: return false
                }
            }, id: \.self) { action in
                Text(action.summary).font(.caption).textSelection(.enabled)
            }
            TextEditor(text: source)
                .font(.system(.body, design: .monospaced))
                .border(.quaternary)
                .accessibilityLabel("\(phase.label)脚本内容")
            Text(phase == .webSocket
                 ? "可读取 direction、fin、opcode、body 和 payloadBase64。返回 action 为 pass、modify、drop 或 close。"
                 : "编辑 message.headers、body 或响应的 status。UTF-8 定长正文上限 256 KiB。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }

    private var logs: some View {
        Group {
            if activity.entries.isEmpty {
                Text("脚本命中、输出和异常会显示在这里")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(activity.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(entry.url)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
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
                        error = "单个脚本超过 16 KiB"
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
