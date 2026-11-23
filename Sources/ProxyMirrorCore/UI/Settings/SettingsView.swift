import SwiftUI

enum ProxyMirrorAppearance: String, CaseIterable {
    case system, light, dark
    static let key = "ui.appearance"
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum PreferencesSheet: String, Identifiable {
    case connections, cleanup, updates, certificateReset, gist, backup
    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var page = PreferencesPage.general
    @State private var history: [PreferencesPage] = [.general]
    @State private var historyIndex = 0
    @State private var search = ""
    @State private var reveal: SettingsSearchTarget?
    @State private var revealRequest = UUID()
    @State private var sheet: PreferencesSheet?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220).overlay(alignment: .trailing) { Divider() }
            VStack(spacing: 0) {
                header
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        pageContent
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 40)
                            .padding(.top, 20)
                            .padding(.bottom, 32)
                    }
                    .onChange(of: revealRequest) { _ in
                        guard let reveal else { return }
                        DispatchQueue.main.async { withAnimation { proxy.scrollTo(reveal.id, anchor: .center) } }
                    }
                }
            }
            .background(PreferencesPalette.content)
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .tint(PreferencesPalette.selection)
        .frame(width: 970, height: 750)
        .background(PreferencesWindowStyle())
        .environment(\.locale, L10n.locale)
        .environment(\.preferencesReveal, reveal)
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden().accessibilityHidden(true)
        }
        .sheet(item: $sheet) { sheetContent($0) }
        .onAppear(perform: configureInitialPage)
        .onChange(of: appState.settingsTarget) { _ in revealSettingsTarget() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 34)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(Strings.Settings.searchF, text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if let target = SettingsSearchTarget.results(for: search).first { show(target) } }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(Strings.Settings.clearSearch)
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 6).frame(height: 21)
            .background(PreferencesPalette.search, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(PreferencesPalette.searchBorder) }
            .padding(.horizontal, 12).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sidebarGroup(Strings.Settings.application2, pages: [.general, .appearance, .privacy])
                        sidebarGroup(Strings.Settings.integrations, pages: [.mcp, .github, .tools])
                        sidebarGroup(Strings.Settings.advanced, pages: [.networkExtension, .advanced])
                        sidebarGroup("ProxyMirror", pages: [.workspace, .products])
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 16)
            }
            Spacer(minLength: 0)
        }
        .background(PreferencesPalette.sidebar)
    }

    private func sidebarGroup(_ title: String, pages: [PreferencesPage]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.leading, 8).padding(.bottom, 2)
            ForEach(pages) { destination in
                Button { navigate(to: destination) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: destination.symbol)
                            .font(.system(size: 14)).foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(destination.color, in: RoundedRectangle(cornerRadius: 6))
                        Text(destination.title).fontWeight(.medium)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).frame(height: 32)
                    .foregroundStyle(page == destination ? Color.white : Color.primary)
                    .background(page == destination ? PreferencesPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == destination ? .isSelected : [])
            }
        }
    }

    private var searchResults: some View {
        let matches = SettingsSearchTarget.results(for: search)
        return VStack(alignment: .leading, spacing: 4) {
            if matches.isEmpty { Text(Strings.Settings.noMatchingSettings).foregroundStyle(.secondary).padding(8) }
            ForEach(matches) { target in
                Button { show(target) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.title).lineLimit(2)
                        Text(target.tabTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { moveHistory(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(historyIndex == 0).accessibilityLabel(Strings.Settings.back)
            Button { moveHistory(1) } label: { Image(systemName: "chevron.right") }
                .disabled(historyIndex >= history.count - 1).accessibilityLabel(Strings.Settings.forward)
            Text(page.title).font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .buttonStyle(.plain).padding(.horizontal, 20).frame(height: 52)
        .background(PreferencesPalette.header)
        .background(PreferencesHeaderAnchor())
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general:
            PreferencesGeneralView(onAdvanced: { sheet = .connections }, onUpdates: { sheet = .updates },
                                   onResetCertificate: { sheet = .certificateReset })
        case .appearance: ExperienceSettingsView()
        case .privacy: PreferencesPrivacyView()
        case .mcp: PreferencesMCPView()
        case .github: PreferencesGitHubView { sheet = .gist }
        case .tools: PreferencesToolsView()
        case .networkExtension: PreferencesNetworkExtensionView()
        case .advanced: PreferencesAdvancedView(onConnections: { sheet = .connections }, onCleanup: { sheet = .cleanup })
        case .workspace: PreferencesWorkspaceView { sheet = .backup }
        case .products: PreferencesProductView(onUpdates: { sheet = .updates })
        }
    }

    @ViewBuilder private func sheetContent(_ destination: PreferencesSheet) -> some View {
        Group {
            switch destination {
            case .connections: PreferencesConnectionSettings(target: reveal)
            case .cleanup: PreferencesCleanupSettings()
            case .updates: UpdateSettingsView()
            case .certificateReset: ResetCAConfirmView { sheet = nil }
            case .gist: GistPublishView(transactions: appState.activeStore.selectedTransactions)
            case .backup: RuleBackupView()
            }
        }
        .environmentObject(appState)
        .environment(\.preferencesReveal, reveal)
    }

    private func navigate(to destination: PreferencesPage) {
        if destination != page {
            history = Array(history.prefix(historyIndex + 1))
            history.append(destination)
            historyIndex = history.count - 1
            page = destination
        }
        search = ""; reveal = nil
    }

    private func moveHistory(_ offset: Int) {
        let next = historyIndex + offset
        guard history.indices.contains(next) else { return }
        historyIndex = next; page = history[next]; search = ""; reveal = nil
    }

    private func configureInitialPage() {
        if let requested = ProcessInfo.processInfo.environment["PM_SETTINGS_PAGE"] {
            let value = requested == "network" ? "networkExtension" : requested
            if let destination = PreferencesPage(rawValue: value) {
                page = destination; history = [destination]; historyIndex = 0
            }
        }
        revealSettingsTarget()
    }

    private func revealSettingsTarget() {
        guard let target = appState.settingsTarget else { return }
        appState.settingsTarget = nil
        show(target)
    }

    private func show(_ target: SettingsSearchTarget) {
        navigate(to: target.page)
        searchFocused = false
        reveal = target
        if target.opensConnectionSettings { sheet = .connections }
        revealRequest = UUID()
    }
}
