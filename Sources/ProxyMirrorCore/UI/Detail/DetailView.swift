import SwiftUI

/// 详情面板（Proxyman 26.10 实测：顶栏 方法/状态/URL + 左右分栏 Request | Response，
/// 每侧横向 tabs：头部|查看|原文|预览 (+ Connection Log)；Response 未解密时显示加密占位）
struct DetailView: View {
    @ObservedObject var store: TrafficStore

    var body: some View {
        Group {
            if let tx = store.selectedTransaction {
                DetailContentView(tx: tx, store: store)
            } else {
                emptyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProxymanTheme.tableBackground)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.6))
            Text("选择一条请求查看详情")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetailContentView: View {
    @ObservedObject var tx: Transaction
    let store: TrafficStore
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                methodBadge(tx.method)
                statusBadge(tx)
                let url = tx.originalURL ?? tx.fullURL
                if let schemeEnd = url.range(of: "://")?.upperBound {
                    (Text(url[..<schemeEnd]).foregroundColor(.secondary)
                     + Text(url[schemeEnd...]).foregroundColor(.blue))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(url).foregroundStyle(.blue).lineLimit(1).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Repeat") { appState.repeatRequest(tx) }.disabled(!tx.canReplay)
                    Button("Copy as cURL") { CopyPaste.copy(ExportService.curlCommand(tx)) }
                    Button("Copy URL") { CopyPaste.copy(tx.fullURL) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("请求操作")
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(ProxymanTheme.inspectorChrome)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }

            if tx.suspectedPinning { pinningBanner }

            // 左右分栏：Request | Response
            HSplitView {
                ContentSideView(tx: tx, side: .request)
                    .frame(minWidth: 200)
                ContentSideView(tx: tx, side: .response)
                    .frame(minWidth: 200)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func methodBadge(_ method: String) -> some View {
        Text(method)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 72, minHeight: 20)
            .background(Color.primary.opacity(0.10), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.14)) }
    }

    private func statusBadge(_ tx: Transaction) -> some View {
        Group {
            if tx.state == .failed {
                Text(tx.statusCode > 0 ? "\(tx.statusText) · 传输失败" : "传输失败")
                    .foregroundStyle(.red)
                    .help(tx.errorText ?? "")
            } else if tx.statusCode > 0 {
                let color = Color(nsColor: tx.statusColor)
                Text(tx.statusText)
                    .foregroundStyle(color)
                    .frame(minWidth: 72, minHeight: 20)
                    .background(color.opacity(0.15), in: Capsule())
                    .overlay { Capsule().strokeBorder(color.opacity(0.26)) }
            } else {
                Text(tx.isTunnel ? "建立隧道中" : "接收中").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
    }

    private var pinningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("疑似 SSL 证书锁定：客户端拒绝了代理证书，未发出明文请求。")
                .font(.system(size: 12))
            Spacer(minLength: 8)
            if let bundleID = tx.clientBundle, let name = tx.clientName {
                Button("对「\(name)」启用透传") { appState.enablePinningPassthrough(bundleID: bundleID, name: name) }
                    .controlSize(.small)
                    .help("此应用的新连接将使用透传。")
            }
            Button("不再解密此域") {
                var hosts = appState.settings.mitmExcludedHosts
                if !hosts.contains(tx.host) { hosts.append(tx.host) }
                appState.settings.mitmExcludedHosts = hosts
                ProxyEngine.shared.mitmExcludedHosts = hosts
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 1) }
    }
}

enum ContentSide {
    case request, response
}

private struct ContentSideView: View {
    enum Tab: String, CaseIterable {
        case headers = "头部", body = "正文", raw = "原文", preview = "预览"
        case query = "查询", cookies = "Cookies", auth = "Auth", connection = "Connection Log", chart = "耗时"
        case graphql = "GraphQL", summary = "摘要"
        case sse = "SSE", webSocket = "WebSocket"
    }

    @ObservedObject var tx: Transaction
    let side: ContentSide
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: Tab?
    @State private var tree = false
    @State private var search = ""
    @State private var treeResult: (input: TreeInput, root: JSONTreeNode?)?
    @State private var showingQuery = false
    @State private var decodedBody: (input: TreeInput, result: Result<(Data, String), ContentCoding.DecodeError>)?

