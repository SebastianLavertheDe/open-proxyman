import SwiftUI

struct TrafficFilterEditor: View {
    @ObservedObject var store: TrafficStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SavedTrafficFilter.defaultsKey) private var stored = Data()
    @State private var draft = TrafficConditionGroup()
    @State private var name = ""
    @State private var highlight = ""
    @State private var search = ""
    @State private var selectedProfile: UUID?
    @State private var selectedCondition: UUID?
    @State private var navigateProfiles = false
    @State private var feedback: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var conditionFocused: UUID?

    private var profiles: [SavedTrafficFilter] { (try? JSONDecoder().decode([SavedTrafficFilter].self, from: stored)) ?? [] }
    private var visibleProfiles: [SavedTrafficFilter] {
        profiles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var valid: Bool { draft.isValid }
    private var profileName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var conditionIDs: [UUID] { visibleIDs(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("高级过滤").font(.headline)
                TextField("搜索预设 / 条件（⌘F）", text: $search).focused($searchFocused)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                actions
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("命名预设 · ⌘↑ / ⌘↓ 选择").font(.caption).foregroundStyle(.secondary)
                    List {
                        ForEach(visibleProfiles) { profile in
                            Button { load(profile) } label: {
                                HStack {
                                    Circle().fill(profile.highlightName.map(ProxymanTheme.highlightColor) ?? .clear)
                                        .frame(width: 9, height: 9)
                                    Text(profile.name).lineLimit(2)
                                    Spacer()
                                }.padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .listRowBackground(selectedProfile == profile.id ? Color.accentColor.opacity(0.15) : .clear)
                        }
                    }
                    HStack {
                        Button("新预设") { selectedProfile = nil; name = ""; draft = TrafficConditionGroup(); highlight = ""; selectedCondition = nil }
                        Button("删除") { if let selectedProfile { write(profiles.filter { $0.id != selectedProfile }); self.selectedProfile = nil } }
                            .disabled(selectedProfile == nil)
                    }
                }.frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                conditionPanel
            }
            footer
        }
        .padding(18).frame(width: 1020, height: 570)
        .background(TrafficFilterKeyHandler(action: handle).frame(width: 0, height: 0))
        .onAppear { draft = store.filter.conditions }
        .onChange(of: conditionFocused) { value in
            if let value { selectedCondition = value; navigateProfiles = false }
        }
    }

    private var conditionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("匹配方式", selection: $draft.mode) {
                ForEach(TrafficConditionGroup.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    TrafficConditionGroupEditor(group: $draft, depth: 0, query: search,
                        selected: $selectedCondition, focus: $conditionFocused)
                }
                .onChange(of: selectedCondition) { id in if let id { navigateProfiles = false; scroll.scrollTo(id, anchor: .center) } }
            }.frame(minHeight: 160)
            Text("正文条件检查解码后前 1 MiB。⌘N 新增条件，⇧⌘N 新增 AND/OR 子组；⌘↑↓ 在当前条件或预设中导航。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("匹配时着色", selection: $highlight) {
                Text("停用着色").tag("")
                ForEach(ProxymanTheme.highlightNames, id: \.self) { Text($0).tag($0) }
            }
            Text("⌘B 启用 / 停用选中预设着色；预设按列表顺序生效，手动高亮优先。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.leading, 10).frame(minWidth: 680)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                TextField("过滤器名称", text: $name)
                Button("保存预设") { saveProfile() }.disabled(!valid || draft.isEmpty || profileName.isEmpty)
                Spacer()
                Button("取消（Esc）") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { store.filter.conditions = draft; dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
    }

    private var actions: some View {
        Menu("面板操作") {
            Button("新增条件  ⌘N") { handle(.addCondition) }
            Button("新增 AND/OR 子组  ⇧⌘N") { handle(.addGroup) }
            Divider()
            Button("上一" + (navigateProfiles ? "预设" : "条件") + "  ⌘↑") { handle(.previous) }
            Button("下一" + (navigateProfiles ? "预设" : "条件") + "  ⌘↓") { handle(.next) }
            Button("切换选中预设着色  ⌘B") { handle(.toggleColor) }.disabled(selectedProfile == nil)
            Button("搜索面板  ⌘F") { handle(.search) }
            Divider()
            Button("取消  Esc") { dismiss() }
        }.fixedSize()
    }

    private func handle(_ command: TrafficFilterShortcut) {
        switch command {
        case .cancel: dismiss()
        case .search: searchFocused = true
        case .addCondition:
            let condition = TrafficCondition()
            search = ""; draft.conditions.append(condition)
            selectedCondition = condition.id; conditionFocused = condition.id; navigateProfiles = false
        case .addGroup:
            let condition = TrafficCondition()
            search = ""
            if draft.groups == nil { draft.groups = [] }
            draft.groups?.append(TrafficConditionGroup(conditions: [condition]))
            selectedCondition = condition.id; conditionFocused = condition.id; navigateProfiles = false
        case .previous, .next:
            let delta = command == .previous ? -1 : 1
            if navigateProfiles {
                if let index = TrafficFilterShortcut.nextIndex(current: visibleProfiles.firstIndex { $0.id == selectedProfile }, count: visibleProfiles.count, delta: delta) {
                    load(visibleProfiles[index])
                }
            } else if let index = TrafficFilterShortcut.nextIndex(current: selectedCondition.flatMap { conditionIDs.firstIndex(of: $0) }, count: conditionIDs.count, delta: delta) {
                selectedCondition = conditionIDs[index]; conditionFocused = conditionIDs[index]
            }
        case .toggleColor:
            guard let id = selectedProfile, let index = profiles.firstIndex(where: { $0.id == id }) else { feedback = "请先选择或保存一个预设。"; return }
            var next = profiles
            next[index].highlightName = next[index].highlightName == nil ? (highlight.isEmpty ? "Yellow" : highlight) : nil
            highlight = next[index].highlightName ?? ""
            write(next)
            feedback = next[index].highlightName == nil ? "已停用选中预设着色。" : "已启用选中预设着色。"
        }
    }

    private func load(_ profile: SavedTrafficFilter) {
        selectedProfile = profile.id; name = profile.name; draft = profile.group; highlight = profile.highlightName ?? ""
        selectedCondition = nil; conditionFocused = nil; navigateProfiles = true; feedback = nil
    }
    private func saveProfile() {
        let id = selectedProfile ?? profiles.first { $0.name == profileName }?.id ?? UUID()
        let profile = SavedTrafficFilter(id: id, name: profileName, group: draft, highlightName: highlight.isEmpty ? nil : highlight)
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == id }) { next[index] = profile } else { next.append(profile) }
        write(next); selectedProfile = id; feedback = "预设已保存。"
    }
    private func write(_ profiles: [SavedTrafficFilter]) {
        if let encoded = try? JSONEncoder().encode(profiles) { stored = encoded }
    }
    private func visibleIDs(_ group: TrafficConditionGroup) -> [UUID] {
        group.conditions.filter { TrafficConditionGroupEditor.matches($0, query: search) }.map(\.id)
            + (group.groups ?? []).flatMap { visibleIDs($0) }
    }
}

