import Foundation
import AppKit
import ProxyMirrorFoundation

/// Proxyman 顶部筛选 chips（实测: 全部|HTTP|HTTPS|WebSocket|JSON|表单|XML|JS|CSS|GraphQL|文档|媒体|其他）
enum FilterChip: String, CaseIterable, Identifiable {
    case all, http, https, websocket, json,
         form, xml, js, css, graphql,
         document, media, other
    var id: String { rawValue }
        var localizedTitle: String {
            switch self {
            case .all: return Strings.Models.filterAll
            case .http: return Strings.Models.filterHttp
            case .https: return Strings.Models.filterHttps
            case .websocket: return Strings.Models.filterWebsocket
            case .json: return Strings.Models.filterJson
            case .form: return Strings.Models.filterForm
            case .xml: return Strings.Models.filterXml
            case .js: return Strings.Models.filterJs
            case .css: return Strings.Models.filterCss
            case .graphql: return Strings.Models.filterGraphql
            case .document: return Strings.Models.filterDocument
            case .media: return Strings.Models.filterMedia
            case .other: return Strings.Models.filterOther
            }
        }
    }

extension Transaction {
    func matches(chip: FilterChip) -> Bool {
        let ct = contentType.lowercased()
        let p = path.lowercased()
        switch chip {
        case .all: return true
        case .http: return scheme == "http" && !isWebSocket
        case .https: return scheme == "https" && !isWebSocket
        case .websocket: return isWebSocket || ct.contains("websocket")
        case .json: return ct.contains("json")
        case .form: return ct.contains("x-www-form-urlencoded") || ct.contains("multipart/form-data")
        case .xml: return ct.contains("xml")
        case .js: return ct.contains("javascript") || p.hasSuffix(".js")
        case .css: return ct.contains("css")
        case .graphql: return p.contains("graphql") || ct.contains("graphql")
        case .document: return ct.contains("html") || ct.contains("pdf") || ct.contains("txt")
        case .media: return ct.hasPrefix("image/") || ct.hasPrefix("video/") || ct.hasPrefix("audio/")
        case .other:
            let covered = matches(chip: .json) || matches(chip: .form) || matches(chip: .xml) ||
                matches(chip: .js) || matches(chip: .css) || matches(chip: .graphql) ||
                matches(chip: .document) || matches(chip: .media) || isWebSocket
            return !covered
        }
    }
}


// MARK: - 事务状态

enum TxState: String, Codable {
    case pending        // 请求发送中
    case awaiting       // 等待响应
    case completed
    case failed
}

enum BodyKind: String, CaseIterable {
    case json
    case html
    case xml
    case javascript
    case css
    case image
    case font
    case plain
    case stream
    case binary
    case tunnel
    case unknown

    static func from(contentType: String?, scheme: String?) -> BodyKind {
        let ct = (contentType ?? "").lowercased()
        if ct.contains("json") { return .json }
        if ct.contains("html") { return .html }
        if ct.contains("xml") || ct.contains("soap") { return .xml }
        if ct.contains("javascript") { return .javascript }
        if ct.contains("css") { return .css }
        if ct.hasPrefix("image/") { return .image }
        if ct.contains("font") || ct.contains("woff") { return .font }
        if ct.contains("event-stream") { return .stream }
        if ct.hasPrefix("text/") { return .plain }
        if ct.isEmpty { return scheme == "Tunnel" ? .tunnel : .unknown }
        return .binary
    }
        var localizedTitle: String {
            switch self {
            case .json: return Strings.Models.bodyKindJson
            case .html: return Strings.Models.bodyKindHtml
            case .xml: return Strings.Models.bodyKindXml
            case .javascript: return Strings.Models.bodyKindJavascript
            case .css: return Strings.Models.bodyKindCss
            case .image: return Strings.Models.bodyKindImage
            case .font: return Strings.Models.bodyKindFont
            case .plain: return Strings.Models.bodyKindPlain
            case .stream: return Strings.Models.bodyKindStream
            case .binary: return Strings.Models.bodyKindBinary
            case .tunnel: return Strings.Models.bodyKindTunnel
            case .unknown: return Strings.Models.bodyKindUnknown
            }
        }
    }

// MARK: - Transaction（一条请求/响应记录）

/// 单条抓包记录。引擎线程只通过 UI 派发的闭包修改字段。
final class Transaction: ObservableObject, Identifiable {
    private struct BodyStorage {
        var data = Data()
        var bytes = 0
        var truncated = false
        var revision: UInt64 = 0
        var generation: UInt64 = 0

