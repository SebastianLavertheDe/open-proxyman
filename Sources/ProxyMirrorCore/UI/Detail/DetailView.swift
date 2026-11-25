import SwiftUI
import ProxyMirrorFoundation

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
            Text(Strings.Detail.selectARequestToInspectItsDetails)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetailContentView: View {
    @ObservedObject var tx: Transaction
    let store: TrafficStore
    var navigationEnabled = true
    @EnvironmentObject var appState: AppState
    @AppStorage("ui.truncationStyle") private var truncation = "middle"
    @ObservedObject private var presentationSettings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if navigationEnabled {
                    Button { store.navigateSelectionHistory(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).disabled(!store.canNavigateBackward).help(Strings.Detail.previousInspectedRequest)
                    Button { store.navigateSelectionHistory(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless).disabled(!store.canNavigateForward).help(Strings.Detail.nextInspectedRequest)
                }
                methodBadge(tx.method)
                statusBadge(tx)
                let url = tx.originalURL ?? tx.fullURL
                if let schemeEnd = url.range(of: "://")?.upperBound {
                    (Text(url[..<schemeEnd]).foregroundColor(.secondary)
                     + Text(url[schemeEnd...]).foregroundColor(.blue))
                        .lineLimit(1)
                        .truncationMode(truncation == "head" ? .head : truncation == "tail" ? .tail : .middle)
                        .textSelection(.enabled)
                } else {
                    Text(url).foregroundStyle(.blue).lineLimit(1).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Menu {
                    Button(Strings.Detail.messageRepeat) { appState.repeatRequest(tx) }.disabled(!tx.canReplay)
                    Button(Strings.Detail.copyAsCurl) { appState.copyRequestsAsCurl([tx]) }
                    Button(Strings.Detail.copyUrl) { appState.copyText(tx.fullURL) }
                    Button(Strings.Detail.createProtobufMapping) {
                        ProtobufRuleStore.shared.addRule(for: tx.fullURL)
                        NotificationCenter.default.post(name: .pmOpenProtobuf, object: nil)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Strings.Detail.requestActions)
            }
            .font(PresentationFonts.swiftUIFont(weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: max(32, CGFloat(presentationSettings.fontSize) + 18))
            .background(ProxymanTheme.inspectorChrome)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }

            if tx.suspectedPinning { pinningBanner }

            Group {
                if presentationSettings.contentDividerIsVertical {
                    HSplitView {
                        ContentSideView(tx: tx, side: .request).frame(minWidth: 180)
                        ContentSideView(tx: tx, side: .response).frame(minWidth: 180)
                    }
                } else {
                    VSplitView {
                        ContentSideView(tx: tx, side: .request).frame(minHeight: 100)
                        ContentSideView(tx: tx, side: .response).frame(minHeight: 100)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func methodBadge(_ method: String) -> some View {
        Text(method)
            .font(PresentationFonts.swiftUIFont(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 72, minHeight: 20)
            .background(Color.primary.opacity(0.10), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.14)) }
    }

    private func statusBadge(_ tx: Transaction) -> some View {
        Group {
            if tx.state == .failed {
                Text(tx.statusCode > 0 ? Strings.Detail.transferFailed(String(describing: tx.statusText)) : Strings.Detail.transportFailed)
                    .foregroundStyle(.red)
                    .help(tx.localizedErrorText ?? "")
            } else if tx.statusCode > 0 {
                let color = Color(nsColor: tx.statusColor)
                Text(tx.statusText)
                    .foregroundStyle(color)
                    .frame(minWidth: 72, minHeight: 20)
                    .background(color.opacity(0.15), in: Capsule())
                    .overlay { Capsule().strokeBorder(color.opacity(0.26)) }
            } else {
                Text(tx.isTunnel ? Strings.Detail.establishingTunnel : Strings.Detail.receiving2).foregroundStyle(.secondary)
            }
        }
        .font(PresentationFonts.swiftUIFont(size: 11, weight: .semibold))
    }

    private var pinningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text(Strings.Detail.possibleSslCertificatePinningTheClientRejectedTheProxyCertificateAnd)
                .font(.system(size: 12))
            Spacer(minLength: 8)
            if let bundleID = tx.clientBundle, let name = tx.clientName {
                Button(Strings.Detail.enablePassthroughFor(String(describing: name))) { appState.enablePinningPassthrough(bundleID: bundleID, name: name) }
                    .controlSize(.small)
                    .help(Strings.Detail.newConnectionsFromThisApplicationWillUsePassthrough)
            }
            Button(Strings.Detail.stopDecryptingThisDomain) {
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
        case headers, body, raw, preview, query, cookies, auth, connection, chart, graphql, summary, sse, webSocket, multipart

        var localizedTitle: String {
            switch self {
            case .headers: return Strings.Detail.headers
            case .body: return Strings.Detail.body
            case .raw: return Strings.Detail.raw
            case .preview: return Strings.Detail.preview
            case .query: return Strings.Detail.query
            case .cookies: return "Cookie"
            case .auth: return Strings.Detail.authentication
            case .connection: return Strings.Detail.connectionLog
            case .chart: return Strings.Detail.timing
            case .graphql: return "GraphQL"
            case .summary: return Strings.Detail.summary
            case .sse: return "SSE"
            case .webSocket: return "WebSocket"
            case .multipart: return Strings.Detail.bodyToolsForm
            }
        }
    }

    @ObservedObject var tx: Transaction
    let side: ContentSide
    @ObservedObject private var presentationSettings = AppSettings.shared
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: Tab?
    @State private var tree = false
    @State private var search = ""
    @FocusState private var bodySearchFocused: Bool
    @State private var bodyWindow = BodyWindowReference()
    @State private var treeResult: (input: TreeInput, root: JSONTreeNode?)?
    @State private var showingQuery = false
    @State private var showCapturedBytes = false
    @State private var decodedBody: (input: TreeInput, result: Result<(Data, String), ContentCoding.DecodeError>)?
    @State private var bodyInspection: (input: InspectionInput, value: HTTPBodyInspection)?
    @State private var inspectionEpoch: UInt64 = 0
    @ObservedObject private var previewers = CustomPreviewerStore.shared
    @ObservedObject private var protobufRules = ProtobufRuleStore.shared
    @State private var customPreviewerID: UUID?
    @State private var forceHex = false
    @State private var exportCapturedBytes = false
    @State private var formattedBody: (key: BodyInspectionKey, text: String, markup: Bool)?
    @State private var formatIssue = false
    @State private var exportingBody = false

    private typealias TreeInput = BodyInspectionKey
    private typealias InspectionInput = BodyInspectionKey
    private var currentBodyKey: BodyInspectionKey {
        .init(transaction: ObjectIdentifier(tx), revision: bodyRevision, encodings: contentEncodings,
              contentType: contentType, complete: complete, truncated: truncated, epoch: inspectionEpoch)
    }

    private var isRequest: Bool { side == .request }
    private var tab: Tab { selectedTab ?? (!isRequest && tx.isWebSocket ? .webSocket : .headers) }
    private var capturedData: Data { isRequest ? tx.requestBody : tx.responseBody }
    private var declaredContentEncodings: [String] {
        headers.values(of: "Content-Encoding").flatMap { header in
            header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }.filter { !$0.isEmpty && $0 != "identity" }
    }
    private var contentEncodings: [String] {
        ContentCoding.inspectionEncodings(capturedData, declared: declaredContentEncodings)
    }
    private var isCompressed: Bool { !contentEncodings.isEmpty }
    private var unsupportedEncodings: Bool { !contentEncodings.allSatisfy({ ContentCoding.supported.contains($0) }) }
    private var decodeInput: TreeInput? {
        guard tab == .body || tab == .preview || tab == .multipart || (tab == .raw && !showCapturedBytes),
              !tx.isWebSocket, !isEncryptedTunnel,
              isCompressed, !unsupportedEncodings, complete, !truncated, !capturedData.isEmpty else { return nil }
        return currentBodyKey
    }
    private var decodeResult: Result<(Data, String), ContentCoding.DecodeError>? {
        guard let input = decodeInput, decodedBody?.input == input else { return nil }
        return decodedBody?.result
    }
    private var decodedLabel: String? {
        guard case .success(let decoded) = decodeResult else { return nil }
        return decoded.1
    }
    private var inspectedBody: HTTPBodyInspection {
        guard let input = inspectionInput else {
            return .init(data: baseDecodedData, contentType: contentType)
        }
        guard bodyInspection?.input == input, let value = bodyInspection?.value else {
            return .init(data: Data(), contentType: contentType)
        }
        return value
    }
    private var inspectionInput: InspectionInput? {
        guard tab == .body || tab == .preview || tab == .multipart || (tab == .raw && !showCapturedBytes),
              !tx.isWebSocket, !isEncryptedTunnel, complete, !truncated else { return nil }
        if isCompressed, decodedLabel == nil { return nil }
        return currentBodyKey
    }
    private var inspectionPending: Bool { inspectionInput.map { bodyInspection?.input != $0 } ?? false }
    private var payloadConverted: Bool { inspectedBody.format != nil }
    /// 仅 Content-Encoding 解码结果
    private var baseDecodedData: Data {
        if isCompressed {
            if case .success(let decoded) = decodeResult { return decoded.0 }
            return Data()
        }
        return capturedData
    }

    private var data: Data { inspectedBody.data }
    private var treeUnavailableReason: String? {
        JSONTreeAvailability.unavailableReason(bytes: data.count, complete: complete, truncated: truncated)
    }
    private var bodyRevision: UInt64 { isRequest ? tx.requestBodyRevision : tx.responseBodyRevision }
    private var bodyGeneration: UInt64 { isRequest ? tx.requestBodyGeneration : tx.responseBodyGeneration }
    private var treeInput: TreeInput? {
        guard tab == .body, tree, !tx.isWebSocket, grpcMediaType == nil, !isHTTPProtobuf, search.isEmpty, !showingQuery, complete, !truncated,
              !data.isEmpty, data.count <= JSONTreeService.maxInput else { return nil }
        return currentBodyKey
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
            || protobufRules.resolution(for: tx.fullURL, isRequest: isRequest) != nil
    }
    private var isJSON: Bool {
        BodyContentView.isJSON(data: data, contentType: inspectedBody.contentType)
    }

    private var queryUnavailable: String? {
        if truncated { return Strings.Detail.theBodyIsTruncatedQueriesRequireACompleteCapture }
        if !complete { return Strings.Detail.waitingForCompleteBody }
        if data.count > JSONPath.maxInputBytes { return Strings.Detail.queriesSupportBodiesUpTo1Mib }
        return nil
    }
    private var isForm: Bool {
        contentType.localizedCaseInsensitiveContains("multipart/form-data") || contentType.localizedCaseInsensitiveContains("application/x-www-form-urlencoded")
    }
    private var isHTML: Bool { contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/html" }
    private var isMarkup: Bool {
        let type = contentType.lowercased()
        return type.contains("xml") || type.contains("html") || type.contains("svg")
    }
    private var isEncryptedTunnel: Bool { tx.isTunnel && !tx.isTLSIntercepted }

    private var tabs: [Tab] {
        if isRequest {
            var request: [Tab] = [.headers, .query, .body, .raw, .summary, .connection]
            if isForm { request.insert(.multipart, at: 3) }
            return request
        }
        var response: [Tab] = [.headers, .body, .raw, .summary, .chart]
        if isForm { response.insert(.multipart, at: 2) }
        if isHTML { response.insert(.preview, at: 2) }
        if tx.isWebSocket { response.insert(.webSocket, at: 1) }
        if tx.isSSE, let index = response.firstIndex(of: .body) { response.insert(.sse, at: index + 1) }
        return isEncryptedTunnel ? [] : response
    }

    private var additionalTabs: [Tab] {
        (isRequest ? [.preview, .cookies, .auth, .graphql] : [.preview, .cookies]).filter { !tabs.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            if !isRequest && isEncryptedTunnel {
                encryptedResponse
            } else {
                if let error = tx.localizedErrorText, !isRequest {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                if truncated {
                    Text(Strings.Detail.bodyTruncatedBytesCaptured(capturedData.count, receivedBytes))
                        .font(.caption).foregroundStyle(.orange).padding(4)
                }
                if let id = customPreviewerID, let previewer = previewers.items.first(where: { $0.id == id }) {
                    CustomPreviewerResultView(previewer: previewer, tx: tx, side: side)
                } else {
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isRequest ? ProxymanTheme.inspectorChrome : ProxymanTheme.tableBackground)
        .background(BodyWindowAnchor(reference: bodyWindow))
        .onChange(of: tx.isWebSocket) { _ in selectedTab = nil }
        .onChange(of: ObjectIdentifier(tx)) { _ in
            if let selectedTab, !tabs.contains(selectedTab), !additionalTabs.contains(selectedTab) {
                self.selectedTab = nil
            }
            search = ""
            showingQuery = false
            showCapturedBytes = false
            decodedBody = nil
            bodyInspection = nil
            formattedBody = nil
            forceHex = false
            formatIssue = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusBodySearch)) { _ in
            // One handler for the pair routes a native find bar to whichever
            // request/response text view currently owns the first responder.
            guard !isRequest, let keyWindow = NSApp.keyWindow, bodyWindow.window === keyWindow,
                  keyWindow.attachedSheet == nil else { return }
            if let text = NSApp.keyWindow?.firstResponder as? InspectableCodeTextView {
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                text.performFindPanelAction(item)
            } else if !isEncryptedTunnel {
                selectedTab = .body
                showingQuery = false
                formattedBody = nil
                forceHex = false
                bodySearchFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pmMemoryPressure)) { _ in
            bodyInspection = nil; decodedBody = nil; treeResult = nil; formattedBody = nil; inspectionEpoch &+= 1
        }
        .task(id: inspectionInput) {
            guard let input = inspectionInput, bodyInspection?.input != input else { return }
            let bytes = baseDecodedData
            let type = contentType
            let compressed = isCompressed
            let worker = Task.detached(priority: .userInitiated) {
                HTTPBodyInspection.inspect(bytes, contentType: type, allowUnhintedTars: compressed)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, inspectionInput == input else { return }
            bodyInspection = (input, result)
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
            if !Task.isCancelled, decodeInput == input { decodedBody = (input, result) }
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
            if !Task.isCancelled, treeInput == input { treeResult = (input, result) }
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 9) {
            Text(isRequest ? Strings.Detail.request : Strings.Detail.response)
                .font(PresentationFonts.swiftUIFont(weight: .bold))
                .fixedSize()
            if !tabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(tabs, id: \.self) { tabButton($0) }
                        if additionalTabs.contains(tab) { tabButton(tab) }
                        Menu {
                            ForEach(additionalTabs, id: \.self) { candidate in
                                Button(candidate.localizedTitle) { customPreviewerID = nil; selectedTab = candidate }
                            }
                            if !previewers.items.isEmpty { Divider() }
                            ForEach(previewers.items.filter { $0.matches(contentType) }) { previewer in
                                Button(previewer.name) { customPreviewerID = previewer.id }
                            }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 10))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(Strings.Detail.moreInspectorTabs)
                    }
                }
            } else {
                Spacer()
            }
            if !isEncryptedTunnel { bodyToolsMenu }
            if receivedBytes > 0 {
                Text(PresentationNumbers.byteCount(Int64(receivedBytes)))
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
        Button { customPreviewerID = nil; selectedTab = candidate } label: {
            Text(candidate == .body ? grpcMediaType?.transport.label ?? candidate.localizedTitle : candidate.localizedTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tab == candidate && customPreviewerID == nil ? Color.accentColor : Color.secondary)
                .fixedSize()
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == candidate ? .isSelected : [])
    }

    private var encryptedResponse: some View {
        VStack(spacing: 8) {
            Label(Strings.Detail.httpsResponse, systemImage: "lock")
                .font(.system(size: 17, weight: .medium))
            Text(Strings.Detail.thisHttpsResponseIsEncryptedEnableSslProxyingToViewIts)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
            Button(Strings.Detail.enableForThisDomainOnly) { appState.enableSSLProxying(for: tx) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 5)
            if let name = tx.clientName, tx.clientBundle != nil {
                Text(Strings.Detail.or).font(.system(size: 12))
                Button(Strings.Detail.configureSslProxyingFor(String(describing: name))) { appState.openTool(.sslApplications, transaction: tx) }
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
                    fields(isRequest ? Strings.Detail.requestHeaders : Strings.Detail.responseHeaders, headers.pairs.map { ($0.name, $0.value) })
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
                                          path: tx.path, isRequest: isRequest, mediaType: grpcMediaType, target: tx.fullURL)
                            .id(ObjectIdentifier(tx))
                    } else if isHTTPProtobuf {
                        HTTPProtobufView(data: baseDecodedData, revision: bodyRevision, generation: bodyGeneration,
                                         complete: complete || tx.state == .failed, truncated: truncated,
                                         isError: !isRequest && (400...599).contains(tx.statusCode),
                                         decodedEncoding: decodedLabel, target: tx.fullURL, isRequest: isRequest)
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
        case .multipart:
            inspectBody {
                FormBodyView(data: baseDecodedData, contentType: contentType, complete: complete && !truncated)
            }
        case .preview:
            inspectBody {
                if isHTML {
                    IsolatedHTMLPreview(data: baseDecodedData)
                } else {
                BodyContentView(data: tx.isWebSocket ? capturedData : data,
                                contentType: tx.isWebSocket ? contentType : inspectedBody.contentType, pretty: true,
                                complete: complete || tx.state == .failed, truncated: truncated, revision: bodyRevision,
                                generation: bodyGeneration, inspectionKey: currentBodyKey)
                    .id(ObjectIdentifier(tx))
                }
            }
        case .query:
            let items = URLComponents(string: "?\(tx.query)")?.queryItems ?? []
            if items.isEmpty {
                Text(Strings.Detail.noQuery).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    fields(Strings.Detail.queryParameters, items.map { ($0.name, $0.value ?? "") }).padding(10)
                }
            }
        case .cookies:
            let name = isRequest ? "Cookie" : "Set-Cookie"
            let values = headers.values(of: name)
            let entries = isRequest ? values.flatMap { $0.components(separatedBy: ";") } : values
            ScrollView { fields(name, entries.map { (name, $0.trimmingCharacters(in: .whitespaces)) }).padding(10) }
        case .auth:
            let entries = headers.pairs.filter { ["authorization", "proxy-authorization"].contains($0.name.lowercased()) }
            ScrollView { fields(Strings.Detail.authenticationHeaders, entries.map { ($0.name, $0.value) }).padding(10) }
        case .graphql:
            ScrollView {
                if let info = GraphQLService.detect(tx: tx, inspectResponse: false) {
                    fields("GraphQL", [(Strings.Detail.operation, info.operationName), (Strings.Detail.type, info.operationType),
                                      (Strings.Detail.document, info.queryText), (Strings.Detail.variables, info.variablesText)]).padding(10)
                } else {
                    Text(Strings.Detail.noGraphqlOperationDetected).font(.caption).foregroundStyle(.secondary).padding(10)
                }
            }
        case .connection:
            ScrollView {
                fields(Strings.Detail.connectionLog, [
                    (Strings.Detail.client, tx.clientName ?? Strings.Detail.unknown),
                    (Strings.Detail.clientAddress, tx.clientAddress ?? Strings.Detail.notAvailable),
                    (Strings.Detail.target, tx.fullURL),
                    (Strings.Detail.originalTarget, tx.originalURL ?? tx.fullURL),
                    (Strings.Detail.captureIngress, tx.isTransparent ? Strings.Detail.transparentProxy : "—"),
                    (Strings.Detail.dnsMappingAddress, tx.resolvedAddress ?? Strings.Detail.none),
                    (Strings.Detail.clientProtocol, tx.requestVersion),
                    (Strings.Detail.upstreamProtocol, tx.upstreamProtocol ?? (tx.statusCode == 0 ? Strings.Detail.notAvailable : tx.responseVersion)),
                    (Strings.Detail.upstreamAddress, tx.connectionDetails?.address ?? Strings.Detail.notAvailable),
                    (Strings.Detail.externalProxy, tx.connectionDetails?.externalProxy ?? Strings.Detail.directOrNotConnected),
                    (Strings.Detail.upstreamAlpn, tx.connectionDetails?.alpn ?? Strings.Detail.notAvailable),
                    (Strings.Detail.dnsLookup, connectionDuration(tx.connectionDetails?.dnsMilliseconds)),
                    (Strings.Detail.tcpProxyConnection, connectionDuration(tx.connectionDetails?.tcpMilliseconds)),
                    (Strings.Detail.tlsHandshake, connectionDuration(tx.connectionDetails?.tlsMilliseconds)),
                    (Strings.Detail.connectionReuse, tx.connectionDetails?.reused == true ? Strings.Detail.reused : Strings.Detail.newOrNotAvailable),
                    (Strings.Detail.clientStreamId, tx.connectionDetails?.downstreamStream.map(String.init) ?? "–"),
                    (Strings.Detail.upstreamStreamId, tx.connectionDetails?.upstreamStream.map(String.init) ?? "–"),
                    (Strings.Detail.connectionEstablished, tx.tConnected.map { PresentationTime.string(from: $0) } ?? Strings.Detail.notAvailable),
                    (Strings.Detail.responseHeadersReceived, tx.tHeaderAt.map { PresentationTime.string(from: $0) } ?? Strings.Detail.notAvailable),
                    (Strings.Detail.matchedRules, tx.ruleMatches.isEmpty ? Strings.Detail.none : tx.ruleMatches.joined(separator: " → ")),
                    (Strings.Detail.scriptExecution, tx.scriptingLogs.isEmpty ? Strings.Detail.none : tx.scriptingLogs.joined(separator: "\n")),
                ]).padding(10)
            }
        case .summary:
            TransactionSummaryView(tx: tx) { selectedTab = .connection }
        case .chart:
            TimingChartView(tx: tx)
        }
    }

    private func connectionDuration(_ milliseconds: Double?) -> String {
        milliseconds.map { PresentationNumbers.milliseconds($0) } ?? "–"
    }

    @ViewBuilder
    private func inspectBody<Content: View>(rawHead: RawMessageHead? = nil,
                                           @ViewBuilder _ content: () -> Content) -> some View {
        if inspectionPending {
            ProgressView(Strings.Detail.decoding).controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if inspectedBody.issue == .outputLimit {
            compressedBody(Strings.Detail.binaryBodyOutputLimit, rawHead: rawHead)
        } else if !isCompressed || capturedData.isEmpty || tx.isWebSocket {
            content()
        } else if truncated {
            compressedBody(Strings.Detail.theBodyWasTruncatedAndCannotBeDecompressed, rawHead: rawHead)
        } else if tx.state == .failed && !complete {
            compressedBody(Strings.Detail.theResponseWasNotFullyReceivedAndCannotBeDecompressed, rawHead: rawHead)
        } else if unsupportedEncodings {
            compressedBody(Strings.Detail.unsupportedContentEncoding(String(describing: contentEncodings.joined(separator: ", "))), rawHead: rawHead)
        } else if !complete {
            if let rawHead {
                compressedBody(Strings.Detail.waitingForTheCompleteBodyBeforeAutomaticDecompression, rawHead: rawHead)
            } else {
                ProgressView(Strings.Detail.waitingForTheCompleteBody).controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            switch decodeResult {
            case .success:
                content()
            case .failure(let error):
                switch error {
                case .outputLimit:
                    compressedBody(Strings.Detail.theDecompressedBodyExceeds32Mib, rawHead: rawHead)
                case .unsupported(let list):
                    compressedBody(Strings.Detail.unsupportedContentEncoding(String(describing: list.joined(separator: ", "))), rawHead: rawHead)
                case .invalidStream:
                    compressedBody(Strings.Detail.unableToDecompressTheBody(String(describing: contentEncodings.joined(separator: ", "))), rawHead: rawHead)
                }
            case nil:
                if let rawHead {
                    compressedBody(Strings.Detail.decompressing, rawHead: rawHead)
                } else {
                    ProgressView(Strings.Detail.decompressing).controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func compressedBody(_ message: String, rawHead: RawMessageHead? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(message).font(.caption).foregroundStyle(.secondary).padding(6)
            if let rawHead {
                rawBodyPreview(capturedData, head: rawHead, forceBinary: true)
            } else {
                HexView(data: capturedData, generation: bodyGeneration)
                    .id(ObjectIdentifier(tx))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bodyToolsMenu: some View {
        Menu {
            Button(Strings.Detail.bodyToolsPreviewer) { selectedTab = .body; customPreviewerID = nil; forceHex = false; tree = false; formattedBody = nil; formatIssue = false }
            Button(Strings.Detail.bodyToolsTreeView) { selectedTab = .body; tree = true; forceHex = false; formattedBody = nil }
                .disabled(!isJSON || treeUnavailableReason != nil)
            Button(Strings.Detail.bodyToolsHex) { selectedTab = .body; tree = false; showingQuery = false; search = ""; forceHex = true; formattedBody = nil }
            Divider()
            Button(Strings.Detail.bodyToolsPrettifyJson) { formatBody(markup: false) }
                .disabled(!isJSON || !complete || truncated)
            Button(Strings.Detail.bodyToolsSortJson) { formatBody(markup: false) }
                .disabled(!isJSON || !complete || truncated)
            Menu(Strings.Detail.bodyToolsFormatWith) {
                Button(Strings.Detail.bodyToolsPrettifyJson) { formatBody(markup: false) }.disabled(!isJSON)
                if isMarkup { Button(Strings.Detail.bodyToolsPrettifyXml) { formatBody(markup: true) } }
            }.disabled(!complete || truncated || data.isEmpty)
            Divider()
            Toggle(Strings.Detail.bodyToolsCapturedBytes, isOn: $exportCapturedBytes)
            Menu(Strings.Detail.bodyToolsOpenWith) {
                Button(Strings.Detail.bodyToolsChooseApplication) { exportBody(.open) }
                Button(Strings.Detail.bodyToolsReveal) { exportBody(.reveal) }
            }.disabled(exportingBody || capturedData.isEmpty)
            Menu(Strings.Detail.bodyToolsExport) {
                Button(isRequest ? Strings.Detail.bodyToolsRequestBody : Strings.Detail.bodyToolsResponseBody) { exportBody(.save) }
            }.disabled(exportingBody || capturedData.isEmpty)
            if truncated || !complete { Text(Strings.Detail.bodyToolsCaptureIncomplete) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(Strings.Detail.bodyToolsMenu)
        .accessibilityLabel(Strings.Detail.bodyToolsMenu)
    }

    private func formatBody(markup: Bool) {
        let key = currentBodyKey, bytes = data, html = contentType.localizedCaseInsensitiveContains("html")
        showingQuery = false
        tree = false
        search = ""
        guard bytes.count <= 1_048_576, let source = String(data: bytes, encoding: .utf8) else { formatIssue = true; return }
        Task {
            let worker = Task.detached(priority: .userInitiated) { () -> String? in
                if markup {
                    let result = MarkupFormatter.format(source, html: html)
                    return result.formatted ? result.text : nil
                }
                return SelectionTransform.prettifyJSON.apply(source)
            }
            let output = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, key == currentBodyKey else { return }
            formatIssue = output == nil
            if let output { formattedBody = (key, output, markup); forceHex = false; showingQuery = false; selectedTab = .body }
        }
    }

    private enum BodyExportAction { case save, open, reveal }
    private func exportBody(_ action: BodyExportAction) {
        let bytes = capturedData, type = contentType, encodings = contentEncodings
        let original = exportCapturedBytes, canDecode = complete && !truncated
        exportingBody = true
        Task {
            defer { exportingBody = false }
            var output = bytes
            if !original, !encodings.isEmpty {
                guard canDecode else { BodyExportService.show(Strings.Detail.bodyToolsIncompleteDecode); return }
                let worker = Task.detached(priority: .userInitiated) { ContentCoding.decodeIfCompressed(bytes, encodings: encodings) }
                let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                guard case .success(let decoded) = result else { BodyExportService.show(Strings.Detail.bodyToolsDecodeFailed); return }
                output = decoded.0
            }
            switch action {
            case .save: BodyExportService.save(output, contentType: original && !encodings.isEmpty ? "application/octet-stream" : type)
            case .open: BodyExportService.open(output, contentType: type, reveal: false)
            case .reveal: BodyExportService.open(output, contentType: type, reveal: true)
            }
        }
    }

    private var bodyInspector: some View {
        VStack(spacing: 0) {
            if !data.isEmpty {
                HStack {
                    if !showingQuery {
                        TextField(Strings.Detail.searchBody, text: Binding(get: { search }, set: { search = $0; formattedBody = nil; forceHex = false }))
                            .textFieldStyle(.roundedBorder).focused($bodySearchFocused)
                        if isJSON {
                            Toggle(Strings.Detail.jsonTree, isOn: Binding(get: { tree }, set: { tree = $0; formattedBody = nil; forceHex = false })).toggleStyle(.checkbox)
                                .disabled(treeUnavailableReason != nil)
                                .help(treeUnavailableReason ?? Strings.Detail.expandTheJsonBodyAsATree)
                        }
                    } else {
                        Text(Strings.Detail.jsonQuery).font(.caption.weight(.semibold))
                        Spacer()
                    }
                    Spacer(minLength: 8)
                    if let format = inspectedBody.format {
                        Text(format == .messagePack ? Strings.Detail.decodedMessagepack : Strings.Detail.decodedTars)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .help(format == .messagePack ? Strings.Detail.messagepackBodyConvertedToJson : Strings.Detail.tarsBodyConvertedToJson)
                    }
                    if let label = decodedLabel {
                        Text(Strings.Detail.decoded(String(describing: label)))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .help(declaredContentEncodings.isEmpty ? Strings.Detail.gzipDetectedFromBody : Strings.Detail.automaticallyDecompressedUsingContentEncoding)
                    }
                    if isJSON {
                        Button(showingQuery ? Strings.Detail.backToBody : Strings.Detail.query) {
                            formattedBody = nil
                            forceHex = false
                            showingQuery.toggle()
                        }
                        .accessibilityLabel(showingQuery ? Strings.Detail.backToBody : Strings.Detail.queryTheJsonBody)
                    }
                }
                .controlSize(.small).padding(5)
                if isJSON, !showingQuery, let reason = treeUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5)
                }
            }
            if formatIssue {
                Text(Strings.Detail.bodyToolsCannotFormat).font(.caption).foregroundStyle(.orange).padding(5)
            }
            if forceHex {
                HexView(data: data, generation: bodyGeneration)
            } else if let formattedBody, formattedBody.key == currentBodyKey {
                CodeDocument(text: formattedBody.text,
                             highlights: formattedBody.markup ? MarkupHighlightPlan.make(formattedBody.text) : JSONHighlightPlan.make(formattedBody.text))
            } else if showingQuery {
                BodyQueryView(data: data, unavailableReason: queryUnavailable).id(ObjectIdentifier(tx))
            } else if !search.isEmpty {
                BodySearchResults(data: data, revision: bodyRevision, query: search)
                    .id(ObjectIdentifier(tx))
            } else if let treeInput, treeResult?.input != treeInput {
                ProgressView(Strings.Detail.parsingJson).controlSize(.small)
            } else if treeInput != nil, let treeRoot = treeResult?.root {
                ScrollView {
                    JSONTreeNodesView(node: treeRoot)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            } else {
                BodyContentView(data: data, contentType: inspectedBody.contentType, pretty: true,
                                complete: complete || tx.state == .failed, truncated: truncated, revision: bodyRevision,
                                generation: bodyGeneration, inspectionKey: currentBodyKey)
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
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tx.isWebSocket ? Strings.Detail.handshakeHeadersAndOriginalWebsocketFrameBytes :
                     isHTTP2 ? Strings.Detail.http2PseudoHeadersAndBody : Strings.Detail.reconstructedFromTheCapturedFirstLineHeadersAndBody)
                Spacer()
                if !tx.isWebSocket, isCompressed || isHTTPProtobuf || payloadConverted {
                    Toggle(Strings.Detail.capturedBytes, isOn: $showCapturedBytes)
                        .toggleStyle(.checkbox)
                        .help(Strings.Detail.viewTheCapturedBodyWithoutDecompressionOrConversion)
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(6)
            if !complete && tx.state != .failed {
                Text(Strings.Detail.capturing).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            if showCapturedBytes || tx.isWebSocket {
                rawBodyPreview(capturedData, head: head, forceBinary: isCompressed || tx.isWebSocket)
            } else {
                inspectBody(rawHead: head) {
                    if let decodedLabel {
                        Text(Strings.Detail.bodyDecodedAsHeadersRetainCapturedValues(String(describing: decodedLabel)))
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                    }
                    if isHTTPProtobuf, grpcMediaType == nil {
                        HTTPProtobufView(data: baseDecodedData, revision: bodyRevision, generation: bodyGeneration,
                                         complete: complete || tx.state == .failed, truncated: truncated,
                                         isError: !isRequest && (400...599).contains(tx.statusCode),
                                         decodedEncoding: nil, target: tx.fullURL, isRequest: isRequest, rawHead: head, rawTrailers: trailers)
                            .id(ObjectIdentifier(tx))
                    } else {
                        rawBodyPreview(data, head: head, contentType: inspectedBody.contentType)
                    }
                }
            }
        }
    }

    private func rawBodyPreview(_ bytes: Data, head: RawMessageHead, forceBinary: Bool = false,
                                contentType: String? = nil) -> some View {
        let binary = !bytes.isEmpty && (forceBinary || BodyContentView.isBinary(data: bytes, contentType: contentType ?? self.contentType))
        return VStack(alignment: .leading, spacing: 0) {
            if binary {
                Text(Strings.Detail.binaryBody).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            BodyPreview(data: bytes, format: binary ? .hex : .text, generation: bodyGeneration,
                        rawHead: head, includeHead: true,
                        suffixText: trailers.count > 0 ? "\r\nTrailers\r\n" + String(decoding: trailers.rawBytes, as: UTF8.self) : "")
                .id(ObjectIdentifier(tx))
        }
    }

    private func fields(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(PresentationFonts.swiftUIFont(weight: .semibold)).foregroundStyle(.secondary)
            if rows.isEmpty { Text(Strings.Detail.none).font(.caption).foregroundStyle(.secondary) }
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Text(rows[index].0).fontWeight(.medium).frame(minWidth: 70, idealWidth: 108, alignment: .leading)
                    Text(rows[index].1).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(PresentationFonts.swiftUIFont()).textSelection(.enabled)
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
                    Text(result.total == 0 ? Strings.Detail.noMatchingContent : result.text)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                Text(Strings.Detail.searchFirst1MibOfBodyShowingLines(min(result.total, 200), result.total))
                    .font(.caption).foregroundStyle(.secondary).padding(4)
            } else {
                ProgressView(Strings.Detail.searching).controlSize(.small)
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
