import SwiftUI

struct H2CUpstreamSettings: View {
    @State private var draft = InterceptionConfig.shared.h2cUpstream.value
    @State private var hosts = InterceptionConfig.shared.h2cUpstream.value.hosts.joined(separator: ", ")
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("HTTP/2 流使用明文上游 (h2c)", isOn: $draft.enabled)
            if draft.enabled {
                TextField("目标主机，用逗号分隔", text: $hosts)
                Text("填入支持 h2c 的主机。适用于 HTTP/2 流转发到 HTTP 地址，例如 Map Remote 指向本地 gRPC 服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("应用 h2c 设置") {
                draft.hosts = hosts.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty }
                failed = !RulesFileIO.save(draft, "h2c.json")
                if !failed { InterceptionConfig.shared.h2cUpstream.set(draft) }
                message = failed ? "保存失败" : "h2c 设置已应用于新流量"
            }
            .disabled(draft.enabled && hosts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message { Text(message).font(.caption).foregroundStyle(failed ? .red : .secondary) }
        }
    }
}
