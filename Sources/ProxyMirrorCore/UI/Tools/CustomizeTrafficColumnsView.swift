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
            Text(Strings.Tools.customTrafficColumns).font(.headline)
            Text(Strings.Tools.builtInColumns).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 8) {
                ForEach(TrafficColumn.allCases.filter { $0 != .url }) { column in
                    Toggle(column.localizedTitle(), isOn: Binding(
                        get: { !hiddenIDs.contains(column.id) },
                        set: { if $0 { hiddenIDs.remove(column.id) } else { hiddenIDs.insert(column.id) } }))
                }
            }
            Divider()
            HStack {
                Text(Strings.Tools.customColumns).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(Strings.Tools.addColumn, systemImage: "plus") { columns.append(CustomTrafficColumn()) }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($columns) { $column in
                        HStack {
                            TextField(Strings.Tools.columnName, text: $column.title).frame(width: 110)
                            Picker(Strings.Tools.source, selection: $column.source) {
                                ForEach(CustomTrafficColumn.Source.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                            }
                            .labelsHidden().frame(width: 105)
                            TextField(Strings.Tools.fieldNameOrKeyPath, text: $column.key)
                            Button(role: .destructive) {
                                let id = column.id
                                columns.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel(Strings.Tools.deleteColumn)
                        }
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 200)
            Text(Strings.Tools.exampleJsonKeyPathItems0IdValuesAre)
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(Strings.Tools.resetColumnWidths) { resetWidth = true }.disabled(resetWidth)
                Spacer()
                Button(Strings.Tools.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Tools.save) {
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