    private struct TreeInput: Equatable {
        let transaction: ObjectIdentifier
        let revision: UInt64
    }

    private var isRequest: Bool { side == .request }
    private var tab: Tab { selectedTab ?? (!isRequest && tx.isWebSocket ? .webSocket : .headers) }
    private var capturedData: Data { isRequest ? tx.requestBody : tx.responseBody }
    private var contentEncodings: [String] {
        headers.values(of: "Content-Encoding").flatMap { header in
            header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }.filter { $0 != "identity" }
    }
    private var isCompressed: Bool { !contentEncodings.isEmpty }
    private var unsupportedEncodings: Bool { !contentEncodings.allSatisfy({ ContentCoding.supported.contains($0) }) }
    private var decodeInput: TreeInput? {
        guard tab == .body || tab == .preview, !tx.isWebSocket, !isEncryptedTunnel,
              isCompressed, !unsupportedEncodings, complete, !truncated, !capturedData.isEmpty else { return nil }
        return TreeInput(transaction: ObjectIdentifier(tx), revision: bodyRevision)
    }
    private var decodeResult: Result<(Data, String), ContentCoding.DecodeError>? {
        guard let input = decodeInput, decodedBody?.input == input else { return nil }
        return decodedBody?.result
    }
    private var decodedLabel: String? {
        guard case .success(let decoded) = decodeResult else { return nil }
        return decoded.1
    }
    private var messagePackApplied: Bool {
        MessagePackBody.decodeIfMessagePack(baseDecodedData, contentTypeHint: contentType) != nil
    }
    /// 仅 Content-Encoding 解码结果
    private var baseDecodedData: Data {
        if isCompressed {
            if case .success(let decoded) = decodeResult { return decoded.0 }
            return Data()
        }
        return capturedData
    }

    private var data: Data {
        MessagePackBody.decodeIfMessagePack(baseDecodedData, contentTypeHint: contentType) ?? baseDecodedData
    }
    private var bodyRevision: UInt64 { isRequest ? tx.requestBodyRevision : tx.responseBodyRevision }
    private var bodyGeneration: UInt64 { isRequest ? tx.requestBodyGeneration : tx.responseBodyGeneration }
    private var treeInput: TreeInput? {
        guard tab == .body, tree, !tx.isWebSocket, grpcMediaType == nil, !isHTTPProtobuf, search.isEmpty, !showingQuery, complete, !truncated,
              !data.isEmpty, data.count <= JSONTreeService.maxInput else { return nil }
        return TreeInput(transaction: ObjectIdentifier(tx), revision: bodyRevision)
    }
    private var headers: HTTPHeaders { isRequest ? tx.requestHeaders : tx.responseHeaders }
    private var trailers: HTTPHeaders { isRequest ? tx.requestTrailers : tx.responseTrailers }
    private var contentType: String { headers.value(of: "Content-Type") ?? "" }
    private var complete: Bool { isRequest ? tx.requestBodyComplete : tx.responseBodyComplete }
    private var truncated: Bool { isRequest ? tx.requestTruncated : tx.responseTruncated }
    private var receivedBytes: Int { isRequest ? tx.requestBytes : tx.responseBytes }
    private var grpcMediaType: GRPCFrames.MediaType? {
        if let media = GRPCFrames.contentType(contentType) { return media }
        guard !isRequest, headers.contains("grpc-status") || trailers.contains("grpc-status") else { return nil }
        return GRPCFrames.contentType(tx.requestHeaders.value(of: "Content-Type") ?? "") ?? .native
    }
    private var isHTTPProtobuf: Bool {
        HTTPProtobuf.matches(contentType: contentType, query: tx.query, isRequest: isRequest)
    }
    private var isJSON: Bool {
        if contentType.localizedCaseInsensitiveContains("json") { return true }
        return data.prefix(256).first { ![9, 10, 13, 32].contains($0) }.map { $0 == 123 || $0 == 91 } ?? false
    }

