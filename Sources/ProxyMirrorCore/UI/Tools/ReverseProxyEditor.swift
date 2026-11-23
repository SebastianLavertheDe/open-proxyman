import SwiftUI

struct ReverseProxyEditor: View {
    private struct Draft: Identifiable {
        var rule: ReverseProxyRule
        var localPort: String
        var upstreamPort: String

        var id: UUID { rule.id }

        init(_ rule: ReverseProxyRule) {
            self.rule = rule
            localPort = rule.listenPort == 0 ? "" : String(rule.listenPort)
            upstreamPort = String(rule.remotePort)
        }

        func validated() throws -> ReverseProxyRule {
            var copy = rule
            guard let local = UInt16(localPort), let upstream = Int(upstreamPort) else {
                throw ReverseProxyError.invalidRule(copy.name)
            }
            copy.listenPort = local
            copy.remotePort = upstream
            _ = try ReverseProxyRoute(copy)
            return copy
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var controller = ReverseProxyController.shared
    @State private var drafts: [Draft] = []
    @State private var error: String?
    @State private var folderDraft = RuleFolderEditingDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("反向代理").font(.headline)
            Text("启用的规则随代理启动，在 127.0.0.1 上接收 HTTP 请求并转发到配置的上游。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                if drafts.isEmpty {
                    Text("暂无反向代理规则")
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($drafts) { row($0) }
                    }
                    .padding(1)
                }
            }
            .frame(minHeight: 180, maxHeight: 360)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("添加规则") { drafts.append(Draft(ReverseProxyRule())) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)
        .onAppear { drafts = controller.rules.map(Draft.init); folderDraft = RuleFolderEditingDraft() }
    }

    private func row(_ draft: Binding<Draft>) -> some View {
        let value = draft.wrappedValue
        let savedPort = controller.rules.first { $0.id == value.id }?.listenPort
        let status = savedPort.flatMap { controller.errors[$0] }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle("启用", isOn: draft.rule.enabled)
                TextField("名称", text: draft.rule.name)
                Button(role: .destructive) {
                    drafts.removeAll { $0.id == value.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("移除规则")
            }
            RuleFolderPicker(tool: "reverse", ruleID: value.id.uuidString, draft: $folderDraft).id(value.id)
            HStack(spacing: 8) {
                Text("127.0.0.1")
                TextField("本地端口", text: draft.localPort).frame(width: 75)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("上游协议", selection: Binding(
                    get: { draft.wrappedValue.rule.remoteScheme ?? "http" },
                    set: { draft.wrappedValue.rule.remoteScheme = $0 }
                )) {
                    Text("HTTP").tag("http")
                    Text("HTTPS").tag("https")
                }
                .labelsHidden()
                .frame(width: 84)
                TextField("上游主机", text: draft.rule.remoteHost)
                TextField("上游端口", text: draft.upstreamPort).frame(width: 75)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.red)
            } else if let savedPort, controller.listening.contains(savedPort) {
                Text("监听中  127.0.0.1:\(savedPort)").font(.caption).foregroundStyle(.secondary)
            } else if value.rule.enabled && !appState.proxyRunning {
                Text("等待代理启动").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    private func save() {
        do {
            let rules = try drafts.map { try $0.validated() }
            let organization = try folderDraft.merging(into: RuleOrganizationStore.shared.snapshot(), tool: "reverse", keeping: Set(rules.map { $0.id.uuidString }))
            try controller.save(rules, organization: organization)
            dismiss()
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}
