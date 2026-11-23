import SwiftUI

struct SavedRequestFolderEditor: View {
    @ObservedObject var store: TrafficStore
    let folder: SavedRequestFolder?
    var initialParent: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parent: UUID?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(folder == nil ? "新建 Saved 请求文件夹" : "编辑 Saved 请求文件夹").font(.headline)
            TextField("文件夹名称", text: $name)
            Picker("父级", selection: $parent) {
                Text("Saved 根级").tag(nil as UUID?)
                ForEach(store.savedRequestFolders.filter { $0.id != folder?.id }) { item in
                    Text(store.savedRequestFolderPath(item.id)).tag(Optional(item.id))
                }
            }
            Text("这里保存独立请求快照。来源文件夹的域名 / 应用过滤不会改变这些内容。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        if let folder { try store.updateSavedRequestFolder(folder.id, name: name, parentID: parent) }
                        else { _ = try store.createSavedRequestFolder(name: name, parentID: parent) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 480)
        .onAppear { name = folder?.name ?? ""; parent = folder?.parentID ?? initialParent }
    }
}
