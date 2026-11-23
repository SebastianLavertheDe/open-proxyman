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
        Button(Strings.Tools.breakpointQueueRules) { openWindow(id: "breakpoints") }
    }
}

struct BreakpointWindow: View {
    @ObservedObject private var manager = BreakpointManager.shared
    @State private var tab = 0
    @State private var selected: UUID?
    @State private var draft = ""
    @State private var error: String?
    @ObservedObject private var templates = BreakpointTemplateStore.shared

    private var active: BreakpointManager.HeldItem? {
        manager.held.first { $0.id == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(Strings.Tools.breakpoints, selection: $tab) {
                    Text(Strings.Tools.pending(Int(manager.held.count))).tag(0)
                    Text(Strings.Tools.rules).tag(1)
                    Text(Strings.Tools.template).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)

                Spacer()
                Toggle(Strings.Tools.openWindowAutomatically, isOn: $manager.autoBringToFront)
                Toggle(Strings.Tools.enableBreakpoints, isOn: $manager.enabled)
            }
            if tab == 0 { queue }
            else if tab == 1 { BreakpointRuleEditor() }
            else { templateLibrary }
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
                        Text(item.phase == .request ? Strings.Tools.request : Strings.Tools.response)
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
                    Text(Strings.Tools.noPendingBreakpoints)
                    Button(Strings.Tools.viewRules) { tab = 1 }
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
                 ? Strings.Tools.editTheHeadersTheOriginalBodyIsForwardedWith
                 : Strings.Tools.editTheHeadersAndBodySeparatedByABlank)
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .border(.quaternary)
                .accessibilityLabel(Strings.Tools.breakpointMessage)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(Strings.Tools.cancelThisRequest, role: .destructive) { manager.drop(item) }
                Menu(Strings.Tools.applyTemplate) {
                    ForEach(templates.templates.filter { $0.phase == item.phase }) { template in
                        Button(template.name) {
                            do { draft = try template.draft(for: item.message, phase: item.phase); error = nil }
                            catch { self.error = LocalizedErrorPresentation.message(for: error) }
                        }
                    }
                }.disabled(!templates.templates.contains { $0.phase == item.phase })
                Button(Strings.Tools.saveAsTemplate) { saveTemplate(item) }
                Spacer()
                Button(Strings.Tools.revertEdits) { draft = item.message.text; error = nil }
                    .disabled(draft == item.message.text)
                Button(Strings.Tools.continueUnchanged) { manager.continueOriginal(item) }
                Button(Strings.Tools.applyContinue) {
                    do { try manager.applyAndExecute(item, draft: draft) }
                    catch { self.error = LocalizedErrorPresentation.message(for: error) }
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

    private var templateLibrary: some View {
        List {
            ForEach(templates.templates) { template in
                HStack {
                    VStack(alignment: .leading) {
                        Text(template.name)
                        Text(Strings.Tools.breakpointTemplateSummary(String(describing: template.phase.localizedTitle), Int(template.headers.count), Int(template.body?.count ?? 0)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(Strings.Tools.rename) {
                        let panel = NSAlert(); panel.messageText = Strings.Tools.renameTemplate
                        let field = NSTextField(string: template.name); panel.accessoryView = field
                        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
                        panel.addButton(withTitle: Strings.Tools.save); panel.addButton(withTitle: Strings.Tools.cancel)
                        if panel.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            var updated = template; updated.name = field.stringValue
                            do { try templates.save(updated) } catch { self.error = LocalizedErrorPresentation.message(for: error) }
                        }
                    }
                    Button(Strings.Tools.delete, role: .destructive) {
                        do { try templates.remove(template.id) } catch { self.error = LocalizedErrorPresentation.message(for: error) }
                    }
                }
            }
            if templates.templates.isEmpty { Text(Strings.Tools.editAPendingBreakpointMessageThenClickSaveAs).foregroundStyle(.secondary) }
        }
        .overlay(alignment: .bottom) { if let error { Text(error).foregroundStyle(.red).padding() } }
    }

    private func saveTemplate(_ item: BreakpointManager.HeldItem) {
        do {
            let edited = try item.message.applying(draft)
            let panel = NSAlert(); panel.messageText = Strings.Tools.saveBreakpointTemplate
            let field = NSTextField(string: item.rule); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            panel.accessoryView = field
            panel.addButton(withTitle: Strings.Tools.save); panel.addButton(withTitle: Strings.Tools.cancel)
            guard panel.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw BreakpointMessage.InvalidEdit(Strings.Tools.enterATemplateName) }
            try templates.save(.capture(name: name, phase: item.phase, message: edited))
            error = nil
        } catch { self.error = LocalizedErrorPresentation.message(for: error) }
    }
}

private struct BreakpointRuleEditor: View {
    @State private var rules = InterceptionConfig.shared.breakpoints.value
    @State private var selected: UUID?
    @State private var error: String?
    @State private var folderDraft = RuleFolderEditingDraft()
    private var dirty: Bool { rules != InterceptionConfig.shared.breakpoints.value || folderDraft.hasChanges }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Strings.Tools.matchTheOriginalRequestSHostAndPathA)
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(selection: $selected) {
                    ForEach(rules) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.rule.name.isEmpty ? rule.rule.summary : rule.rule.name).lineLimit(1)
                            Text(Strings.Tools.rulePhaseStatus(rule.phase.localizedTitle, rule.enabled ? Strings.Tools.stateEnabled : Strings.Tools.stateDisabled))
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
                    Text(Strings.Tools.addARuleOrSelectAnExistingRule)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(Strings.Tools.addRule) {
                    let rule = BreakpointRule(enabled: false)
                    rules.append(rule)
                    selected = rule.id
                }
                Button(Strings.Tools.removeSelected) {
                    rules.removeAll { $0.id == selected }
                    selected = nil
                }
                .disabled(selected == nil)
                Spacer()
                Button(Strings.Tools.revert) { rules = InterceptionConfig.shared.breakpoints.value; folderDraft = RuleFolderEditingDraft(); error = nil }
                    .disabled(!dirty)
                Button(Strings.Tools.saveRule) { save() }.disabled(!dirty)
            }
        }
    }

    private func fields(_ rule: Binding<BreakpointRule>) -> some View {
        Form {
            Toggle(Strings.Tools.enableThisRule, isOn: rule.enabled)
            TextField(Strings.Tools.name, text: rule.rule.name)
            RuleFolderPicker(tool: "breakpoints", ruleID: rule.wrappedValue.id.uuidString, draft: $folderDraft)
            Picker(Strings.Tools.pausePhase, selection: rule.phase) {
                Text(Strings.Tools.request).tag(BreakpointRule.Phase.request)
                Text(Strings.Tools.response).tag(BreakpointRule.Phase.response)
            }
            TextField(Strings.Tools.methodAnyGetPost, text: rule.rule.method)
            TextField(Strings.Tools.schemeAnyHttpHttps, text: rule.rule.scheme)
            Picker(Strings.Tools.matchType, selection: rule.rule.matchMode) {
                Text(Strings.Tools.wildcard).tag(URLRule.MatchMode.wildcard)
                Text(Strings.Tools.text).tag(URLRule.MatchMode.plain)
                Text(Strings.Tools.fullUrlRegularExpression).tag(URLRule.MatchMode.regex)
            }
            if rule.wrappedValue.rule.matchMode == .regex {
                TextField(Strings.Tools.regularExpression, text: rule.rule.regexPattern)
            } else {
                TextField(Strings.Tools.hostLeaveEmptyToMatchAll, text: rule.rule.host)
                TextField(Strings.Tools.pathMatchesAll, text: rule.rule.path)
                TextField(Strings.Tools.queryStringContains, text: rule.rule.query)
                Toggle(Strings.Tools.includeSubpaths, isOn: rule.rule.includeSubpaths)
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
                error = Strings.Tools.enterAValidUrlRegularExpression
                selected = updated[index].id
                return
            }
            updated[index].rule = rule
        }
        let store = RulesStore.shared
        var backup = store.backup()
        backup.breakpoints = updated
        do {
            backup.organization = try folderDraft.merging(into: backup.organization ?? RuleOrganizationStore.shared.snapshot(), tool: "breakpoints", keeping: Set(updated.map { $0.id.uuidString }))
            try store.install(backup)
        } catch let failure {
            error = LocalizedErrorPresentation.message(for: failure)
            return
        }
        rules = updated
        folderDraft = RuleFolderEditingDraft()
        error = nil
    }
}
