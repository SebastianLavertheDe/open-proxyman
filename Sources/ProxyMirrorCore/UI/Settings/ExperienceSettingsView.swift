import SwiftUI

@MainActor
struct ExperienceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(ProxyMirrorAppearance.key) private var appearance = ProxyMirrorAppearance.system

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesSetting(target: .displayBehavior) {
                PreferencesSection(title: Strings.Settings.userInterface) {
                    VStack(alignment: .leading, spacing: 12) {
                        typography
                        PreferencesRow(label: Strings.Settings.bodyTab, labelWidth: 165) {
                            VStack(alignment: .leading, spacing: 8) {
                                PreferencesToggle(title: Strings.Settings.wordWrap, keyPath: \.wordWrap)
                                PreferencesToggle(title: Strings.Settings.showInvisibleCharacters, keyPath: \.showInvisibles)
                                PreferencesToggle(title: Strings.Settings.showMinimap, keyPath: \.showMinimap)
                                PreferencesToggle(title: Strings.Settings.scrollBeyondLastLine, keyPath: \.scrollBeyondLastLine)
                            }
                        }
                        PreferencesRow(label: Strings.Settings.other, labelWidth: 165) {
                            VStack(alignment: .leading, spacing: 9) {
                                PreferencesToggle(title: Strings.Settings.alternatingRowColors, keyPath: \.showAlternatingRows)
                                PreferencesToggle(title: Strings.Settings.showResourceUsageInTheBottomToolbar, keyPath: \.showResourceUsage)
                                PreferencesToggle(title: Strings.Settings.proxymanCompatibleShortcuts, keyPath: \.proxymanCompatibleShortcuts)
                                PreferencesHelp(Strings.Settings.proxymanCompatibleShortcutsHelp)
                                PreferencesHelp(Strings.Settings.includesMemoryUsageUploadAndDownloadSpeeds)
                            }
                        }
                    }
                }
            }
            PreferencesSection(title: Strings.Settings.timeFormat) {
                PreferencesRow(label: "", labelWidth: 165) {
                    VStack(alignment: .leading, spacing: 9) {
                        PreferencesToggle(title: Strings.Settings.use24HourClock, keyPath: \.use24HourClock)
                        PreferencesHelp(Strings.Settings.switchBetweenThe12HourAnd24Hour)
                        PreferencesToggle(title: Strings.Settings.showFullDateAndTime, keyPath: \.showFullDate)
                        PreferencesHelp(Strings.Settings.timestampsIncludeTheDateTimeAndTimeZone)
                    }
                }
            }
            PreferencesSetting(target: .appearance) { themeSettings }
            Button(Strings.Settings.restoreDefaults) {
                settings.resetAppearanceDefaults()
                appearance = .system
            }
            .padding(.top, 4)
        }
    }

    private var typography: some View {
        PreferencesRow(label: Strings.Settings.fontSize, labelWidth: 165) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 18) {
                    Stepper(value: Binding(get: { Int(settings.fontSize) }, set: { settings.fontSize = Double($0) }), in: 8...32) {
                        Text(String(Int(settings.fontSize))).monospacedDigit().frame(width: 23)
                    }.fixedSize()
                    Text(Strings.Settings.tabWidth)
                    Stepper(value: Binding(get: { settings.codeTabWidth }, set: { settings.codeTabWidth = $0 }), in: 1...16) {
                        Text(Strings.Settings.spaces(settings.codeTabWidth)).monospacedDigit()
                    }.fixedSize()
                }
                HStack(spacing: 10) {
                    PreferencesToggle(title: Strings.Settings.useMonospacedFont, keyPath: \.useMonospacedFont)
                    Menu {
                        Button(Strings.Settings.systemMonospacedFont) { settings.monospacedFontFamily = "" }
                        ForEach(PresentationFonts.availableFamilies, id: \.self) { family in
                            Button(family) { settings.monospacedFontFamily = family }
                        }
                    } label: { Image(systemName: "gearshape").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(!settings.useMonospacedFont)
                    .accessibilityLabel(Strings.Settings.monospacedFont)
                    .help(settings.monospacedFontFamily.isEmpty ? Strings.Settings.systemMonospacedFont : settings.monospacedFontFamily)
                }
                PreferencesHelp(Strings.Settings.applyToAllTabsInTheRequestResponse)
            }
        }
    }

    private var themeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Settings.applicationTheme).fontWeight(.medium)
            HStack(spacing: 10) {
                themeOption(.system, title: Strings.Settings.system, dark: false)
                themeOption(.light, title: Strings.Settings.light, dark: false)
                themeOption(.dark, title: Strings.Settings.dark, dark: true)
            }
            .padding(7)
            .background(PreferencesPalette.strip)
        }
    }

    private func themeOption(_ value: ProxyMirrorAppearance, title: String, dark: Bool) -> some View {
        Button { appearance = value } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 2) { Circle().fill(.red); Circle().fill(.yellow); Circle().fill(.green) }.frame(width: 16, height: 4)
                    RoundedRectangle(cornerRadius: 1).fill(.blue.opacity(0.55)).frame(height: 2)
                    RoundedRectangle(cornerRadius: 1).fill(.green.opacity(0.6)).frame(width: 24, height: 2)
                    RoundedRectangle(cornerRadius: 1).fill(.orange.opacity(0.5)).frame(height: 2)
                }
                .padding(5).frame(width: 47, height: 34)
                .background(value == .system ? Color.gray : dark ? Color.black.opacity(0.7) : Color.white, in: RoundedRectangle(cornerRadius: 4))
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if appearance == value { Image(systemName: "checkmark").foregroundStyle(PreferencesPalette.selection) }
            }
            .padding(.horizontal, 7).frame(height: 42)
            .background(appearance == value ? PreferencesPalette.selection.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(appearance == value ? PreferencesPalette.selection : .clear) }
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityAddTraits(appearance == value ? .isSelected : [])
    }
}
