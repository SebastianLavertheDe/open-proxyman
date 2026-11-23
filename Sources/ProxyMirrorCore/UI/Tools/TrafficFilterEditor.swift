import SwiftUI

struct TrafficFilterEditor: View {
    @ObservedObject var store: TrafficStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SavedTrafficFilter.defaultsKey) private var stored = Data()
    @State private var draft = TrafficConditionGroup()
    @State private var name = ""
    @State private var highlight = ""

    private var profiles: [SavedTrafficFilter] {
        (try? JSONDecoder().decode([SavedTrafficFilter].self, from: stored)) ?? []
    }

    private var valid: Bool { draft.isValid }
    private var profileName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("高级过滤").font(.headline)
            HStack {
                Picker("匹配方式", selection: $draft.mode) {
                    ForEach(TrafficConditionGroup.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Spacer()
                Menu("已保存的过滤器") {
                    ForEach(profiles) { profile in
                        Button(profile.name) { name = profile.name; draft = profile.group; highlight = profile.highlightName ?? "" }
                    }
                    if !profiles.isEmpty {
                        Divider()
                        Menu("删除过滤器") {
                            ForEach(profiles) { profile in
                                Button(profile.name) { write(profiles.filter { $0.id != profile.id }) }
                            }
                        }
                    }
                }
                .disabled(profiles.isEmpty)
            }
            ScrollView {
                TrafficConditionGroupEditor(group: $draft, depth: 0)
            }
            .frame(minHeight: 110, maxHeight: 340)
            Text("正文条件检查解码后内容的前 1 MiB；压缩正文需完整捕获。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("匹配时着色", selection: $highlight) {
                Text("无（仅保存过滤条件）").tag("")
                ForEach(ProxymanTheme.highlightNames, id: \.self) { Text($0).tag($0) }
            }
            Text("已保存的着色过滤器按列表顺序生效，手动高亮优先；不会更改会话中的标记。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                TextField("过滤器名称", text: $name)
                Button("保存过滤器") {
                    let id = profiles.first { $0.name == profileName }?.id ?? UUID()
                    let profile = SavedTrafficFilter(id: id, name: profileName, group: draft, highlightName: highlight.isEmpty ? nil : highlight)
                    write(profiles.filter { $0.id != id } + [profile])
                }
                .disabled(!valid || draft.isEmpty || profileName.isEmpty)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") {
                    store.filter.conditions = draft
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(18)
        .frame(width: 780)
        .onAppear { draft = store.filter.conditions }
    }

    private func write(_ profiles: [SavedTrafficFilter]) {
        if let encoded = try? JSONEncoder().encode(profiles) { stored = encoded }
    }
}

private struct TrafficConditionGroupEditor: View {
    @Binding var group: TrafficConditionGroup
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($group.conditions) { $condition in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Picker("字段", selection: $condition.field) {
                            ForEach(TrafficCondition.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 150)
                        Picker("条件", selection: $condition.comparison) {
                            ForEach(TrafficCondition.Comparison.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 100)
                        TextField(condition.comparison == .between ? "最小值...最大值" : "匹配值", text: $condition.value)
                        Button {
                            let id = condition.id
                            group.conditions.removeAll { $0.id == id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("删除条件")
                    }
                    if !condition.value.isEmpty && !condition.isValid {
                        Text("条件无效：数值比较需选择数值字段，区间格式为 10...100；正则必须有效。")
                            .font(.caption).foregroundStyle(.red)
                    }
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
                    AnyView(TrafficConditionGroupEditor(group: subgroup(index), depth: depth + 1))
                }
                .padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("添加条件", systemImage: "plus") { group.conditions.append(TrafficCondition()) }
                if depth < 3 {
                    Button("添加 AND/OR 子组", systemImage: "rectangle.3.group") {
                        if group.groups == nil { group.groups = [] }
                        group.groups?.append(TrafficConditionGroup(conditions: [TrafficCondition()]))
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