    private var queryUnavailable: String? {
        if truncated { return "正文已截断，完整捕获后可运行查询。" }
        if !complete { return "等待完整正文…" }
        if data.count > JSONPath.maxInputBytes { return "查询支持最大 1 MiB 的正文。" }
        return nil
    }
    private var isEncryptedTunnel: Bool { tx.isTunnel && !tx.isTLSIntercepted }

    private var tabs: [Tab] {
        if isRequest {
            return [.headers, .query, .body, .raw, .summary, .connection]
        }
        var response: [Tab] = [.headers, .body, .raw, .summary, .chart]
        if tx.isWebSocket { response.insert(.webSocket, at: 1) }
        if tx.isSSE, let index = response.firstIndex(of: .body) { response.insert(.sse, at: index + 1) }
        return isEncryptedTunnel ? [] : response
    }

    private var additionalTabs: [Tab] {
        isRequest ? [.preview, .cookies, .auth, .graphql] : [.preview, .cookies]
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            if !isRequest && isEncryptedTunnel {
                encryptedResponse
            } else {
                if let error = tx.errorText, !isRequest {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                if truncated {
                    Text("正文已截断 · 捕获 \(capturedData.count) / \(receivedBytes) 字节")
                        .font(.caption).foregroundStyle(.orange).padding(4)
                }
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isRequest ? ProxymanTheme.inspectorChrome : ProxymanTheme.tableBackground)
        .onChange(of: tx.isWebSocket) { _ in selectedTab = nil }
        .onChange(of: ObjectIdentifier(tx)) { _ in
            search = ""
            showingQuery = false
            decodedBody = nil
        }
        .task(id: decodeInput) {
            guard let input = decodeInput, decodedBody?.input != input else { return }
            let compressed = capturedData
            let encodings = contentEncodings
            let worker = Task.detached(priority: .userInitiated) {
                ContentCoding.decodeIfCompressed(compressed, encodings: encodings)
                    ?? .failure(ContentCoding.DecodeError.invalidStream)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { decodedBody = (input, result) }
        }
        .task(id: treeInput) {
            guard let input = treeInput else { treeResult = nil; return }
            let body = data
            let worker = Task.detached(priority: .userInitiated) { JSONTreeService.build(from: body) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { treeResult = (input, result) }
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 9) {
            Text(isRequest ? "Request" : "Response")
                .font(.system(size: 12, weight: .bold))
                .fixedSize()
            if !tabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(tabs, id: \.self) { tabButton($0) }
                        if additionalTabs.contains(tab) { tabButton(tab) }
                        Menu {
                            ForEach(additionalTabs, id: \.self) { candidate in
                                Button(candidate.rawValue) { selectedTab = candidate }
                            }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 10))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("更多详情标签")
                    }
                }
            } else {
                Spacer()
            }
            if receivedBytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 31)
        .background(ProxymanTheme.inspectorChrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
    }

    private func tabButton(_ candidate: Tab) -> some View {
        Button { selectedTab = candidate } label: {
            Text(candidate == .body ? grpcMediaType?.transport.label ?? candidate.rawValue : candidate.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tab == candidate ? Color.accentColor : Color.secondary)
                .fixedSize()
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == candidate ? .isSelected : [])
    }