private struct TrafficConditionGroupEditor: View {
    @Binding var group: TrafficConditionGroup
    let depth: Int
    let query: String
    @Binding var selected: UUID?
    let focus: FocusState<UUID?>.Binding

    static func matches(_ condition: TrafficCondition, query: String) -> Bool {
        query.isEmpty || "\(condition.field.rawValue) \(condition.comparison.rawValue) \(condition.value)".localizedCaseInsensitiveContains(query)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($group.conditions) { $condition in
                if Self.matches(condition, query: query) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Picker("字段", selection: $condition.field) {
                                ForEach(TrafficCondition.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 130)
                            Picker("条件", selection: $condition.comparison) {
                                ForEach(TrafficCondition.Comparison.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 94)
                            TextField(condition.comparison == .between ? "最小值...最大值" : "匹配值", text: $condition.value)
                                .focused(focus, equals: condition.id)
                            Button {
                                let id = condition.id; group.conditions.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("删除条件")
                        }
                        if !condition.value.isEmpty && !condition.isValid {
                            Text("条件无效：数值字段与区间须有效（10...100），正则必须有效。")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }.padding(4).id(condition.id)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected == condition.id ? Color.accentColor : .clear))
                        .simultaneousGesture(TapGesture().onEnded { selected = condition.id })
                }
            }
            ForEach(Array((group.groups ?? []).indices), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("子组", selection: subgroup(index).mode) {
                            ForEach(TrafficConditionGroup.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Spacer()
                        Button("删除子组") { group.groups?.remove(at: index) }.buttonStyle(.borderless)
                    }
                    AnyView(TrafficConditionGroupEditor(group: subgroup(index), depth: depth + 1, query: query, selected: $selected, focus: focus))
                }.padding(8).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("添加条件") {
                    let condition = TrafficCondition(); group.conditions.append(condition); selected = condition.id; focus.wrappedValue = condition.id
                }
                if depth < 3 {
                    Button("添加 AND/OR 子组") {
                        let condition = TrafficCondition()
                        if group.groups == nil { group.groups = [] }
                        group.groups?.append(TrafficConditionGroup(conditions: [condition])); selected = condition.id; focus.wrappedValue = condition.id
                    }
                }
            }
        }
    }
    private func subgroup(_ index: Int) -> Binding<TrafficConditionGroup> {
        Binding(get: {
            guard let groups = group.groups, groups.indices.contains(index) else { return TrafficConditionGroup() }
            return groups[index]
        }, set: { value in
            guard group.groups?.indices.contains(index) == true else { return }
            group.groups?[index] = value
        })
    }
}
