import SwiftUI

struct LatencyConditionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = LatencyConditions.snapshot()
    @State private var selection: UUID?
    @State private var error: String?

    private var selectedIndex: Int? { draft.rules?.firstIndex { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Strings.Tools.networkConditions).font(.headline)
                Spacer()
                Toggle(Strings.Tools.enable, isOn: $draft.enabled).toggleStyle(.switch)
            }
            HSplitView {
                VStack(spacing: 8) {
                    List(selection: $selection) {
                        ForEach(draft.rules ?? []) { rule in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(rule.name, systemImage: rule.enabled ? "network" : "pause.circle")
                                Text(rule.host.isEmpty ? Strings.Tools.allHosts : rule.host).font(.caption).foregroundStyle(.secondary)
                            }.tag(rule.id)
                        }
                    }
                    HStack {
                        Button { add() } label: { Image(systemName: "plus") }
                        Button { remove() } label: { Image(systemName: "minus") }.disabled(selectedIndex == nil)
                        Spacer()
                        Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled((selectedIndex ?? 0) == 0)
                        Button { move(1) } label: { Image(systemName: "arrow.down") }
                            .disabled(selectedIndex == nil || selectedIndex == (draft.rules?.count ?? 0) - 1)
                    }.buttonStyle(.borderless)
                }.frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
                if let index = selectedIndex {
                    editor(index).padding(.leading, 10).frame(minWidth: 390)
                } else {
                    Text(Strings.Tools.addRulesToConfigureNetworkConditionsForDifferentHosts)
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(Strings.Tools.useTheFirstEnabledRuleMatchingTheHostFrom)
                .font(.caption).foregroundStyle(.secondary)
            if let error = error ?? draft.localizedValidationError { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Spacer()
                Button(Strings.Tools.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Tools.save) {
                    for index in (draft.rules ?? []).indices {
                        draft.rules?[index].host = RulesSnapshot.sslHostPattern(draft.rules?[index].host ?? "")
                    }
                    if LatencyConditions.install(draft) { dismiss() }
                    else { error = Strings.Tools.unableToSaveNetworkConditions }
                }
                .keyboardShortcut(.defaultAction).disabled(draft.validationError != nil)
            }
        }
        .padding(18).frame(width: 740, height: 480)
        .onAppear {
            if draft.rules == nil {
                var migrated = NetworkConditionRule(legacy: draft, name: Strings.Tools.existingNetworkConditions)
                migrated.enabled = true
                draft.rules = [migrated]
            }
            selection = draft.rules?.first?.id
        }
    }

    private func binding<T>(_ index: Int, _ path: WritableKeyPath<NetworkConditionRule, T>, fallback: T) -> Binding<T> {
        Binding(get: {
            guard let rules = draft.rules, rules.indices.contains(index) else { return fallback }
            return rules[index][keyPath: path]
        }, set: { value in
            guard draft.rules?.indices.contains(index) == true else { return }
            draft.rules?[index][keyPath: path] = value
        })
    }

    private func editor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(Strings.Tools.ruleName, text: binding(index, \.name, fallback: ""))
                Toggle(Strings.Tools.enableRule, isOn: binding(index, \.enabled, fallback: false))
            }
            TextField(Strings.Tools.targetHostLeaveEmptyForAllHosts, text: binding(index, \.host, fallback: ""))
            Menu(Strings.Tools.loadPreset) {
                ForEach(LatencyConditions.Preset.allCases, id: \.self) { preset in
                    Button(preset.localizedTitle) {
                        guard let old = draft.rules?[index] else { return }
                        var replacement = NetworkConditionRule(legacy: preset.settings(for: old.host), name: old.name)
                        replacement.id = old.id
                        draft.rules?[index] = replacement
                    }
                }
            }.fixedSize()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(Strings.Tools.requestDelayMs)
                    TextField("0–5000", value: binding(index, \.milliseconds, fallback: 0), format: .number.grouping(.never))
                }
                numberRow(index, Strings.Tools.requestJitterMs, \.jitterMilliseconds)
                numberRow(index, Strings.Tools.uploadKbps, \.uploadKbps)
                numberRow(index, Strings.Tools.downloadKbps, \.downloadKbps)
                numberRow(index, Strings.Tools.randomDisconnect, \.disconnectPercent)
                numberRow(index, Strings.Tools.responseLatencySpike, \.responseSpikePercent)
                numberRow(index, Strings.Tools.bodyPause, \.bodyPausePercent)
            }
            Text(Strings.Tools.aRateOf0IsUnlimitedRandomDisconnectionsAre)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.textFieldStyle(.roundedBorder)
    }

    private func numberRow(_ index: Int, _ label: String, _ field: WritableKeyPath<NetworkConditionRule, Int?>) -> some View {
        GridRow {
            Text(label)
            TextField("0", value: Binding(get: { draft.rules?[index][keyPath: field] ?? 0 }, set: {
                draft.rules?[index][keyPath: field] = $0 == 0 ? nil : $0
            }), format: .number.grouping(.never))
        }
    }

    private func add() {
        let rule = NetworkConditionRule(legacy: LatencyConditions.Preset.threeG.settings(for: ""), name: Strings.Tools.rule(Int((draft.rules?.count ?? 0) + 1)))
        draft.rules = (draft.rules ?? []) + [rule]
        selection = rule.id
    }

    private func remove() {
        guard let index = selectedIndex else { return }
        draft.rules?.remove(at: index)
        selection = draft.rules?.first?.id
    }

    private func move(_ offset: Int) {
        guard let index = selectedIndex, let rules = draft.rules, rules.indices.contains(index + offset) else { return }
        draft.rules?.swapAt(index, index + offset)
    }
}
