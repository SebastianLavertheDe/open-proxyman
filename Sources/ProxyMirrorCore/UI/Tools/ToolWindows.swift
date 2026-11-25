import SwiftUI

// MARK: - 工具窗口类型（对齐 Proxyman Tools 菜单）

enum ToolKind: String, Identifiable, CaseIterable {
    case compose, mapLocal, mapRemote, blockList, allowList, sslProxyingList
    case sslApplications, dnsMapping, reverseProxy, customCertificates
    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .compose: return Strings.Tools.composeRequest
        case .mapLocal: return Strings.Tools.mapLocal
        case .mapRemote: return Strings.Tools.mapRemote
        case .blockList: return Strings.Tools.blockList
        case .allowList: return Strings.Tools.allowList
        case .sslProxyingList: return Strings.Tools.sslProxyingList
        case .sslApplications: return Strings.Tools.sslByApplication
        case .dnsMapping: return Strings.Tools.dnsMapping
        case .reverseProxy: return Strings.Tools.reverseProxy
        case .customCertificates: return Strings.Tools.customServerCertificates
        }
    }
    var searchAliases: [String] {
        let key: String
        switch self {
        case .compose: key = "compose_request"
        case .mapLocal: key = "map_local"
        case .mapRemote: key = "map_remote"
        case .blockList: key = "block_list"
        case .allowList: key = "allow_list"
        case .sslProxyingList: key = "ssl_proxying_list"
        case .sslApplications: key = "ssl_by_application"
        case .dnsMapping: key = "dns_mapping"
        case .reverseProxy: key = "reverse_proxy"
        case .customCertificates: key = "custom_server_certificates"
        }
        return [rawValue,
                L10n.render(table: "Tools", key: key, englishFallback: rawValue, language: "en"),
                L10n.render(table: "Tools", key: key, englishFallback: rawValue, language: "zh-Hans")]
    }

}

