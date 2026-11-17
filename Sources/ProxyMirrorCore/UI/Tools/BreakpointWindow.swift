import SwiftUI

struct BreakpointOpening: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .pmBreakpointHit)) { _ in
            openWindow(id: "breakpoints")
        }
    }
}

struct BreakpointMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("断点队列与规则…") { openWindow(id: "breakpoints") }
    }
}

struct BreakpointWindow: View {
    @ObservedObject private var manager = BreakpointManager.shared
    @State private var tab = 0
    @State private var selected: UUID?
    @State private var draft = ""
    @State private var error: String?

    private var active: BreakpointManager.HeldItem? {
        manager.held.first { $0.id == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("断点", selection: $tab) {
                    Text("待处理 (\(manager.held.count))").tag(0)
                    Text("规则").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)

                Spacer()
                Toggle("自动打开窗口", isOn: $manager.autoBringToFront)
                Toggle("启用断点", isOn: $manager.enabled)
            }
            if tab == 0 { queue } else { BreakpointRuleEditor() }
        }
        .padding(14)
        .frame(minWidth: 730, minHeight: 460)
        .onAppear { refreshSelection() }
        .onChange(of: manager.held.map(\.id)) { _ in refreshSelection() }
        .onChange(of: selected) { _ in
            draft = active?.message.text ?? ""
            error = nil
        }
    }

    private var queue: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(manager.held) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.phase == .request ? "请求" : "响应")
                            .font(.caption.weight(.semibold))
                        Text(item.summary).lineLimit(2)
                        Text(item.rule).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .tag(item.id)
                }
            }
            .frame(minWidth: 220, idealWidth: 270)
            if let item = active {
                messageEditor(item)
                    .frame(minWidth: 420)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "pause.circle").font(.title2)
                    Text("没有等待处理的断点")
                    Button("查看规则") { tab = 1 }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: manager.held.first?.id) { id in if id != nil { tab = 0 } }
    }

    private func messageEditor(_ item: BreakpointManager.HeldItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.summary).font(.headline).lineLimit(2).textSelection(.enabled)
                Spacer()
                Text(item.deadline, style: .timer).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("\(item.source)  ·  \(item.rule)").font(.caption).foregroundStyle(.secondary)
            Text(item.message.body == nil
                 ? "可编辑头部，原正文随报文继续传输。"
                 : "可编辑头部和正文。用空行分隔，Content-Length 会随正文更新。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .border(.quaternary)
                .accessibilityLabel("断点报文")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消此条", role: .destructive) { manager.drop(item) }
                Spacer()
                Button("还原编辑") { draft = item.message.text; error = nil }
                    .disabled(draft == item.message.text)
                Button("原样继续") { manager.continueOriginal(item) }
                Button("应用并继续") {
                    do { try manager.applyAndExecute(item, draft: draft) }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    private func refreshSelection() {
        if active == nil { selected = manager.held.first?.id }
        if manager.held.isEmpty { draft = ""; error = nil }
    }
}

private struct BreakpointRuleEditor: View {
    @State private var rules = InterceptionConfig.shared.breakpoints.value
    @State private var selected: UUID?
    @State private var error: String?
    @State private var dirty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按原始请求的主机和路径匹配。请求和响应可各设一条规则。")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(selection: $selected) {
                    ForEach(rules) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.rule.name.isEmpty ? rule.rule.summary : rule.rule.name).lineLimit(1)
                            Text("\(rule.phase == .request ? "请求" : "响应") · \(rule.enabled ? "启用" : "关闭")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(rule.id)
                    }
                }
                .frame(minWidth: 220, idealWidth: 270)
                if let id = selected, let index = rules.firstIndex(where: { $0.id == id }) {
                    fields($rules[index])
                        .id(id)
                        .frame(minWidth: 350, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text("添加规则或选择已有规则")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("添加规则") {
                    let rule = BreakpointRule(enabled: false)
                    rules.append(rule)
                    selected = rule.id
                }
                Button("移除所选") {
                    rules.removeAll { $0.id == selected }
                    selected = nil
                }
                .disabled(selected == nil)
                Spacer()
                Button("还原") { rules = InterceptionConfig.shared.breakpoints.value; error = nil; dirty = false }
                    .disabled(!dirty)
                Button("保存规则") { save() }.disabled(!dirty)
            }
        }
        .onChange(of: rules) { _ in dirty = rules != InterceptionConfig.shared.breakpoints.value }
    }

    private func fields(_ rule: Binding<BreakpointRule>) -> some View {
        Form {
            Toggle("启用此规则", isOn: rule.enabled)
            TextField("名称", text: rule.rule.name)
            Picker("暂停阶段", selection: rule.phase) {
                Text("请求").tag(BreakpointRule.Phase.request)
                Text("响应").tag(BreakpointRule.Phase.response)
            }
            TextField("方法（ANY / GET / POST）", text: rule.rule.method)
            TextField("协议（ANY / http / https）", text: rule.rule.scheme)
            Picker("匹配方式", selection: rule.rule.matchMode) {
                Text("通配符").tag(URLRule.MatchMode.wildcard)
                Text("文本").tag(URLRule.MatchMode.plain)
                Text("完整 URL 正则").tag(URLRule.MatchMode.regex)
            }
            if rule.wrappedValue.rule.matchMode == .regex {
                TextField("正则表达式", text: rule.rule.regexPattern)
            } else {
                TextField("主机（留空匹配所有）", text: rule.rule.host)
                TextField("路径（* 匹配所有）", text: rule.rule.path)
                TextField("查询字符串包含", text: rule.rule.query)
                Toggle("包含子路径", isOn: rule.rule.includeSubpaths)
            }
        }
        .padding(10)
    }

    private func save() {
        var updated = rules
        for index in updated.indices {
            var rule = updated[index].rule
            rule.method = rule.method.trimmingCharacters(in: .whitespaces).uppercased()
            rule.scheme = rule.scheme.trimmingCharacters(in: .whitespaces)
            rule.scheme = rule.scheme.isEmpty || rule.scheme.uppercased() == "ANY" ? "ANY" : rule.scheme.lowercased()
            rule.host = rule.host.trimmingCharacters(in: .whitespaces)
            if rule.method.isEmpty { rule.method = "ANY" }
            if rule.path.isEmpty { rule.path = "*" }
            if rule.matchMode == .regex && (rule.regexPattern.isEmpty || URLRule.regexCache(rule.regexPattern) == nil) {
                error = "请填写有效的 URL 正则表达式"
                selected = updated[index].id
                return
            }
            updated[index].rule = rule
        }
        let store = RulesStore.shared
        var backup = store.backup()
        backup.breakpoints = updated
        do {
            try store.install(backup)
        } catch let failure {
            error = failure.localizedDescription
            return
        }
        rules = updated
        dirty = false
        error = nil
    }
}
