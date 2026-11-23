import SwiftUI

@MainActor
struct UpdateSettingsView: View {
    @ObservedObject private var updates = AppUpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.Settings.updatesReleaseNotes).font(.title2)
            Text("ProxyMirror \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Strings.Settings.developmentBuild)")
                .foregroundStyle(.secondary)
            Text(updates.status).fixedSize(horizontal: false, vertical: true)
            Toggle(Strings.Settings.automaticallyCheckForUpdates, isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.setAutomaticallyChecksForUpdates($0) }
            )).disabled(!updates.supportsAutomaticChecks)
            if let checked = updates.lastUpdateCheck {
                Text(Strings.Settings.lastChecked(checked.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let feed = updates.configuredFeed {
                Text(Strings.Settings.updateFeed(feed.absoluteString)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button(updates.checkMenuTitle) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                Button(Strings.Settings.releaseNotes) { updates.openReleaseNotes() }
            }
            if !updates.automaticUpdatesAvailable {
                Link(Strings.Settings.projectReleases, destination: AppUpdateController.releasesURL)
            }
            Spacer(minLength: 0)
        }
        .padding(22).frame(width: 560, height: 310)
        .onAppear { updates.startIfConfigured() }
    }
}

/// Insert in an app-info CommandGroup; state changes keep the menu's enabled state current.
@MainActor
struct AppUpdateMenuItems: View {
    @ObservedObject private var updates = AppUpdateController.shared
    var body: some View {
        Button(updates.checkMenuTitle) { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
        Button(Strings.Settings.releaseNotes) { updates.openReleaseNotes() }
    }
}