        mutating func replace(_ body: Data) {
            data = body
            revision &+= 1
            generation &+= 1
        }

        mutating func discard() {
            guard !data.isEmpty else { return }
            bytes = max(bytes, data.count)
            replace(Data())
            truncated = true
        }

        mutating func append(_ captured: Data, byteCount: Int) {
            if !captured.isEmpty {
                if data.isEmpty { data = captured } else { data.append(captured) }
                revision &+= 1
            }
            bytes += byteCount
            truncated = bytes > data.count
        }
    }

    let id: UUID
    let startedAt: Date
    let captureReservation: CaptureReservation?
    private let captureLock = NSLock()
    private var requestCapture = BodyStorage()
    private var responseCapture = BodyStorage()
    private var storedWebSocketFrames: [WSFrame] = []
    private weak var captureSink: TrafficSink?

    @Published var state: TxState = .pending {
        didSet {
            if (state == .completed || state == .failed), !isWebSocket {
                captureReservation?.finish(transaction: self)
            }
        }
    }
    @Published var method: String = "GET"
    @Published var scheme: String = "http"      // http / https / Tunnel
    @Published var host: String = ""
    @Published var port: Int = 80
    @Published var path: String = "/"
    @Published var query: String = ""
    @Published var statusCode: Int = 0          // 0 = 未完成/失败
    @Published var statusReason: String = ""
    @Published private var storedErrorText: String?
    @Published private(set) var failure: CapturedFailure?
    /// Stable diagnostic retained for CLI, HAR and native session consumers.
    var errorText: String? {
        get { failure?.diagnostic ?? storedErrorText }
        set { failure = nil; storedErrorText = newValue }
    }
    var localizedErrorText: String? { failure?.localizedPresentation ?? storedErrorText }

    func setFailure(_ failure: CapturedFailure?) {
        storedErrorText = nil
        self.failure = failure
    }

    func recordFailure(_ error: Error) { setFailure(NetworkFailure.capture(error)) }
    @Published var isTLSIntercepted = false     // MITM 解密
    @Published var suspectedPinning = false     // 疑似证书锁定（客户端拒绝代理证书）
    @Published var sseEvents: [SSEEvent] = []   // text/event-stream 事件级解析结果
    @Published var sseEventsTruncated = false
    @Published var sseParseIssue: String?
    @Published var sseDecodingDeferred = false
    var isSSE: Bool { SSEStreamState.matches(contentType) }
    @Published var isTunnel = false             // 未解密的 CONNECT 隧道
    @Published var isWebSocket = false
    var websocketFrames: [WSFrame] {
        get { captureLock.withLock { storedWebSocketFrames } }
        set {
            objectWillChange.send()
            captureLock.withLock { storedWebSocketFrames = newValue }
        }
    }

