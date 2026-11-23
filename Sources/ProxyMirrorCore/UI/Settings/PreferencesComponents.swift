import AppKit
import SwiftUI

enum PreferencesPalette {
    static let sidebar = adaptive(dark: 0x4C4C4C, light: 0xEAEAEA)
    static let content = adaptive(dark: 0x282828, light: 0xF5F5F5)
    static let header = adaptive(dark: 0x383838, light: 0xECECEC)
    static let search = adaptive(dark: 0x5C5C5C, light: 0xF5F5F5)
    static let searchBorder = adaptive(dark: 0x888888, light: 0xBFBFBF)
    static let card = adaptive(dark: 0x313131, light: 0xF9F9F9)
    static let cardBorder = adaptive(dark: 0x4E4E4E, light: 0xCDCDCD)
    static let strip = adaptive(dark: 0x1E1E1E, light: 0xE7E7E7)
    static let selection = Color(red: 58 / 255, green: 128 / 255, blue: 230 / 255)

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

extension PreferencesPage {
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "wand.and.stars"
        case .privacy: return "person.fill"
        case .mcp: return "shippingbox"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .tools: return "wrench.and.screwdriver"
        case .networkExtension: return "network"
        case .advanced: return "ellipsis.circle"
        case .workspace: return "person.3.fill"
        case .products: return "square.grid.2x2"
        }
    }

    var color: Color {
        switch self {
        case .general, .advanced: return .gray
        case .appearance: return .purple
        case .privacy, .networkExtension: return .blue
        case .mcp: return .orange
        case .github: return Color(nsColor: .darkGray)
        case .tools, .workspace: return .indigo
        case .products: return .cyan
        }
    }
}

struct PreferencesRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 178
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.top, 2)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PreferencesSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(verbatim: title).fontWeight(.medium) }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(PreferencesPalette.card, in: RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(PreferencesPalette.cardBorder) }
        }
    }
}

struct PreferencesHelp: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PreferencesToggle: View {
    let title: String
    let keyPath: ReferenceWritableKeyPath<AppSettings, Bool>
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }))
    }
}

private struct PreferencesRevealKey: EnvironmentKey {
    static let defaultValue: SettingsSearchTarget? = nil
}

extension EnvironmentValues {
    var preferencesReveal: SettingsSearchTarget? {
        get { self[PreferencesRevealKey.self] }
        set { self[PreferencesRevealKey.self] = newValue }
    }
}

struct PreferencesSetting<Content: View>: View {
    let target: SettingsSearchTarget
    @ViewBuilder let content: Content
    @Environment(\.preferencesReveal) private var reveal

    var body: some View {
        content
            .background {
                if reveal == target {
                    RoundedRectangle(cornerRadius: 4).fill(PreferencesPalette.selection.opacity(0.13)).padding(-4)
                }
            }
            .id(target.id)
    }
}

/// Keep the system window controls while letting the sidebar extend behind the title bar.
struct PreferencesWindowStyle: NSViewRepresentable {
    final class WindowView: NSView {
        private var snapshotScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.toolbar = nil
            window.setContentSize(NSSize(width: 970, height: 750))
            scheduleSnapshot()
        }

        private func scheduleSnapshot() {
            guard !snapshotScheduled,
                  let path = ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"],
                  path.hasPrefix("/") else { return }
            snapshotScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                do {
                    guard let content = self.window?.contentView else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    // The frame view also draws the real system title-bar controls.
                    let renderedView = content.superview ?? content
                    renderedView.layoutSubtreeIfNeeded()
                    let rect = self.convert(self.bounds, to: renderedView)
                    guard let bitmap = renderedView.bitmapImageRepForCachingDisplay(in: rect) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    renderedView.cacheDisplay(in: rect, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let url = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    NotificationCenter.default.post(name: Notification.Name("ProxyMirror.settingsSnapshotFinished"),
                                                    object: nil, userInfo: ["path": path, "success": true])
                } catch {
                    NotificationCenter.default.post(name: Notification.Name("ProxyMirror.settingsSnapshotFinished"),
                                                    object: nil, userInfo: ["path": path, "success": false,
                                                                         "error": LocalizedErrorPresentation.message(for: error)])
                }
            }
        }
    }

    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
