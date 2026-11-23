import SwiftUI

/// A shared picker for rule editors. Folder creation and removal of membership are drafts.
struct RuleFolderPicker: View {
    let tool: String
    let ruleID: String
    @Binding var draft: RuleFolderEditingDraft
    @State private var creating = false
    @State private var name = ""
    @State private var parent = ""
    @State private var error: String?

    private var folders: [RuleFolder] { draft.folders(tool: tool) }
    private var selection: Binding<String> {
        Binding(get: { draft.folderID(ruleID: ruleID, tool: tool)?.uuidString ?? "" }, set: { value in
            draft.assign(ruleID: ruleID, tool: tool, folderID: UUID(uuidString: value))
        })
    }

    var body: some View {
        HStack {
            Picker("文件夹", selection: selection) {
                Text("未分组").tag("")
                ForEach(folders) { folder in Text(draft.path(folder)).tag(folder.id.uuidString) }
            }
            Button("新建…") {
                name = ""; parent = selection.wrappedValue; error = nil; creating = true
            }
            Button("移除归属") { selection.wrappedValue = "" }.disabled(selection.wrappedValue.isEmpty)
        }
        .help("文件夹归属与新建文件夹在保存规则时一起提交；取消编辑会丢弃这些更改。")
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 12) {
                Text("新建规则文件夹").font(.headline)
                TextField("名称", text: $name)
                Picker("父文件夹", selection: $parent) {
                    Text("根目录").tag("")
                    ForEach(folders) { folder in Text(draft.path(folder)).tag(folder.id.uuidString) }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                HStack {
                    Spacer()
                    Button("取消") { creating = false }.keyboardShortcut(.cancelAction)
                    Button("新建并移动") {
                        do {
                            let folder = try draft.createFolder(tool: tool, name: name, parentID: UUID(uuidString: parent))
                            draft.assign(ruleID: ruleID, tool: tool, folderID: folder.id)
                            creating = false
                        } catch { self.error = error.localizedDescription }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
                }
            }.padding(18).frame(width: 390)
        }
    }
}
