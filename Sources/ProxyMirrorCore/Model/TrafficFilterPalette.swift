import Foundation
import Combine
import ProxyMirrorFoundation

/// Saved filter colors are a display overlay; they never overwrite a flow's manual highlight.
@MainActor
final class TrafficFilterPalette: ObservableObject {
    static let shared = TrafficFilterPalette()
    @Published private(set) var revision: UInt64 = 0
    private var stored = Data()
    private var tests: [(String, (Transaction) -> PresentationPredicateResult)] = []
    private var changes: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        reload(defaults)
        changes = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload(defaults) }
    }

    private func reload(_ defaults: UserDefaults) {
        let data = defaults.data(forKey: SavedTrafficFilter.defaultsKey) ?? Data()
        guard data != stored else { return }
        stored = data
        let profiles = (try? JSONDecoder().decode([SavedTrafficFilter].self, from: data)) ?? []
        tests = profiles.compactMap { profile in
            guard let color = profile.highlightName, ProxymanTheme.highlightNames.contains(color),
                  profile.group.isValid, !profile.group.isEmpty else { return nil }
            return (color, profile.group.compileForPresentation())
        }
        revision &+= 1
    }

    func highlight(for transaction: Transaction) -> String? {
        tests.first { $0.1(transaction) == .matched }?.0
    }
}