    @Published var requestHeaders = HTTPHeaders()
    @Published var responseHeaders = HTTPHeaders()
    var requestBody: Data {
        get { captureLock.withLock { requestCapture.data } }
        set {
            objectWillChange.send()
            captureLock.withLock { requestCapture.replace(newValue) }
        }
    }
    var responseBody: Data {
        get { captureLock.withLock { responseCapture.data } }
        set {
            objectWillChange.send()
            captureLock.withLock { responseCapture.replace(newValue) }
        }
    }
    var requestBodyRevision: UInt64 { captureLock.withLock { requestCapture.revision } }
    var responseBodyRevision: UInt64 { captureLock.withLock { responseCapture.revision } }
    var requestBodyGeneration: UInt64 { captureLock.withLock { requestCapture.generation } }
    var responseBodyGeneration: UInt64 { captureLock.withLock { responseCapture.generation } }
    var requestBytes: Int {
        get { captureLock.withLock { requestCapture.bytes } }
        set {
            objectWillChange.send()
            captureLock.withLock { requestCapture.bytes = newValue }
        }
    }
    var responseBytes: Int {
        get { captureLock.withLock { responseCapture.bytes } }
        set {
            objectWillChange.send()
            captureLock.withLock { responseCapture.bytes = newValue }
        }
    }
    var requestVersion = "HTTP/1.1"
    var responseVersion = "HTTP/1.1"
    var upstreamProtocol: String?
    var connectionDetails: ProxyConnectionDetails?
    var originalURL: String?
    var resolvedAddress: String?
    var simulatedLatencyMs: Int?
    var requestTrailers = HTTPHeaders()
    var responseTrailers = HTTPHeaders()
    @Published var requestBodyComplete = false
    @Published var responseBodyComplete = false
    var requestTruncated: Bool {
        get { captureLock.withLock { requestCapture.truncated } }
        set {
            objectWillChange.send()
            captureLock.withLock { requestCapture.truncated = newValue }
        }
    }
    var responseTruncated: Bool {
        get { captureLock.withLock { responseCapture.truncated } }
        set {
            objectWillChange.send()
            captureLock.withLock { responseCapture.truncated = newValue }
        }
    }
    @Published var contentType: String = ""
    @Published var duration: TimeInterval = 0
    @Published var comment: String = ""
    @Published var isFlagged = false
    /// Flow ▸ Highlight 标记色名（Red/Yellow/Green/Blue/Purple/Gray），nil=无
    @Published var highlightName: String?
    /// Flow ▸ Strikethrough（⌘/）
    @Published var strikethrough = false
    /// 工具列标记（创建期写入安全）
    var matchedByMapLocal = false
    var matchedByMapRemote = false
    var isTransparent = false
    var matchedByBlock = false
    @Published var breakpointRules: [String] = []
    @Published var scriptingLogs: [String] = []
    var ruleMatches: [String] {
        var result: [String] = []
        if matchedByBlock { result.append(Strings.Models.ruleMatchBlock) }
        if matchedByMapLocal { result.append(Strings.Models.ruleMatchMapLocal) }
        if matchedByMapRemote { result.append(Strings.Models.ruleMatchMapRemote) }
        result.append(contentsOf: breakpointRules.map { Strings.Models.ruleMatchBreakpoint($0) })
        if !scriptingLogs.isEmpty { result.append(Strings.Models.ruleMatchScript) }
        if resolvedAddress != nil { result.append(Strings.Models.ruleMatchDns) }
        if let simulatedLatencyMs { result.append(Strings.Models.ruleMatchLatency(simulatedLatencyMs)) }
        return result
    }

    // MARK: 列表 # 列 与 客户端列（对齐 Proxyman）
    /// 序号（TrafficStore 添加时赋值，创建期写入安全）
    var seq: Int = 0
    /// 客户端连接的本地临时端口（进程归因用，创建期写入安全）
    var peerPort: UInt16 = 0
    /// 客户端进程信息（创建期或主线程延迟归因后写入）
    @Published var clientName: String?
    @Published var clientPID: Int32?
    @Published var clientBundle: String?
    @Published var isIOSSimulator = false
    var clientAddress: String?
    private var clientBundleURL: URL?

    @MainActor var clientIcon: NSImage? {
        ClientApplicationIcons.image(bundleID: clientBundle, bundleURL: clientBundleURL)
    }

    func setClientApplication(_ info: ProcessAppInfo?) {
        guard let info else { return }
        clientBundleURL = info.bundleURL
        clientName = info.name
        clientBundle = info.bundleID
        clientPID = Int32(info.pid)
        isIOSSimulator = info.isIOSSimulator
    }
    /// 阶段时间戳（Chart 瀑布图用；主线程写入）
    var tConnected: Date?
    var tHeaderAt: Date?

    /// 超过捕获上限时不再累计字节
    var captureLimit: Int = 20 * 1024 * 1024

    /// 不在列表中显示（如已被 MITM 解密的 CONNECT 隧道行，对齐 Proxyman）
    var hideFromList = false

    init(id: UUID = UUID(), startedAt: Date = Date(), captureBudget: CaptureBudget? = nil) {
        self.id = id
        self.startedAt = startedAt
        captureReservation = captureBudget.map(CaptureReservation.init)
    }

    // MARK: 派生展示属性

    var isGRPCWeb: Bool {
        if let media = GRPCFrames.contentType(contentType), media.transport != .native { return true }
        return GRPCFrames.contentType(requestHeaders.value(of: "Content-Type") ?? "")
            .map { $0.transport != .native } ?? false
    }

    var bodyKind: BodyKind {
        if isTunnel { return .tunnel }
        return BodyKind.from(contentType: contentType, scheme: scheme)
    }

    var urlText: String {
        if isTunnel { return "\(host):\(port)" }
        return path + (query.isEmpty ? "" : "?\(query)")
    }

    var fullURL: String {
        let protocolName = isTunnel ? "https" : scheme
        let authority = URLParser.authority(host: host, port: port, scheme: protocolName)
        return "\(protocolName)://\(authority)\(isTunnel ? "" : urlText)"
    }