struct ComposeRequestView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction?

    @State private var method = "GET"
    @State private var url = ""
    @State private var headers = ""
    @State private var query = ""
    @State private var bodyText = ""
    @State private var binaryBody: Data?
    @State private var rawText = ""
    @State private var rawMode = false
    @State private var direct = false
    @State private var error: String?
    @State private var result: Transaction?
    @State private var task: ComposeService.RequestTask?
    @State private var importingCurl = false
    @State private var curlText = ""
    @State private var timeoutSeconds = 60
    @State private var followRedirects = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(transaction == nil ? Strings.Tools.composeRequest : Strings.Tools.editAndResend).font(.headline)
                Spacer()
                Toggle(Strings.Tools.direct, isOn: $direct).help(Strings.Tools.whenDisabledRequestsPassThroughProxymirrorRules)
                Button(task == nil ? Strings.Tools.close : Strings.Tools.cancelRequest) {
                    if let task { task.cancel() } else { dismiss() }
                }
                Button(Strings.Tools.send) { execute() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(task != nil)
            }

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker(Strings.Tools.editor, selection: Binding(get: { rawMode }, set: changeMode)) {
                            Text(Strings.Tools.form).tag(false)
                            Text(Strings.Tools.raw).tag(true)
                        }
                        .pickerStyle(.segmented)
                        Menu(Strings.Tools.template) {
                            ForEach(ComposeService.Template.allCases) { template in
                                Button(template.localizedTitle) { load(template.request(url: url)) }
                            }
                            Button(Strings.Tools.importCurl) { importingCurl = true }
                        }
                        Menu(Strings.Tools.history) {
                            ForEach(appState.composeHistory.indices, id: \.self) { index in
                                let item = appState.composeHistory[index]
                                Button("\(item.method) \(item.url)") { load(item) }
                            }
                        }
                        .disabled(appState.composeHistory.isEmpty)
                    }
                    HStack {
                        Picker(Strings.Tools.timeout, selection: $timeoutSeconds) {
                            Text(Strings.Tools.unlimited).tag(0); Text(Strings.Tools.step15Seconds).tag(15); Text(Strings.Tools.step30Seconds).tag(30); Text(Strings.Tools.step60Seconds).tag(60)
                            if ![0, 15, 30, 60].contains(timeoutSeconds) { Text(Strings.Tools.seconds(Int(timeoutSeconds))).tag(timeoutSeconds) }
                        }.frame(width: 165)
                        Toggle(Strings.Tools.followRedirects, isOn: $followRedirects)
                    }
                    if url.hasPrefix("ws://") || url.hasPrefix("wss://") {
                        Text(Strings.Tools.websocketSendsTheBodyAsTheFirstMessageThen)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if rawMode {
                        editor(Strings.Tools.httpMessage, text: $rawText)
                    } else {
                        HStack {
                            TextField(Strings.Tools.method, text: $method).frame(width: 74)
                            TextField("https://example.com/path", text: $url)
                        }
                        .textFieldStyle(.roundedBorder)
                        TextField(Strings.Tools.queryParametersForExampleTagATagB, text: $query).textFieldStyle(.roundedBorder)
                        editor(Strings.Tools.requestHeaders, text: $headers).frame(minHeight: 100)
                        if let binaryBody {
                            HStack {
                                Text(Strings.Tools.retainedBytesOfBinaryBody(Int(binaryBody.count)))
                                Button(Strings.Tools.replaceWithText) { self.binaryBody = nil }
                            }
                        } else {
                            editor(Strings.Tools.body, text: $bodyText).frame(minHeight: 100)
                        }
                    }
                }
                .frame(minWidth: 350)

                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.Tools.response).font(.headline)
                    if let result {
                        Text(result.state == .failed ? result.localizedErrorText ?? Strings.Tools.sendFailed : result.statusText)
                            .font(.system(.body, design: .monospaced))
                        BodyContentView(data: result.responseBody, contentType: result.contentType, pretty: true,
                                        complete: result.responseBodyComplete, truncated: result.responseTruncated,
                                        revision: result.responseBodyRevision)
                            .id(ObjectIdentifier(result))
                    } else if task != nil {
                        ProgressView(Strings.Tools.waitingForResponse).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(Strings.Tools.noResponseYet).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.leading, 8)
                .frame(minWidth: 270)
            }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(16)
        .frame(width: 780, height: 520)
        .onAppear {
            if appState.composeHistory.isEmpty { appState.composeHistory = ComposeService.loadHistory() }
            if let transaction {
                if let request = ComposeService.replayRequest(from: transaction) {
                    load(request)
                } else {
                    error = Strings.Tools.theRequestBodyIsIncompleteAndCannotPrefillThe
                }
            }
        }
        .onDisappear { task?.cancel() }
        .sheet(isPresented: $importingCurl) {
            VStack(alignment: .leading, spacing: 10) {
                editor(Strings.Tools.curlCommand, text: $curlText)
                HStack {
                    Spacer()
                    Button(Strings.Tools.cancel) { importingCurl = false }
                    Button(Strings.Tools.import) {
                        if let parsed = ComposeService.parseCurl(curlText) {
                            load(parsed)
                            error = nil
                        } else {
                            error = Strings.Tools.unableToParseCurlImportSupportsAUrlMethod
                        }
                        importingCurl = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 520, height: 250)
        }
    }

    private func editor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel(title)
                .overlay(Rectangle().strokeBorder(.quaternary))
        }
    }

    private func load(_ request: ComposeService.ParsedRequest) {
        method = request.method
        timeoutSeconds = request.timeoutSeconds
        followRedirects = request.followRedirects
        if var components = URLComponents(string: request.url) {
            query = components.percentEncodedQuery ?? ""
            components.percentEncodedQuery = nil
            url = components.string ?? request.url
        } else {
            url = request.url
            query = ""
        }
        headers = request.headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        bodyText = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        binaryBody = bodyText.isEmpty && request.body?.isEmpty == false ? request.body : nil
        rawText = ComposeService.rawText(from: request)
    }

    private func parsed() -> ComposeService.ParsedRequest? {
        if rawMode {
            var request = ComposeService.parse(rawText)
            request?.timeoutSeconds = timeoutSeconds
            request?.followRedirects = followRedirects
            return request
        }
        guard var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.host != nil else { return nil }
        if !query.isEmpty {
            guard let parsedQuery = URLComponents(string: "https://localhost/?" + query), parsedQuery.fragment == nil else { return nil }
            components.percentEncodedQuery = parsedQuery.percentEncodedQuery
        }
        guard let target = components.string else { return nil }
        let raw = "\(method) \(target) HTTP/1.1\n\(headers)\n\n\(bodyText)"
        guard var request = ComposeService.parse(raw) else { return nil }
        if let binaryBody { request.body = binaryBody }
        request.timeoutSeconds = timeoutSeconds
        request.followRedirects = followRedirects
        return request
    }

    private func changeMode(_ raw: Bool) {
        if raw {
            guard binaryBody == nil else {
                error = Strings.Tools.keepTheBinaryBodyInFormModeOrReplace
                return
            }
            if let request = parsed() { rawText = ComposeService.rawText(from: request) }
        } else if let request = parsed() {
            load(request)
        } else if !rawText.isEmpty {
            error = Strings.Tools.correctTheRawMessageBeforeSwitchingToFormMode
            return
        }
        error = nil
        rawMode = raw
    }

    private func execute() {
        guard let request = parsed() else { error = Strings.Tools.enterAValidHttpMethodAndUrl; return }
        if !direct && !appState.proxyRunning { appState.startProxy(automaticallyTakeOver: false) }
        guard direct || appState.proxyRunning else { error = appState.proxyStartError; return }
        error = nil
        result = nil
        let proxyPort = direct ? nil : appState.listenerPort
        appState.composeHistory.insert(request, at: 0)
        if appState.composeHistory.count > 20 { appState.composeHistory.removeLast() }
        ComposeService.saveHistory(appState.composeHistory)
        task = ComposeService.execute(request, runtime: appState.runtimeContext, proxyPort: proxyPort) { tx in
            task = nil
            result = tx
            if proxyPort == nil || tx.state == .failed { appState.store.add(tx) }
        }
        if task == nil { error = Strings.Tools.theUrlMustUseHttpHttpsWsOrWss }
    }
}
