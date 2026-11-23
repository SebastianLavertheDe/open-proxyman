import SwiftUI

struct TrafficFilterEditor: View {
    @ObservedObject var store: TrafficStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SavedTrafficFilter.defaultsKey) private var stored = Data()
    @State private var draft = TrafficConditionGroup()
    @State private var name = ""
    @State private var highlight = ""
    @State private var search = ""
    @State private var selectedProfile: UUID?
    @State private var selectedCondition: UUID?
    @State private var navigateProfiles = false
    @State private var feedback: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var conditionFocused: UUID?

    private var profiles: [SavedTrafficFilter] { (try? JSONDecoder().decode([SavedTrafficFilter].self, from: stored)) ?? [] }
    private var visibleProfiles: [SavedTrafficFilter] {
        profiles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var valid: Bool { draft.isValid }
    private var profileName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var conditionIDs: [UUID] { visibleIDs(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Strings.Tools.advancedFilters).font(.headline)
                TextField(Strings.Tools.searchPresetsConditionsF, text: $search).focused($searchFocused)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                actions
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Strings.Tools.namedPresetsSelectWith).font(.caption).foregroundStyle(.secondary)
                    List {
                        ForEach(visibleProfiles) { profile in
                            Button { load(profile) } label: {
                                HStack {
                                    Circle().fill(profile.highlightName.map(ProxymanTheme.highlightColor) ?? .clear)
                                        .frame(width: 9, height: 9)
                                    Text(profile.name).lineLimit(2)
                                    Spacer()
                                }.padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .listRowBackground(selectedProfile == profile.id ? Color.accentColor.opacity(0.15) : .clear)
                        }
                    }
                    HStack {
                        Button(Strings.Tools.newPreset) { selectedProfile = nil; name = ""; draft = TrafficConditionGroup(); highlight = ""; selectedCondition = nil }
                        Button(Strings.Tools.delete) { if let selectedProfile { write(profiles.filter { $0.id != selectedProfile }); self.selectedProfile = nil } }
                            .disabled(selectedProfile == nil)
                    }
                }.frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                conditionPanel
            }
            footer
        }
        .padding(18).frame(width: 1020, height: 570)
        .background(TrafficFilterKeyHandler(action: handle).frame(width: 0, height: 0))
        .onAppear { draft = store.filter.conditions }
        .onChange(of: conditionFocused) { value in
            if let value { selectedCondition = value; navigateProfiles = false }
        }
    }

    private var conditionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(Strings.Tools.matchType, selection: $draft.mode) {
                ForEach(TrafficConditionGroup.Mode.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    TrafficConditionGroupEditor(group: $draft, depth: 0, query: search,
                        selected: $selectedCondition, focus: $conditionFocused)
                }
                .onChange(of: selectedCondition) { id in if let id { navigateProfiles = false; scroll.scrollTo(id, anchor: .center) } }
            }.frame(minHeight: 160)
            Text(Strings.Tools.bodyConditionsInspectTheFirst1MibAfterDecoding)
                .font(.caption).foregroundStyle(.secondary)
            Picker(Strings.Tools.colorMatchingRequests, selection: $highlight) {
                Text(Strings.Tools.disableColoring).tag("")
                ForEach(ProxymanTheme.highlightNames, id: \.self) { Text(ProxymanTheme.localizedHighlightName($0)).tag($0) }
            }
            Text(Strings.Tools.bTogglesColoringForTheSelectedPresetPresetsApply)
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.leading, 10).frame(minWidth: 680)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                TextField(Strings.Tools.filterName, text: $name)
                Button(Strings.Tools.savePreset) { saveProfile() }.disabled(!valid || draft.isEmpty || profileName.isEmpty)
                Spacer()
                Button(Strings.Tools.cancelEsc) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.Tools.applyAction) { store.filter.conditions = draft; dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
    }

    private var actions: some View {
        Menu(Strings.Tools.panelActions) {
            Button(Strings.Tools.addConditionN) { handle(.addCondition) }
            Button(Strings.Tools.addAndOrGroupN) { handle(.addGroup) }
            Divider()
            Button(navigateProfiles ? Strings.Tools.previousPresetShortcut : Strings.Tools.previousConditionShortcut) { handle(.previous) }
            Button(navigateProfiles ? Strings.Tools.nextPresetShortcut : Strings.Tools.nextConditionShortcut) { handle(.next) }
            Button(Strings.Tools.toggleSelectedPresetColoringB) { handle(.toggleColor) }.disabled(selectedProfile == nil)
            Button(Strings.Tools.searchPanelF) { handle(.search) }
            Divider()
            Button(Strings.Tools.cancelEsc2) { dismiss() }
        }.fixedSize()
    }

    private func handle(_ command: TrafficFilterShortcut) {
        switch command {
        case .cancel: dismiss()
        case .search: searchFocused = true
        case .addCondition:
            let condition = TrafficCondition()
            search = ""; draft.conditions.append(condition)
            selectedCondition = condition.id; conditionFocused = condition.id; navigateProfiles = false
        case .addGroup:
            let condition = TrafficCondition()
            search = ""
            if draft.groups == nil { draft.groups = [] }
            draft.groups?.append(TrafficConditionGroup(conditions: [condition]))
            selectedCondition = condition.id; conditionFocused = condition.id; navigateProfiles = false
        case .previous, .next:
            let delta = command == .previous ? -1 : 1
            if navigateProfiles {
                if let index = TrafficFilterShortcut.nextIndex(current: visibleProfiles.firstIndex { $0.id == selectedProfile }, count: visibleProfiles.count, delta: delta) {
                    load(visibleProfiles[index])
                }
            } else if let index = TrafficFilterShortcut.nextIndex(current: selectedCondition.flatMap { conditionIDs.firstIndex(of: $0) }, count: conditionIDs.count, delta: delta) {
                selectedCondition = conditionIDs[index]; conditionFocused = conditionIDs[index]
            }
        case .toggleColor:
            guard let id = selectedProfile, let index = profiles.firstIndex(where: { $0.id == id }) else { feedback = Strings.Tools.selectOrSaveAPresetFirst; return }
            var next = profiles
            next[index].highlightName = next[index].highlightName == nil ? (highlight.isEmpty ? "Yellow" : highlight) : nil
            highlight = next[index].highlightName ?? ""
            write(next)
            feedback = next[index].highlightName == nil ? Strings.Tools.coloringDisabledForTheSelectedPreset : Strings.Tools.coloringEnabledForTheSelectedPreset
        }
    }

    private func load(_ profile: SavedTrafficFilter) {
        selectedProfile = profile.id; name = profile.name; draft = profile.group; highlight = profile.highlightName ?? ""
        selectedCondition = nil; conditionFocused = nil; navigateProfiles = true; feedback = nil
    }
    private func saveProfile() {
        let id = selectedProfile ?? profiles.first { $0.name == profileName }?.id ?? UUID()
        let profile = SavedTrafficFilter(id: id, name: profileName, group: draft, highlightName: highlight.isEmpty ? nil : highlight)
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == id }) { next[index] = profile } else { next.append(profile) }
        write(next); selectedProfile = id; feedback = Strings.Tools.presetSaved
    }
    private func write(_ profiles: [SavedTrafficFilter]) {
        if let encoded = try? JSONEncoder().encode(profiles) { stored = encoded }
    }
    private func visibleIDs(_ group: TrafficConditionGroup) -> [UUID] {
        group.conditions.filter { TrafficConditionGroupEditor.matches($0, query: search) }.map(\.id)
            + (group.groups ?? []).flatMap { visibleIDs($0) }
    }
}

