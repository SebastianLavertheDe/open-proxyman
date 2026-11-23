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
            Picker(Strings.Tools.folder, selection: selection) {
                Text(Strings.Tools.ungrouped).tag("")
                ForEach(folders) { folder in Text(draft.path(folder)).tag(folder.id.uuidString) }
            }
            Button(Strings.Tools.new) {
                name = ""; parent = selection.wrappedValue; error = nil; creating = true
            }
            Button(Strings.Tools.removeFolderMembership) { selection.wrappedValue = "" }.disabled(selection.wrappedValue.isEmpty)
        }
        .help(Strings.Tools.folderMembershipAndNewFoldersAreCommittedWhenThe)
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 12) {
                Text(Strings.Tools.newRuleFolder).font(.headline)
                TextField(Strings.Tools.name, text: $name)
                Picker(Strings.Tools.parentFolder, selection: $parent) {
                    Text(Strings.Tools.root).tag("")
                    ForEach(folders) { folder in Text(draft.path(folder)).tag(folder.id.uuidString) }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                HStack {
                    Spacer()
                    Button(Strings.Tools.cancel) { creating = false }.keyboardShortcut(.cancelAction)
                    Button(Strings.Tools.createMove) {
                        do {
                            let folder = try draft.createFolder(tool: tool, name: name, parentID: UUID(uuidString: parent))
                            draft.assign(ruleID: ruleID, tool: tool, folderID: folder.id)
                            creating = false
                        } catch { self.error = LocalizedErrorPresentation.message(for: error) }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
                }
            }.padding(18).frame(width: 390)
        }
    }
}
