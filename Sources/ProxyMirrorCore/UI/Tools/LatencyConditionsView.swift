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
                Text("Network Conditions · 弱网模拟").font(.headline)
                Spacer()
                Toggle("启用", isOn: $draft.enabled).toggleStyle(.switch)
            }
            HSplitView {
                VStack(spacing: 8) {
                    List(selection: $selection) {
                        ForEach(draft.rules ?? []) { rule in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(rule.name, systemImage: rule.enabled ? "network" : "pause.circle")
                                Text(rule.host.isEmpty ? "所有主机" : rule.host).font(.caption).foregroundStyle(.secondary)
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
                    Text("添加规则，为不同主机设置网络条件。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text("从上到下使用第一条启用且匹配主机的规则；未匹配的请求保持正常网络。支持 HTTP/1、HTTP/2 及经过 HTTP 握手的连接。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = error ?? draft.validationError { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    for index in (draft.rules ?? []).indices {
                        draft.rules?[index].host = RulesSnapshot.sslHostPattern(draft.rules?[index].host ?? "")
                    }
                    if LatencyConditions.install(draft) { dismiss() }
                    else { error = "无法保存弱网设置" }
                }
                .keyboardShortcut(.defaultAction).disabled(draft.validationError != nil)
            }
        }
        .padding(18).frame(width: 740, height: 480)
        .onAppear {
            if draft.rules == nil {
                var migrated = NetworkConditionRule(legacy: draft, name: "原有网络条件")
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
                TextField("规则名称", text: binding(index, \.name, fallback: ""))
                Toggle("启用规则", isOn: binding(index, \.enabled, fallback: false))
            }
            TextField("目标主机，空白为所有主机", text: binding(index, \.host, fallback: ""))
            Menu("载入预设") {
                ForEach(LatencyConditions.Preset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) {
                        guard let old = draft.rules?[index] else { return }
                        var replacement = NetworkConditionRule(legacy: preset.settings(for: old.host), name: old.name)
                        replacement.id = old.id
                        draft.rules?[index] = replacement
                    }
                }
            }.fixedSize()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("请求延迟 (ms)")
                    TextField("0–5000", value: binding(index, \.milliseconds, fallback: 0), format: .number.grouping(.never))
                }
                numberRow(index, "请求抖动 (±ms)", \.jitterMilliseconds)
                numberRow(index, "上传 (kbps)", \.uploadKbps)
                numberRow(index, "下载 (kbps)", \.downloadKbps)
                numberRow(index, "随机断连 (%)", \.disconnectPercent)
                numberRow(index, "响应延迟尖峰 (%)", \.responseSpikePercent)
                numberRow(index, "正文暂停 (%)", \.bodyPausePercent)
            }
            Text("速率为 0 时不限速。随机断连按请求抽样；响应尖峰增加 500 ms。正文暂停按块抽样后顺序补发，用于模拟不稳定链路。")
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
        let rule = NetworkConditionRule(legacy: LatencyConditions.Preset.threeG.settings(for: ""), name: "规则 \((draft.rules?.count ?? 0) + 1)")
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
