import SwiftUI

struct CustomizeTrafficColumnsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CustomTrafficColumn.defaultsKey) private var stored = Data()
    @AppStorage("ui.hiddenTrafficColumns") private var hidden = ""
    @AppStorage("ui.trafficColumnWidths") private var widths = ""
    @State private var columns: [CustomTrafficColumn] = []
    @State private var hiddenIDs: Set<String> = []
    @State private var resetWidth = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义流量列").font(.headline)
            Text("内置列").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 8) {
                ForEach(TrafficColumn.allCases.filter { $0 != .url }) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { !hiddenIDs.contains(column.id) },
                        set: { if $0 { hiddenIDs.remove(column.id) } else { hiddenIDs.insert(column.id) } }))
                }
            }
            Divider()
            HStack {
                Text("自定义列").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("新增列", systemImage: "plus") { columns.append(CustomTrafficColumn()) }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($columns) { $column in
                        HStack {
                            TextField("列名", text: $column.title).frame(width: 110)
                            Picker("来源", selection: $column.source) {
                                ForEach(CustomTrafficColumn.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().frame(width: 105)
                            TextField("字段名或键路径", text: $column.key)
                            Button(role: .destructive) {
                                let id = column.id
                                columns.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("删除列")
                        }
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 200)
            Text("JSON 键路径示例 items.0.id。从解码后不超过 128 KiB 的正文取值；压缩正文需完整捕获。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("恢复默认列宽") { resetWidth = true }.disabled(resetWidth)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let encoded = try? JSONEncoder().encode(columns) else { return }
                    stored = encoded
                    hidden = hiddenIDs.sorted().joined(separator: "|")
                    if resetWidth { widths = "" }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(columns.contains {
                    $0.title.trimmingCharacters(in: .whitespaces).isEmpty || $0.key.trimmingCharacters(in: .whitespaces).isEmpty
                })
            }
        }
        .padding(18)
        .frame(width: 600)
        .onAppear {
            columns = (try? JSONDecoder().decode([CustomTrafficColumn].self, from: stored)) ?? []
            hiddenIDs = Set(hidden.split(separator: "|").map(String.init))
        }
    }
}
