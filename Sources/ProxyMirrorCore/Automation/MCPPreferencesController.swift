import Combine
import Foundation

/// The core settings UI talks to the application-owned MCP transport through
/// this bridge, keeping the executable target out of the core dependency graph.
@MainActor
final class MCPPreferencesController: ObservableObject {
    static let shared = MCPPreferencesController()

    enum Client: String, CaseIterable, Identifiable {
        case claudeCode, codex, manual
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .manual: return "Manual"
            }
        }
    }
    enum Transport: String, CaseIterable, Identifiable {
        case http, stdio
        var id: String { rawValue }
        var title: String { self == .http ? "HTTP" : "stdio" }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var endpoint: String?
    private let settings: AppSettings
    private var applyEnabled: ((Bool) -> Void)?
    private var provideConfiguration: ((Client, Transport) -> String?)?
    private var defaultsObserver: NSObjectProtocol?
    private var appliedEnabled: Bool?

    init(settings: AppSettings = .shared) {
        self.settings = settings
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.appliedEnabled != self.settings.mcpEnabled else { return }
                self.refresh()
            }
        }
    }

    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }

    func register(applyEnabled: @escaping (Bool) -> Void,
                  configuration: @escaping (Client, Transport) -> String?) {
        self.applyEnabled = applyEnabled
        provideConfiguration = configuration
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        appliedEnabled = enabled
        settings.mcpEnabled = enabled
        applyEnabled?(enabled)
    }

    func refresh() {
        appliedEnabled = settings.mcpEnabled
        applyEnabled?(settings.mcpEnabled)
    }

    func configuration(client: Client, transport: Transport = .http) -> String? {
        provideConfiguration?(client, transport)
    }

    func update(isRunning: Bool, endpoint: String? = nil, error: String? = nil) {
        self.isRunning = isRunning
        self.endpoint = endpoint
        errorMessage = error
    }
}
