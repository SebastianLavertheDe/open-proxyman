import AppKit
import SwiftUI

/// Shared menu adapter for live, imported and saved snapshots. A move is offered only for saved containers.
@MainActor
enum SavedRequestMenu {
    static func add(to menu: NSMenu, store: TrafficStore, transactions: [Transaction], reportError: @escaping (String) -> Void) {
        guard !transactions.isEmpty else { return }
        let source = store.activeSavedRequestFolderID
        menu.addSubmenu("复制到 Saved 请求文件夹") { submenu in
            submenu.addAction("Saved（未分组）") { perform(reportError) { try store.copyRequests(transactions, toSavedFolder: nil) } }
            for folder in store.savedRequestFolders {
                submenu.addAction(store.savedRequestFolderPath(folder.id)) {
                    perform(reportError) { try store.copyRequests(transactions, toSavedFolder: folder.id) }
                }
            }
        }
        if store.isBrowsingSavedRequests {
            menu.addSubmenu("移动到 Saved 请求文件夹") { submenu in
                submenu.addAction("Saved（未分组）", enabled: source != nil) {
                    perform(reportError) { try store.transferSavedRequests(ids: Set(transactions.map(\.id)), from: source, to: nil, copy: false) }
                }
                for folder in store.savedRequestFolders {
                    submenu.addAction(store.savedRequestFolderPath(folder.id), enabled: source != folder.id) {
                        perform(reportError) { try store.transferSavedRequests(ids: Set(transactions.map(\.id)), from: source, to: folder.id, copy: false) }
                    }
                }
            }
        }
    }
    private static func perform(_ report: (String) -> Void, operation: () throws -> Void) {
        do { try operation() } catch { report(error.localizedDescription) }
    }
}