    private var encryptedResponse: some View {
        VStack(spacing: 8) {
            Label("HTTPS 响应", systemImage: "lock")
                .font(.system(size: 17, weight: .medium))
            Text("此 HTTPS 响应已加密。\n启用 SSL 代理以查看内容。")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
            Button("仅启用此域") { appState.enableSSLProxying(for: tx) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 5)
            if let name = tx.clientName, tx.clientBundle != nil {
                Text("或者").font(.system(size: 12))
                Button("为「\(name)」配置 SSL 代理…") { appState.openTool(.sslApplications, transaction: tx) }
                    .controlSize(.small)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .headers:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    fields(isRequest ? "请求头" : "响应头", headers.pairs.map { ($0.name, $0.value) })
                    if trailers.count > 0 { fields("Trailers", trailers.pairs.map { ($0.name, $0.value) }) }
                }.padding(10)
            }
        case .webSocket:
            WSFramesView(tx: tx)
                .id(ObjectIdentifier(tx))
        case .body:
            if tx.isWebSocket {
                WSFramesView(tx: tx, direction: isRequest ? .upstream : .downstream)
                    .id(ObjectIdentifier(tx))
            } else {
                inspectBody {
                    if let grpcMediaType {
                        GRPCInspectorView(data: baseDecodedData, bodyRevision: bodyRevision,
                                          bodyGeneration: bodyGeneration,
                                          headers: headers, trailers: trailers,
                                          complete: complete || tx.state == .failed, truncated: truncated,
                                          path: tx.path, isRequest: isRequest, mediaType: grpcMediaType)
                            .id(ObjectIdentifier(tx))
                    } else if isHTTPProtobuf {
                        HTTPProtobufView(data: baseDecodedData, revision: bodyRevision, generation: bodyGeneration,
                                         complete: complete || tx.state == .failed, truncated: truncated,
                                         isError: !isRequest && (400...599).contains(tx.statusCode),
                                         decodedEncoding: decodedLabel)
                            .id(ObjectIdentifier(tx))
                    } else {
                        bodyInspector
                    }
                }
            }
        case .sse:
            SseEventsView(tx: tx)
                .id(ObjectIdentifier(tx))
        case .raw:
            rawInspector
        case .preview:
            inspectBody {
                BodyContentView(data: tx.isWebSocket ? capturedData : data, contentType: contentType, pretty: true,
                                complete: complete || tx.state == .failed, truncated: truncated, revision: bodyRevision,
                                generation: bodyGeneration)
                    .id(ObjectIdentifier(tx))
            }
        case .query:
            let items = URLComponents(string: "?\(tx.query)")?.queryItems ?? []
            if items.isEmpty {
                Text("没有查询").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    fields("查询参数", items.map { ($0.name, $0.value ?? "") }).padding(10)
                }
            }
        case .cookies:
            let name = isRequest ? "Cookie" : "Set-Cookie"
            let values = headers.values(of: name)
            let entries = isRequest ? values.flatMap { $0.components(separatedBy: ";") } : values
            ScrollView { fields(name, entries.map { (name, $0.trimmingCharacters(in: .whitespaces)) }).padding(10) }
        case .auth:
            let entries = headers.pairs.filter { ["authorization", "proxy-authorization"].contains($0.name.lowercased()) }
            ScrollView { fields("认证头", entries.map { ($0.name, $0.value) }).padding(10) }
        case .graphql:
            ScrollView {
                if let info = GraphQLService.detect(tx: tx, inspectResponse: false) {
                    fields("GraphQL", [("操作", info.operationName), ("类型", info.operationType),
                                      ("文档", info.queryText), ("变量", info.variablesText)]).padding(10)
                } else {
                    Text("未识别到 GraphQL 操作").font(.caption).foregroundStyle(.secondary).padding(10)
                }
            }
        case .connection:
            ScrollView {
                fields("连接日志", [
                    ("客户端", tx.clientName ?? "未知"),
                    ("客户端地址", tx.clientAddress ?? "暂无"),
                    ("目标", tx.fullURL),
                    ("原始目标", tx.originalURL ?? tx.fullURL),
                    ("抓包入口", tx.isTransparent ? "透明代理" : "—"),
                    ("DNS 映射地址", tx.resolvedAddress ?? "无"),
                    ("客户端协议", tx.requestVersion),
                    ("上游协议", tx.upstreamProtocol ?? (tx.statusCode == 0 ? "暂无" : tx.responseVersion)),
                    ("上游连接地址", tx.connectionDetails?.address ?? "暂无"),
                    ("外部代理", tx.connectionDetails?.externalProxy ?? "直连或无连接"),
                    ("上游 ALPN", tx.connectionDetails?.alpn ?? "暂无"),
                    ("DNS 解析", connectionDuration(tx.connectionDetails?.dnsMilliseconds)),
                    ("TCP / 代理连接", connectionDuration(tx.connectionDetails?.tcpMilliseconds)),
                    ("TLS 握手", connectionDuration(tx.connectionDetails?.tlsMilliseconds)),
                    ("连接复用", tx.connectionDetails?.reused == true ? "已复用" : "新建或暂无"),
                    ("客户端流 ID", tx.connectionDetails?.downstreamStream.map(String.init) ?? "–"),
                    ("上游流 ID", tx.connectionDetails?.upstreamStream.map(String.init) ?? "–"),
                    ("已建立连接", tx.tConnected.map { $0.formatted() } ?? "暂无"),
                    ("收到响应头", tx.tHeaderAt.map { $0.formatted() } ?? "暂无"),
                    ("命中规则", tx.ruleMatches.isEmpty ? "无" : tx.ruleMatches.joined(separator: " → ")),
                    ("脚本执行", tx.scriptingLogs.isEmpty ? "无" : tx.scriptingLogs.joined(separator: "\n")),
                ]).padding(10)
            }
        case .summary:
            ScrollView {
                fields("摘要", [
                    ("网址", tx.originalURL ?? tx.fullURL),
                    ("方法", tx.method),
                    ("状态", tx.statusCode > 0 ? tx.statusText : "–"),
                    ("协议", isRequest ? tx.requestVersion : tx.responseVersion),
                    ("持续时间", tx.durationText),
                ]).padding(10)
            }
        case .chart:
            TimingChartView(tx: tx)
        }
    }

    private func connectionDuration(_ milliseconds: Double?) -> String {
        milliseconds.map { String(format: "%.1f ms", $0) } ?? "–"
    }

    @ViewBuilder
    private func inspectBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if !isCompressed || capturedData.isEmpty || tx.isWebSocket {
            content()
        } else if truncated {
            compressedBody("正文已截断，无法解压。")
        } else if tx.state == .failed && !complete {
            compressedBody("响应未完整接收，无法解压。")
        } else if unsupportedEncodings {
            compressedBody("暂不支持 Content-Encoding: \(contentEncodings.joined(separator: ", "))。")
        } else if !complete {
            ProgressView("等待接收完整正文…").controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch decodeResult {
            case .success:
                content()
            case .failure(let error):
                switch error {
                case .outputLimit:
                    compressedBody("解压后的正文超过 32 MiB。")
                case .unsupported(let list):
                    compressedBody("暂不支持 Content-Encoding: \(list.joined(separator: ", "))。")
                case .invalidStream:
                    compressedBody("无法解压 \(contentEncodings.joined(separator: ", ")) 压缩正文。")
                }
            case nil:
                ProgressView("正在解压…").controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func compressedBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(message).font(.caption).foregroundStyle(.secondary).padding(6)
            HexView(data: capturedData, generation: bodyGeneration)
                .id(ObjectIdentifier(tx))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bodyInspector: some View {
        VStack(spacing: 0) {
            if !data.isEmpty {
                HStack {
                    if !showingQuery {
                        TextField("搜索正文", text: $search).textFieldStyle(.roundedBorder)
                        if isJSON {
                            Toggle("JSON 树", isOn: $tree).toggleStyle(.checkbox)
                        }
                    } else {
                        Text("JSON 查询").font(.caption.weight(.semibold))
                        Spacer()
                    }
                    Spacer(minLength: 8)
                    if messagePackApplied {
                        Text("已解码 MessagePack")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .help("MessagePack 正文已转换为 JSON")
                    }
                    if let label = decodedLabel {
                        Text("已解码 \(label)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .help("已按 Content-Encoding 自动解压")
                    }
                    if isJSON {
                        Button(showingQuery ? "返回正文" : "查询") {
                            showingQuery.toggle()
                        }
                        .accessibilityLabel(showingQuery ? "返回正文" : "查询 JSON 正文")
                    }
                }
                .controlSize(.small).padding(5)
            }
            if showingQuery {
                BodyQueryView(data: data, unavailableReason: queryUnavailable).id(ObjectIdentifier(tx))
            } else if !search.isEmpty {
                BodySearchResults(data: data, revision: bodyRevision, query: search)
                    .id(ObjectIdentifier(tx))
            } else if let treeInput, treeResult?.input != treeInput {
                ProgressView("正在解析 JSON…").controlSize(.small)
            } else if treeInput != nil, let treeRoot = treeResult?.root {
                ScrollView {
                    JSONTreeNodesView(node: treeRoot)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            } else {
                BodyContentView(data: data, contentType: contentType, pretty: true,
                                complete: complete || tx.state == .failed, truncated: truncated, revision: bodyRevision,
                                generation: bodyGeneration)
                    .id(ObjectIdentifier(tx))
            }
        }
    }

    private var rawInspector: some View {
        let isHTTP2 = (isRequest ? tx.requestVersion : tx.responseVersion) == "HTTP/2"
        let startLine: String = {
            if isHTTP2 {
                if !isRequest { return tx.statusCode > 0 ? ":status: \(tx.statusCode)" : "" }
                let authority = URLParser.authority(host: tx.host, port: tx.port, scheme: tx.scheme)
                return ":method: \(tx.method)\r\n:scheme: \(tx.scheme)\r\n:authority: \(authority)\r\n:path: \(tx.urlText)"
            }
            return isRequest ? "\(tx.method) \(tx.urlText) \(tx.requestVersion)"
                : (tx.statusCode > 0 ? "\(tx.responseVersion) \(tx.statusText)" : "")
        }()
        let head = RawMessageHead(startLine: startLine, headers: headers)
        let bytes = capturedData
        let binary = !bytes.isEmpty && (tx.isWebSocket || isCompressed || BodyContentView.isBinary(data: bytes, contentType: contentType))
        return VStack(alignment: .leading, spacing: 0) {
            Text(tx.isWebSocket ? "握手头部和原始 WebSocket 帧字节" :
                 isHTTP2 ? "HTTP/2 伪头部、解码后的头部和正文" : "按捕获的首行、头部和已解帧正文重组")
                .font(.caption).foregroundStyle(.secondary).padding(6)
            if !complete && tx.state != .failed {
                Text("捕获中").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    RawMessageHeadView(head: head).equatable()
                    if binary {
                        Text("二进制正文").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                    }
                    BodyPreview(data: bytes, format: binary ? .hex : .text, generation: bodyGeneration, rawHead: head) {
                        scroll.scrollTo(BodyPreview.ScrollAnchor.pageTop, anchor: .top)
                    }
                    .id(ObjectIdentifier(tx))
                    if trailers.count > 0 {
                        fields("Trailers", trailers.pairs.map { ($0.name, $0.value) }).padding(10)
                    }
                }
            }
        }
    }

    private func fields(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if rows.isEmpty { Text("无").font(.caption).foregroundStyle(.secondary) }
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Text(rows[index].0).fontWeight(.medium).frame(minWidth: 70, idealWidth: 108, alignment: .leading)
                    Text(rows[index].1).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct BodySearchResults: View {
    let data: Data
    let revision: UInt64
    let query: String
    @State private var result: SearchResult?

    private struct Key: Equatable {
        let revision: UInt64
        let query: String
    }

    private struct SearchResult: Sendable {
        let text: String
        let total: Int
    }

    var body: some View {
        Group {
            if let result {
                ScrollView {
                    Text(result.total == 0 ? "无匹配内容" : result.text)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                Text("搜索正文前 1 MiB · 显示 \(min(result.total, 200))/\(result.total) 行")
                    .font(.caption).foregroundStyle(.secondary).padding(4)
            } else {
                ProgressView("正在搜索…").controlSize(.small)
            }
        }
        .task(id: Key(revision: revision, query: query)) {
            let worker = Task.detached(priority: .userInitiated) { Self.find(data, query: query) }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { result = matches }
        }
    }

    private static func find(_ data: Data, query: String) -> SearchResult {
        let text = String(decoding: data.prefix(1_048_576), as: UTF8.self)
        var lines: [String] = []
        var total = 0
        text.enumerateLines { line, stop in
            guard !Task.isCancelled else { stop = true; return }
            if line.localizedCaseInsensitiveContains(query) {
                total += 1
                if lines.count < 200 { lines.append(line) }
            }
        }
        return SearchResult(text: lines.joined(separator: "\n"), total: total)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
