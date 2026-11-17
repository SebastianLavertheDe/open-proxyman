import SwiftUI

struct TrafficFilterEditor: View {
    @ObservedObject var store: TrafficStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SavedTrafficFilter.defaultsKey) private var stored = Data()
    @State private var draft = TrafficConditionGroup()
    @State private var name = ""

    private var profiles: [SavedTrafficFilter] {
        (try? JSONDecoder().decode([SavedTrafficFilter].self, from: stored)) ?? []
    }

    private var valid: Bool { draft.conditions.allSatisfy(\.isValid) }
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
                        Button(profile.name) { name = profile.name; draft = profile.group }
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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($draft.conditions) { $condition in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Picker("字段", selection: $condition.field) {
                                    ForEach(TrafficCondition.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden().frame(width: 124)
                                Picker("条件", selection: $condition.comparison) {
                                    ForEach(TrafficCondition.Comparison.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden().frame(width: 85)
                                TextField("匹配值", text: $condition.value)
                                Button {
                                    let id = condition.id
                                    draft.conditions.removeAll { $0.id == id }
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("删除条件")
                            }
                            if !condition.value.isEmpty && !condition.isValid {
                                Text(condition.comparison == .regex ? "无效的正则表达式" : "至少需要数值字段和有效数字")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    Button("添加条件", systemImage: "plus") { draft.conditions.append(TrafficCondition()) }
                }
            }
            .frame(minHeight: 110, maxHeight: 280)
            Text("正文条件检查捕获内容的前 1 MiB")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                TextField("过滤器名称", text: $name)
                Button("保存过滤器") {
                    let id = profiles.first { $0.name == profileName }?.id ?? UUID()
                    let profile = SavedTrafficFilter(id: id, name: profileName, group: draft)
                    write(profiles.filter { $0.id != id } + [profile])
                }
                .disabled(!valid || draft.conditions.isEmpty || profileName.isEmpty)
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
        .frame(width: 610)
        .onAppear { draft = store.filter.conditions }
    }

    private func write(_ profiles: [SavedTrafficFilter]) {
        if let encoded = try? JSONEncoder().encode(profiles) { stored = encoded }
    }
}
