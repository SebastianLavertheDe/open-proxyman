import SwiftUI

struct LatencyConditionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = LatencyConditions.snapshot()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("弱网模拟").font(.headline)
                Spacer()
                Menu("载入预设") {
                    ForEach(LatencyConditions.Preset.allCases, id: \.self) { preset in
                        Button(preset.rawValue) { draft = preset.settings(for: draft.host) }
                    }
                }
                .fixedSize()
            }
            Toggle("启用弱网模拟", isOn: $draft.enabled)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("请求延迟 (ms)")
                    TextField("0–5000", value: $draft.milliseconds, format: .number.grouping(.never))
                }
                numberRow("请求抖动 (±ms)", "0–5000", \.jitterMilliseconds)
                numberRow("上传 (kbps)", "不限速", \.uploadKbps)
                numberRow("下载 (kbps)", "不限速", \.downloadKbps)
                numberRow("随机断连 (%)", "0–100", \.disconnectPercent)
                numberRow("响应延迟尖峰 (%)", "0–100", \.responseSpikePercent)
                numberRow("丢包近似 (%)", "0–100", \.bodyPausePercent)
            }
            TextField("目标主机（空白表示所有主机）", text: $draft.host)
            Text("适用于转发到上游的 HTTP 请求。支持 *.example.com。速率为 0 时不限速。")
                .font(.caption).foregroundStyle(.secondary)
            Text("随机断连按请求抽样。响应尖峰在最终响应头前增加 500 ms。丢包近似按正文块抽样，暂停后按原顺序补发。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    draft.host = RulesSnapshot.sslHostPattern(draft.host)
                    if LatencyConditions.install(draft) { dismiss() }
                    else { error = "无法保存弱网设置" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationError != nil)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func numberRow(_ label: String, _ placeholder: String, _ field: WritableKeyPath<LatencyConditions, Int?>) -> some View {
        GridRow {
            Text(label)
            TextField(placeholder, value: Binding(
                get: { draft[keyPath: field] ?? 0 },
                set: { draft[keyPath: field] = $0 == 0 ? nil : $0 }
            ), format: .number.grouping(.never))
        }
    }
}
