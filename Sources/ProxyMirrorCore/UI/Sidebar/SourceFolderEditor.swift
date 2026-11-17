import SwiftUI

struct SourceFolderEditor: View {
    @ObservedObject var store: TrafficStore
    @Environment(\.dismiss) private var dismiss
    private let folderID: UUID?
    @State private var name: String
    @State private var selected: Set<SourceFolderMember>
    @State private var search = ""
    @State private var error: String?

    init(store: TrafficStore, folder: SourceFolder?, initialMember: SourceFolderMember?) {
        self.store = store
        folderID = folder?.id
        _name = State(initialValue: folder?.name ?? "")
        _selected = State(initialValue: folder?.members ?? Set([initialMember?.normalized].compactMap { $0 }))
    }

    private var candidates: [SourceFolderMember] {
        let captured = store.clientApps.map { SourceFolderMember.client($0.name) }
            + store.domainSummary.map { SourceFolderMember.domain($0.host.lowercased()) }
        return selected.union(captured)
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted {
                if $0.isDomain != $1.isDomain { return $0.isDomain }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(folderID == nil ? "新建来源文件夹" : "编辑来源文件夹").font(.headline)
            TextField("文件夹名称", text: $name)
            TextField("搜索已捕获的来源", text: $search)
            let items = candidates
            if items.isEmpty {
                Text(search.isEmpty ? "捕获流量后可添加应用或域名。" : "未找到匹配来源。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(items, id: \.self) { item in
                    Toggle(isOn: Binding(get: { selected.contains(item) }, set: { enabled in
                        if enabled { selected.insert(item) } else { selected.remove(item) }
                    })) {
                        Label(item.name, systemImage: item.isDomain ? "globe" : "app")
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(minHeight: 160, maxHeight: 270)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("已选 \(selected.count) 个来源").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        do {
            let id = try store.saveSourceFolder(id: folderID, name: name, members: selected)
            if folderID == nil { store.filterMode = .folder(id) }
            dismiss()
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}