private struct TrafficConditionGroupEditor: View {
    @Binding var group: TrafficConditionGroup
    let depth: Int
    let query: String
    @Binding var selected: UUID?
    let focus: FocusState<UUID?>.Binding

    static func matches(_ condition: TrafficCondition, query: String) -> Bool {
        query.isEmpty || "\(condition.field.localizedTitle) \(condition.comparison.localizedTitle) \(condition.value)".localizedCaseInsensitiveContains(query)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($group.conditions) { $condition in
                if Self.matches(condition, query: query) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Picker(Strings.Tools.field, selection: $condition.field) {
                                ForEach(TrafficCondition.Field.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                            }.labelsHidden().frame(width: 130)
                            Picker(Strings.Tools.condition, selection: $condition.comparison) {
                                ForEach(TrafficCondition.Comparison.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                            }.labelsHidden().frame(width: 94)
                            TextField(condition.comparison == .between ? Strings.Tools.minimumMaximum : Strings.Tools.matchValue, text: $condition.value)
                                .focused(focus, equals: condition.id)
                            Button {
                                let id = condition.id; group.conditions.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel(Strings.Tools.deleteCondition)
                        }
                        if !condition.value.isEmpty && !condition.isValid {
                            Text(Strings.Tools.invalidConditionNumericFieldsAndRanges10100Must)
                                .font(.caption).foregroundStyle(.red)
                        }
                    }.padding(4).id(condition.id)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected == condition.id ? Color.accentColor : .clear))
                        .simultaneousGesture(TapGesture().onEnded { selected = condition.id })
                }
            }
            ForEach(Array((group.groups ?? []).indices), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker(Strings.Tools.subgroup, selection: subgroup(index).mode) {
                            ForEach(TrafficConditionGroup.Mode.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                        }
                        Spacer()
                        Button(Strings.Tools.deleteSubgroup) { group.groups?.remove(at: index) }.buttonStyle(.borderless)
                    }
                    AnyView(TrafficConditionGroupEditor(group: subgroup(index), depth: depth + 1, query: query, selected: $selected, focus: focus))
                }.padding(8).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button(Strings.Tools.addCondition) {
                    let condition = TrafficCondition(); group.conditions.append(condition); selected = condition.id; focus.wrappedValue = condition.id
                }
                if depth < 3 {
                    Button(Strings.Tools.addAndOrGroup) {
                        let condition = TrafficCondition()
                        if group.groups == nil { group.groups = [] }
                        group.groups?.append(TrafficConditionGroup(conditions: [condition])); selected = condition.id; focus.wrappedValue = condition.id
                    }
                }
            }
        }
    }
    private func subgroup(_ index: Int) -> Binding<TrafficConditionGroup> {
        Binding(get: {
            guard let groups = group.groups, groups.indices.contains(index) else { return TrafficConditionGroup() }
            return groups[index]
        }, set: { value in
            guard group.groups?.indices.contains(index) == true else { return }
            group.groups?[index] = value
        })
    }
}
