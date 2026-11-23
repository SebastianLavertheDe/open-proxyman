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
            Text(folder == nil ? Strings.Traffic.newSavedRequestFolder : Strings.Traffic.editSavedRequestFolder).font(.headline)
            TextField(Strings.Traffic.folderName, text: $name)
            Picker(Strings.Traffic.parent, selection: $parent) {
                Text(Strings.Traffic.savedRoot).tag(nil as UUID?)
                ForEach(store.savedRequestFolders.filter { $0.id != folder?.id }) { item in
                    Text(store.savedRequestFolderPath(item.id)).tag(Optional(item.id))
                }
            }
            Text(Strings.Traffic.thisStoresIndependentRequestSnapshotsDomainAndApplicationFiltersInSource)
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(Strings.Traffic.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Traffic.save) {
                    do {
                        if let folder { try store.updateSavedRequestFolder(folder.id, name: name, parentID: parent) }
                        else { _ = try store.createSavedRequestFolder(name: name, parentID: parent) }
                        dismiss()
                    } catch { self.error = LocalizedErrorPresentation.message(for: error) }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 480)
        .onAppear { name = folder?.name ?? ""; parent = folder?.parentID ?? initialParent }
    }
}