    var totalSize: Int {
        max(requestBytes, requestBody.count) + max(responseBytes, responseBody.count)
    }

    var statusText: String {
        statusReason.isEmpty ? "\(statusCode)" : "\(statusCode) \(statusReason)"
    }

    var canReplay: Bool {
        !isTunnel && !isWebSocket && requestBodyComplete && !requestTruncated
    }

    func replayRequestBody() -> Data? {
        guard !isTunnel, !isWebSocket, requestBodyComplete else { return nil }
        return captureLock.withLock {
            requestCapture.truncated ? nil : requestCapture.data
        }
    }

    var sizeText: String {
        PresentationNumbers.byteCount(Int64(totalSize))
    }

    var timeText: String { PresentationTime.string(from: startedAt) }

    var durationText: String {
        PresentationNumbers.duration(seconds: duration)
    }

    /// 状态圆点颜色（实测色板，见 UI-SPEC.md §1：2xx 绿 / 3xx 黄 / 4xx 橙 / 5xx 红）
    var statusColor: NSColor {
        ProxymanTheme.statusColorNS(status: statusCode,
                                    failed: state == .failed,
                                    completed: state == .completed)
    }

    var methodColor: NSColor {
        ProxymanTheme.methodColorNS(method)
    }

    // MARK: 追加（线程由调用方保证在主线程）

    func appendRequestBody(_ data: Data) {
        appendBody(data, direction: .upstream)
    }

    func appendResponseBody(_ data: Data) {
        appendBody(data, direction: .downstream)
    }

    private func appendBody(_ data: Data, direction: WSFrame.Direction) {
        let wanted = captureLock.withLock {
            let capture = direction == .upstream ? requestCapture : responseCapture
            return capture.truncated ? 0 : min(data.count, max(0, captureLimit - capture.data.count))
        }
        let count = wanted == 0 ? 0 : captureReservation?.reserve(wanted) ?? wanted
        let captured = count == data.count ? data : Data(data.prefix(count))
        if direction == .upstream {
            receiveCapture(request: captured, requestBytes: data.count, charge: count)
        } else {
            receiveCapture(response: captured, responseBytes: data.count, charge: count)
        }
    }

    /// Batches already hold their budget. Moving a batch into retained storage is
    /// atomic with eviction, which can occur on a different connection's loop.
    func receiveCapture(request: Data = Data(), requestBytes: Int = 0,
                        response: Data = Data(), responseBytes: Int = 0,
                        frames: [WSFrame] = [], charge: Int, sink: TrafficSink? = nil) {
        guard requestBytes > 0 || responseBytes > 0 || !frames.isEmpty else { return }
        objectWillChange.send()
        let store = { (retain: Bool) in
            self.captureLock.withLock {
                if let sink { self.captureSink = sink }
                self.requestCapture.append(retain ? request : Data(), byteCount: requestBytes)
                self.responseCapture.append(retain ? response : Data(), byteCount: responseBytes)
                if retain, !frames.isEmpty {
                    self.storedWebSocketFrames.append(contentsOf: frames)
                }
            }
        }
        if let captureReservation { captureReservation.publish(charge: charge, store) }
        else { store(true) }
    }

    func discardCapturedPayload() {
        captureLock.withLock {
            requestCapture.discard()
            responseCapture.discard()
            storedWebSocketFrames = []
        }
    }

    func notifyCaptureEviction() {
        // Captured storage was retired immediately. Deliver observation to the
        // main thread once, after the budget lock has been released.
        onMain { [self] in
            objectWillChange.send()
            let sink = captureLock.withLock { captureSink }
            sink?.transactionBodyUpdated(self)
        }
    }

    func capturedPayloadSnapshot() -> (request: Data, requestBytes: Int, requestTruncated: Bool,
                                       response: Data, responseBytes: Int, responseTruncated: Bool,
                                       frames: [WSFrame]) {
        captureLock.withLock {
            (requestCapture.data, requestCapture.bytes, requestCapture.truncated,
             responseCapture.data, responseCapture.bytes, responseCapture.truncated, storedWebSocketFrames)
        }
    }

    func appendScriptingLogs(_ entries: [String]) {
        scriptingLogs.append(contentsOf: entries)
        if scriptingLogs.count > 100 { scriptingLogs.removeFirst(scriptingLogs.count - 100) }
    }


}
