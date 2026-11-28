import Foundation
import ProxyMirrorFoundation
import NIOCore
import NIOHTTP1
import NIOHTTP2

func configureHTTP2Proxy(_ channel: Channel, engine: ProxyEngine, host: String, port: Int,
                         clientApplication: ProcessAppInfo?,
                         transparentFlow: TransparentProxyFlow? = nil) -> EventLoopFuture<Void> {
    let pool = HTTP2UpstreamPool(downstream: channel, listenerPort: engine.port, listenerAddresses: engine.listenerAddresses)
    let client = channel.remoteAddress
    return channel.configureHTTP2Pipeline(mode: .server,
        initialLocalSettings: nioDefaultSettings + [HTTP2Setting(parameter: .enableConnectProtocol, value: 1)],
        inboundStreamInitializer: { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandlers([
                    HTTP2HeaderValidation(),
                    HTTP2ProxyStreamRouter(engine: engine, pool: pool, host: host, port: port, client: client,
                        application: clientApplication, transparent: transparentFlow),
                ])
            }
        }).map { _ in Void() }
}

final class HTTP2ProxyStream: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let engine: ProxyEngine
    private let pool: HTTP2UpstreamPool
    private let authorityHost: String
    private let authorityPort: Int
    private let client: SocketAddress?
    private let clientApplication: ProcessAppInfo?
    private let transparentFlow: TransparentProxyFlow?
    private let requestRules: () -> RulesSnapshot
    private var downstream: Channel?
    private var upstream: HTTP2UpstreamPool.Exchange?
    private var transaction: Transaction?
    private var metadataPublication: MetadataPublication<Transaction>?
    private var requestMetadata: RequestRouteMetadata?
    private var routedUpstream: RequestRoutePlan.Upstream?
    private var capturedRequestHeaders = HTTPHeaders()
    private var diagnosticHeaders = DiagnosticHeaders()
    private var capture = false
    private var bodyCapture: TransactionCapture?
    private var mapLocalSender: MapLocalSender?
    private var requestEnded = false
    private var responseStarted = false
    private var responseEnded = false
    private var upstreamResponseEnded = false
    private var waitingForUpstream = false
    private var queuedRequest: [HTTPClientRequestPart] = []
    private var queuedBytes = 0
    private var simulatedDelay: Scheduled<Void>?
    private var responseWait: Scheduled<Void>?
    private var version = "HTTP/2"
    private var requestMethod: NIOHTTP1.HTTPMethod?
    private var removeResponseCacheHeaders = false
    private var simulation = LatencySimulation()
    private var uploadPacer: BytePacingQueue?
    private var downloadPacer: BytePacingQueue?
    private static let maxQueuedRequest = 1_048_576
    private static let maxPausedParts = 1024
    private var published = false
    private var originalTarget: ScriptingTarget?
    private var graphqlOperation: String?
    private var gate: StreamInterception?
    private var queuedResponse: [HTTPClientResponsePart] = []
    private var queuedResponseBytes = 0
    private var queuedResponseEnded = false

    private final class StreamInterception {
        let id = UUID()
        let phase: BreakpointRule.Phase
        let head: BreakpointHead
        let rule: BreakpointRule?
        let script: ScriptingPlan?
        let length: Int?
        let session: UUID
        let deadline: Date
        var body = Data()
        var submitted = false
        var timer: Scheduled<Void>?

        init(phase: BreakpointRule.Phase, head: BreakpointHead, rule: BreakpointRule?, script: ScriptingPlan?,
             length: Int?, session: UUID, deadline: Date) {
            self.phase = phase
            self.head = head
            self.rule = rule
            self.script = script
            self.length = length
            self.session = session
            self.deadline = deadline
        }

        var label: String? { rule.map { $0.rule.name.isEmpty ? $0.rule.summary : $0.rule.name } }
    }

    init(engine: ProxyEngine, pool: HTTP2UpstreamPool, authorityHost: String, authorityPort: Int, client: SocketAddress?,
         clientApplication: ProcessAppInfo?, transparentFlow: TransparentProxyFlow? = nil,
         requestRules: @escaping () -> RulesSnapshot = { RulesStore.shared.snapshot() }) {
        self.engine = engine
        self.pool = pool
        self.authorityHost = authorityHost
        self.authorityPort = authorityPort
        self.client = client
        self.clientApplication = clientApplication
        self.transparentFlow = transparentFlow
        self.requestRules = requestRules
    }

    func handlerAdded(context: ChannelHandlerContext) {
        downstream = context.channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            guard transaction == nil else { fail(ProxyHTTP2Error.invalidMessage); return }
            receiveRequestHead(head)
        case .body(let bytes):
            guard !requestEnded, transaction != nil else { fail(ProxyHTTP2Error.invalidMessage); return }
            let waitingForEdit = gate?.phase == .request
            if !waitingForEdit { recordRequestBody(bytes) }
            if !responseEnded { enqueue(.body(.byteBuffer(bytes)), bytes: bytes.readableBytes) }
            if waitingForEdit { collect(bytes) }
        case .end(let trailers):
            guard !requestEnded, transaction != nil else { fail(ProxyHTTP2Error.invalidMessage); return }
            requestEnded = true
            bodyCapture?.flush()
            if capture, let tx = transaction {
                let headers = Self.capturedHeaders(trailers ?? .init())
                let sink = published ? engine.sink : nil
                commitMetadata(tx) { tx in
                    tx.requestTrailers = headers
                    tx.requestBodyComplete = true
                    sink?.transactionUpdated(tx)
                }
            }
            if !responseEnded {
                // HTTP/1.1 trailers require chunked framing. HTTP/2 keeps the trailing HEADERS.
                enqueue(.end(trailers.map(Self.endToEndHeaders)), bytes: 0)
            }
            if let gate, gate.phase == .request, !gate.submitted {
                fail(ProxyHTTP2Error.invalidMessage)
            }
        }
    }

    private func recordRequestBody(_ bytes: ByteBuffer) {
        if capture { bodyCapture?.append(bytes.readableBytesView, direction: .upstream) }
    }

    private func receiveRequestHead(_ head: NIOHTTP1.HTTPRequestHead) {
        requestMethod = head.method
        guard head.method != .CONNECT, !head.method.rawValue.isEmpty,
              head.method.rawValue.utf8.allSatisfy(HTTP2HeaderValidation.isToken),
              (head.uri.hasPrefix("/") || head.uri == "*"), !head.uri.contains("#"),
              HTTP2HeaderValidation.validValue(head.uri, pseudo: true),
              let authority = head.headers["host"].first,
              let parts = URLComponents(string: "https://\(authority)"), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil,
              URLParser.bareHost(host).caseInsensitiveCompare(authorityHost) == .orderedSame,
              (parts.port ?? 443) == authorityPort else {
            sendLocal(status: 421, type: "text/plain", data: Data(ProxyHTTP2Error.invalidAuthority.localizedDescription.utf8))
            return
        }

        capture = engine.recordingEnabled
        let tx = Transaction(captureBudget: capture ? .live : nil)
        tx.scheme = "https"
        tx.host = URLParser.bareHost(host)
        tx.port = authorityPort
        tx.method = head.method.rawValue
        (tx.path, tx.query) = splitQueryPath(head.uri)
        tx.requestVersion = "HTTP/2"
        tx.responseVersion = "HTTP/2"
        tx.clientAddress = client?.ipAddress
        tx.peerPort = UInt16(client?.port ?? 0)
        if let version = TLSConnectionMetadata.clientVersion(on: downstream) {
            tx.connectionDetails = ProxyConnectionDetails(clientTLSVersion: version)
        }
        tx.setClientApplication(clientApplication)
        transparentFlow?.mark(tx)
        tx.isTLSIntercepted = true
        tx.state = .awaiting
        tx.captureLimit = capture ? engine.captureLimit : 0
        if capture, let loop = downstream?.eventLoop {
            bodyCapture = TransactionCapture(transaction: tx, on: loop, sink: engine.sink)
        }
        transaction = tx
        metadataPublication = MetadataPublication(tx)
        diagnosticHeaders = DiagnosticHeaders(requestID: tx.id)
        let target = ScriptingTarget(method: tx.method, scheme: tx.scheme, host: tx.host, path: tx.path,
                                     query: tx.query, url: tx.fullURL)
        originalTarget = target
        var request = head
        var validated = Self.capturedHeaders(head.headers)
        do { _ = try HTTPFraming.normalize(&validated, request: true) }
        catch { fail(error, status: 400); return }
        request.headers = Self.endToEndHeaders(NIOHTTP1.HTTPHeaders(validated.pairs.map { ($0.name, $0.value) }))
        tx.requestHeaders = Self.capturedHeaders(request.headers)
        capturedRequestHeaders = tx.requestHeaders
        requestMetadata = RequestRouteMetadata(method: tx.method, scheme: tx.scheme, host: tx.host, port: tx.port,
                                               path: tx.path, query: tx.query, headers: capturedRequestHeaders)
        let candidate = BreakpointHead.request(HTTPRequestHead(method: tx.method, target: request.uri,
            version: "HTTP/2", headers: tx.requestHeaders))
        if startInterception(candidate, phase: .request) {
            waitingForUpstream = true
        } else {
            routeRequest(request, tx: tx)
        }
    }

    private func routeRequest(_ head: NIOHTTP1.HTTPRequestHead, tx: Transaction) {
        guard let downstream, downstream.isActive, !responseEnded else { return }
        let headers = Self.endToEndHeaders(head.headers)
        guard var input = requestMetadata else { return }
        input.headers = Self.capturedHeaders(headers)
        capturedRequestHeaders = input.headers
        let plan = RequestRoutePlan(request: input, rules: requestRules())
        let captured = capturedRequestHeaders
        commitMetadata(tx) { $0.requestHeaders = captured }
        if let rejection = plan.rejection {
            commitMetadata(tx) { $0.matchedByBlock = true }
            diagnosticHeaders.record(.block)
            if let status = plan.blockAction.statusCode {
                sendLocal(status: status, type: "text/plain", data: Data(rejection.diagnostic.utf8))
            } else {
                markAborted(CapturedFailure(code: OperationIssue.networkRouteBlocked.code,
                                           diagnostic: rejection.diagnostic))
                publish(tx)
                downstream.close(promise: nil)
            }
            return
        }
        if let lookup = plan.prepareLocal(on: downstream.eventLoop) {
            waitingForUpstream = true
            setReading(downstream, false)
            lookup.whenComplete { [weak self] result in
                guard let self, downstream.isActive, !self.responseEnded else { return }
                switch result {
                case .success(let local?):
                    self.commitMetadata(tx) { $0.matchedByMapLocal = true }
                    self.diagnosticHeaders.record(.mapLocal)
                    self.sendLocal(status: local.status, type: local.contentType, body: ByteBuffer(),
                                   contentLength: local.contentLength, headers: local.headers, file: local.body)
                case .success(nil):
                    self.routeUpstream(head, tx: tx, plan: plan)
                case .failure(let error):
                    self.publish(tx)
                    self.fail(error, status: 503)
                }
            }
            return
        }
        routeUpstream(head, tx: tx, plan: plan)
    }

    private func routeUpstream(_ head: NIOHTTP1.HTTPRequestHead, tx: Transaction, plan: RequestRoutePlan) {
        guard let downstream, downstream.isActive, !responseEnded else { return }
        let route = plan.upstream()
        routedUpstream = route
        requestMetadata = route.request
        let path = route.request.target
        if route.mappedRemote {
            diagnosticHeaders.record(.mapRemote)
        }
        removeResponseCacheHeaders = route.noCaching
        let headers = annotatedHeaders(NIOHTTP1.HTTPHeaders(route.request.headers.pairs.map { ($0.name, $0.value) }))
        capturedRequestHeaders = Self.capturedHeaders(headers)
        simulation = route.simulation
        let captured = capturedRequestHeaders
        commitMetadata(tx) { tx in
            tx.matchedByMapRemote = route.mappedRemote
            if route.mappedRemote, tx.originalURL == nil { tx.originalURL = route.originalURL }
            tx.host = route.request.host
            tx.port = route.request.port
            tx.scheme = route.request.scheme
            tx.path = route.request.path
            tx.query = route.request.query
            tx.requestHeaders = captured
            tx.resolvedAddress = route.resolvedAddress
            tx.simulatedLatencyMs = !route.simulation.disconnect && route.simulation.requestDelay > 0 ? route.simulation.requestDelay : nil
        }
        if simulation.disconnect {
            publish(tx)
            markAborted(NetworkFailure.capture(NetworkFailure(.networkRandomDisconnect)))
            // Closing an active HTTP/2 stream emits RST_STREAM without affecting sibling streams.
            downstream.close(promise: nil)
            return
        }
        let delay = simulation.requestDelay
        if simulation.bandwidth.uploadKbps != nil || simulation.bodyPause.enabled {
            uploadPacer = BytePacingQueue(loop: downstream.eventLoop, onBackpressure: { [weak self] _ in
                self?.resumeRequestReads()
            }, onFailure: { [weak self] error in self?.fail(error) })
        }
        if simulation.bandwidth.downloadKbps != nil || simulation.bodyPause.enabled || simulation.responseDelay > 0 {
            downloadPacer = BytePacingQueue(loop: downstream.eventLoop, onBackpressure: { [weak self] _ in
                self?.resumeResponseReads()
            }, onFailure: { [weak self] error in self?.fail(error) })
        }
        let dialHost = route.resolvedAddress ?? (route.mappedRemote ? route.request.host : transparentFlow?.dialHost ?? route.request.host)
        let origin = HTTPOrigin(host: route.request.host, dialHost: dialHost, port: route.request.port, tls: route.request.scheme == "https")
        publish(tx)

        queuedRequest.insert(.head(NIOHTTP1.HTTPRequestHead(version: .http1_1, method: head.method, uri: path, headers: headers)), at: 0)
        waitingForUpstream = true
        setReading(downstream, false)
        if delay > 0 {
            simulatedDelay = downstream.eventLoop.scheduleTask(in: .milliseconds(Int64(delay))) { [weak self] in
                self?.simulatedDelay = nil
                self?.open(origin: origin)
            }
        } else {
            open(origin: origin)
        }
    }

    private func publish(_ tx: Transaction) {
        guard capture, !published else { return }
        published = true
        let sink = engine.sink
        metadataPublication?.publish { sink?.transactionCreated($0) }
    }

    private func commitMetadata(_ transaction: Transaction, _ update: @escaping (Transaction) -> Void) {
        if let metadataPublication, metadataPublication.value === transaction { metadataPublication.update(update) }
        else { MetadataPublication<Transaction>.onMain { update(transaction) } }
    }

    // MARK: Per-stream rule gates

    private func startInterception(_ head: BreakpointHead, phase: BreakpointRule.Phase) -> Bool {
        guard let target = originalTarget, let downstream else { return false }
        let rule = BreakpointManager.enabledSnapshot.value && RuleOrganizationStore.shared.isEnabled("breakpoints") ? InterceptionConfig.shared.breakpoints.value.first {
            $0.enabled && RuleOrganizationStore.shared.ruleIsEnabled(tool: "breakpoints", id: $0.id) &&
                $0.rule.enabled && $0.phase == phase &&
                $0.rule.matches(method: target.method, scheme: target.scheme, host: target.host,
                                path: target.path, query: target.query, fullURL: target.url,
                                graphqlName: graphqlOperation)
        } : nil
        let script = ScriptingService.plan(for: target, phase: phase == .request ? .request : .response)
        guard rule != nil || script != nil else { return false }
        let timeout = rule == nil ? TimeAmount.seconds(30) : engine.breakpointTimeout
        let deadline = Date().addingTimeInterval(Double(timeout.nanoseconds) / 1_000_000_000)
        let stage = StreamInterception(phase: phase, head: head, rule: rule, script: script,
            length: Self.editableLength(head, method: requestMethod), session: engine.breakpointSessionID,
            deadline: deadline)
        gate = stage
        stage.timer = downstream.eventLoop.scheduleTask(in: timeout) { [weak self] in
            self?.fail(NetworkFailure(rule == nil ? .networkScriptTimeout : .networkBreakpointTimeout), status: 504)
        }
        if (stage.length ?? 0) == 0 { submitInterception(stage) }
        return true
    }

    private static func editableLength(_ head: BreakpointHead, method: NIOHTTP1.HTTPMethod?) -> Int? {
        if case .response(let response) = head, method == .HEAD || BreakpointMessage.noBodyStatus(response.status) {
            return nil
        }
        let headers = head.headers
        let type = (headers.value(of: "content-type") ?? "").lowercased()
        let lengths = headers.values(of: "content-length")
        guard lengths.count == 1, let length = Int(lengths[0]),
              (0...BreakpointMessage.bodyLimit).contains(length), !headers.contains("content-encoding"),
              !headers.contains("expect"), !type.hasPrefix("application/grpc"),
              !type.hasPrefix("text/event-stream") else { return nil }
        return length
    }

    private func collect(_ bytes: ByteBuffer) {
        guard let gate, let length = gate.length else { return }
        guard bytes.readableBytes <= length - gate.body.count else {
            fail(ProxyHTTP2Error.invalidMessage)
            return
        }
        gate.body.append(contentsOf: bytes.readableBytesView)
        if !gate.submitted && gate.body.count == length { submitInterception(gate) }
    }

    private func queueResponseDuringInterception(_ part: HTTPClientResponsePart) {
        guard let gate, !queuedResponseEnded, queuedResponse.count < Self.maxPausedParts else {
            fail(ProxyHTTP2Error.invalidMessage)
            return
        }
        switch part {
        case .head:
            fail(ProxyHTTP2Error.invalidMessage)
        case .body(let bytes):
            queuedResponseBytes += bytes.readableBytes
            guard queuedResponseBytes <= Self.maxQueuedRequest else { fail(ProxyHTTP2Error.invalidMessage); return }
            queuedResponse.append(part)
            collect(bytes)
        case .end:
            queuedResponse.append(part)
            queuedResponseEnded = true
            if !gate.submitted { fail(ProxyHTTP2Error.invalidMessage) }
        }
    }

    private func submitInterception(_ stage: StreamInterception) {
        guard let target = originalTarget, let tx = transaction, let downstream else { return }
        stage.submitted = true
        if stage.phase == .request {
            setReading(downstream, false)
        } else if let source = upstream?.channel {
            setReading(source, false)
        }

        guard let label = stage.label else {
            resumeInterception(stage.id, decision: .original)
            return
        }
        let item = BreakpointManager.HeldItem(id: stage.id, txID: tx.id, phase: stage.phase,
            summary: "\(target.method) \(target.url)", source: client?.description ?? "本机客户端", rule: label,
            message: BreakpointMessage(head: stage.head, body: stage.length.flatMap { _ in
                BreakpointMessage.editableText(stage.body)
            }), deadline: stage.deadline)
        let loop = downstream.eventLoop
        let engine = engine
        let session = stage.session
        DispatchQueue.main.async {
            guard session == engine.breakpointSessionID else {
                loop.execute { [weak self] in self?.resumeInterception(item.id, decision: .discard) }
                return
            }
            BreakpointManager.shared.hold(item) { [weak self] decision in
                loop.execute { [weak self] in self?.resumeInterception(item.id, decision: decision) }
            }
        }
    }

    private func resumeInterception(_ id: UUID, decision: BreakpointManager.Decision) {
        guard let stage = gate, stage.id == id, !responseEnded, let downstream else { return }
        let edit: BreakpointMessage?
        switch decision {
        case .drop(let reason): fail(NetworkFailure(.technical(reason))); return
        case .discard: fail(NetworkFailure(.networkSessionCleared)); return
        case .original: edit = nil
        case .apply(let message): edit = message
        }
        let head = edit?.head ?? stage.head
        let body = edit?.body ?? stage.length.flatMap { _ in BreakpointMessage.editableText(stage.body) }
        if let script = stage.script {
            let loop = downstream.eventLoop
            ScriptingService.run(script, head: head, body: body, graphqlName: graphqlOperation) { [weak self] result in
                loop.execute { [weak self] in
                    guard let self, self.gate?.id == id else { return }
                    if script.phase == .request { self.graphqlOperation = result.graphqlOperationName }
                    if script.phase == .request, let mock = result.mockResponse {
                        self.releaseMockInterception(id, head: result.head, body: result.body, mock: mock, logs: result.logs)
                    } else {
                        self.releaseInterception(id, head: result.head, body: result.body, logs: result.logs)
                    }
                }
            }
        } else {
            releaseInterception(id, head: head, body: edit?.body, logs: [])
        }
    }

    private func releaseMockInterception(_ id: UUID, head: BreakpointHead, body: Data?,
                                         mock: ScriptingMockResponse, logs: [String]) {
        guard gate?.id == id, let tx = transaction, let stage = takeInterception(), !responseEnded,
              case .request(let edited) = head else { return }
        if stage.script != nil { diagnosticHeaders.record(.scripting) }
        if stage.rule != nil { diagnosticHeaders.record(.breakpoint) }
        capturedRequestHeaders = edited.headers
        let ended = requestEnded
        commitMetadata(tx) { tx in
            if let label = stage.label { tx.breakpointRules.append(label) }
            if !logs.isEmpty { tx.appendScriptingLogs(logs) }
            tx.requestHeaders = edited.headers
            tx.requestBodyComplete = ended
        }
        if let body {
            if !body.isEmpty { recordRequestBody(ByteBuffer(bytes: body)) }
        } else {
            for part in queuedRequest {
                if case .body(.byteBuffer(let bytes)) = part { recordRequestBody(bytes) }
            }
        }
        publish(tx)
        sendLocal(status: mock.status, type: mock.headers.value(of: "Content-Type") ?? "text/plain; charset=utf-8",
                  body: ByteBuffer(bytes: mock.body), contentLength: mock.body.count, headers: mock.headers)
    }

    private func releaseInterception(_ id: UUID, head: BreakpointHead, body: Data?, logs: [String]) {
        guard gate?.id == id, let tx = transaction, let stage = takeInterception(), !responseEnded else { return }
        if stage.script != nil { diagnosticHeaders.record(.scripting) }
        if stage.rule != nil { diagnosticHeaders.record(.breakpoint) }
        switch head {
        case .request(let edited):
            commitMetadata(tx) { tx in
                if let label = stage.label { tx.breakpointRules.append(label) }
                if !logs.isEmpty { tx.appendScriptingLogs(logs) }
            }
            if let body, body != stage.body {
                queuedRequest.removeAll { if case .body = $0 { return true }; return false }
                if !body.isEmpty { queuedRequest.insert(.body(.byteBuffer(ByteBuffer(bytes: body))), at: 0) }
            }
            for part in queuedRequest {
                if case .body(.byteBuffer(let bytes)) = part { recordRequestBody(bytes) }
            }
            let headers = NIOHTTP1.HTTPHeaders(edited.headers.pairs.map { ($0.name, $0.value) })
            guard let method = requestMethod else { fail(ProxyHTTP2Error.invalidMessage); return }
            routeRequest(NIOHTTP1.HTTPRequestHead(version: .http1_1, method: method,
                                                  uri: edited.target, headers: headers), tx: tx)
        case .response(let edited):
            let label = stage.label
            if capture {
                onMain {
                    if let label { tx.breakpointRules.append(label) }
                    if !logs.isEmpty { tx.appendScriptingLogs(logs) }
                }
            }
            var remaining = queuedResponse
            queuedResponse.removeAll()
            queuedResponseBytes = 0
            queuedResponseEnded = false
            if let body, body != stage.body {
                remaining.removeAll { if case .body = $0 { return true }; return false }
                if !body.isEmpty { remaining.insert(.body(ByteBuffer(bytes: body)), at: 0) }
            }
            let headers = NIOHTTP1.HTTPHeaders(edited.headers.pairs.map { ($0.name, $0.value) })
            let response = NIOHTTP1.HTTPResponseHead(version: .init(major: 2, minor: 0),
                status: HTTPResponseStatus(statusCode: edited.status), headers: headers)
            forwardResponse(.head(response))
            for part in remaining { forwardResponse(part) }
            if !upstreamResponseEnded { resumeResponseReads() }
        }
    }

    private func takeInterception() -> StreamInterception? {
        guard let stage = gate else { return nil }
        gate = nil
        stage.timer?.cancel()
        let id = stage.id
        if stage.rule != nil { DispatchQueue.main.async { BreakpointManager.shared.forget(id) } }
        return stage
    }

    private func finishFailedInterception() {
        guard let stage = takeInterception(), let tx = transaction else { return }
        queuedResponse.removeAll()
        queuedResponseBytes = 0
        queuedResponseEnded = false
        if stage.phase == .request {
            if stage.rule != nil && stage.session != engine.breakpointSessionID { capture = false; return }
            commitMetadata(tx) { tx in if let label = stage.label { tx.breakpointRules.append(label) } }
            for part in queuedRequest {
                if case .body(.byteBuffer(let bytes)) = part { recordRequestBody(bytes) }
            }
            publish(tx)
        } else if capture, let label = stage.label {
            onMain { tx.breakpointRules.append(label) }
        }
    }

    private func open(origin: HTTPOrigin) {
        guard let downstream, downstream.isActive, !responseEnded else { return }
        pool.exchange(to: origin, path: routedUpstream?.request.target ?? "/", relay: HTTP2UpstreamRelay(owner: self)).whenComplete { [weak self] result in
            guard let self, downstream.isActive, !self.responseEnded else {
                if case .success(let exchange) = result { exchange.channel.close(promise: nil) }
                return
            }
            switch result {
            case .success(let exchange):
                self.upstream = exchange
                self.waitingForUpstream = false
                self.version = exchange.protocolName
                self.applyConnectionDetails(exchange, downstream: downstream)
                let request = self.queuedRequest
                self.queuedRequest.removeAll()
                self.queuedBytes = 0
                for part in request { self.sendUpstream(part) }
                self.resumeRequestReads()
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    private func applyConnectionDetails(_ exchange: HTTP2UpstreamPool.Exchange, downstream: Channel) {
        guard capture, let tx = transaction else { return }
        downstream.getOption(HTTP2StreamChannelOptions.streamID).whenComplete { result in
            var details = exchange.connection
            details.downstreamStream = (try? result.get()).map { Int($0) }
            details.clientTLSVersion = TLSConnectionMetadata.clientVersion(on: downstream)
            onMain {
                tx.connectionDetails = details
                tx.tConnected = max(exchange.connectedAt, tx.startedAt)
                tx.upstreamProtocol = exchange.protocolName
                self.engine.sink?.transactionUpdated(tx)
            }
        }
    }

    private func enqueue(_ part: HTTPClientRequestPart, bytes: Int) {
        guard !upstreamResponseEnded else { return }
        if upstream != nil {
            sendUpstream(part)
        } else if waitingForUpstream {
            queuedBytes += bytes
            guard queuedBytes <= Self.maxQueuedRequest, queuedRequest.count < Self.maxPausedParts else {
                fail(ProxyHTTP2Error.invalidMessage); return
            }
            queuedRequest.append(part)
        }
    }

    private func sendUpstream(_ part: HTTPClientRequestPart) {
        guard !upstreamResponseEnded, let exchange = upstream else { return }
        if let uploadPacer {
            switch part {
            case .body(.byteBuffer(let buffer)):
                uploadPacer.write(buffer, kilobitsPerSecond: simulation.bandwidth.uploadKbps,
                                  pauseMs: simulation.bodyPause.sample()) {
                    exchange.channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer($0)))
                }
                return
            case .end:
                uploadPacer.afterWrites { [weak self] in self?.writeUpstream(part, exchange: exchange) }
                return
            default: break
            }
        }
        writeUpstream(part, exchange: exchange)
    }

    private func writeUpstream(_ part: HTTPClientRequestPart, exchange: HTTP2UpstreamPool.Exchange) {
        let data: HTTPClientRequestPart
        switch part {
        case .head(var head) where exchange.protocolName == "HTTP/1.1":
            // Match the known HTTP/2 framing for HTTP/1.1, even on methods with an optional body.
            if !head.headers.contains(name: "content-length") { head.headers.add(name: "transfer-encoding", value: "chunked") }
            head.headers.replaceOrAdd(name: "connection", value: "close")
            data = .head(head)
        case .end(let trailers) where exchange.protocolName == "HTTP/1.1":
            let hadLength = capturedRequestHeaders.contains("Content-Length")
            data = .end(hadLength ? nil : trailers)
        default: data = part
        }
        exchange.channel.writeAndFlush(data).whenFailure { [weak self] error in
            guard let self, !self.responseEnded, !self.upstreamResponseEnded else { return }
            self.fail(error)
        }
        if case .end = part { armResponseWait() }
    }

    fileprivate func receiveResponse(_ part: HTTPClientResponsePart) {
        guard !responseEnded, !upstreamResponseEnded else { return }
        if let gate, gate.phase == .response {
            queueResponseDuringInterception(part)
            return
        }
        if case .head(let head) = part, head.status.code >= 200 {
            let headers = Self.capturedHeaders(Self.endToEndHeaders(head.headers))
            let candidate = BreakpointHead.response(HTTPResponseHead(version: "HTTP/2", status: Int(head.status.code),
                reason: "", headers: headers))
            if startInterception(candidate, phase: .response) {
                responseWait?.cancel()
                responseWait = nil
                return
            }
        }
        forwardResponse(part)
    }

    private func forwardResponse(_ part: HTTPClientResponsePart) {
        guard !responseEnded, !upstreamResponseEnded, let downstream, let tx = transaction else { return }
        switch part {
        case .head(let head):
            let code = Int(head.status.code)
            var forwarded = head
            var validated = Self.capturedHeaders(head.headers)
            do { _ = try HTTPFraming.normalize(&validated, request: false) }
            catch { fail(error); return }
            forwarded.headers = Self.endToEndHeaders(NIOHTTP1.HTTPHeaders(validated.pairs.map { ($0.name, $0.value) }))
            if code >= 200 { forwarded.headers = annotatedHeaders(forwarded.headers) }
            if code >= 200 {
                responseStarted = true
                responseWait?.cancel()
                responseWait = nil
                let responseFields = RequestRoutePlan.responseHeaders(Self.capturedHeaders(forwarded.headers), noCaching: removeResponseCacheHeaders)
                forwarded.headers = NIOHTTP1.HTTPHeaders(responseFields.pairs.map { ($0.name.lowercased(), $0.value) })
                let fields = Self.capturedHeaders(forwarded.headers)
                bodyCapture?.setResponseHeadersForSSE(fields)
                let receivedAt = Date()
                if capture {
                    let upstreamVersion = version
                    if upstreamVersion == "HTTP/2", let channel = upstream?.channel {
                        channel.getOption(HTTP2StreamChannelOptions.streamID).whenSuccess { id in
                            onMain {
                                tx.connectionDetails?.upstreamStream = Int(id)
                                self.engine.sink?.transactionUpdated(tx)
                            }
                        }
                    }
                    onMain {
                        tx.statusCode = code
                        tx.statusReason = ""
                        tx.responseVersion = "HTTP/2"
                        tx.upstreamProtocol = upstreamVersion
                        tx.responseHeaders = fields
                        tx.contentType = fields.value(of: "content-type") ?? ""
                        tx.tHeaderAt = receivedAt
                        self.engine.sink?.transactionUpdated(tx)
                    }
                }
            }
            let part = HTTPServerResponsePart.head(forwarded)
            if code >= 200, simulation.responseDelay > 0, let downloadPacer {
                downloadPacer.afterWrites(pauseMs: simulation.responseDelay) { [weak self] in
                    downstream.writeAndFlush(part).whenFailure { [weak self] error in self?.fail(error) }
                }
            } else {
                downstream.writeAndFlush(wrapOutboundOut(part), promise: nil)
            }
        case .body(let bytes):
            guard responseStarted else { fail(ProxyHTTP2Error.invalidMessage); return }
            if capture { bodyCapture?.append(bytes.readableBytesView, direction: .downstream) }
            if let downloadPacer {
                downloadPacer.write(bytes, kilobitsPerSecond: simulation.bandwidth.downloadKbps,
                                    pauseMs: simulation.bodyPause.sample()) {
                    downstream.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer($0)))
                }
            } else {
                downstream.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(bytes))), promise: nil)
            }
        case .end(let trailers):
            guard responseStarted else { return } // HTTP/1.1 can delimit a 1xx with its own .end.
            let safe = trailers.map(Self.endToEndHeaders)
            upstreamResponseEnded = true
            // A final response may precede the client's END_STREAM (401/413,
            // for example). We no longer forward that upload, so its upstream
            // half must be cancelled explicitly. For HTTP/2 this closes only
            // the child, retaining its parent and releasing the pool's slot.
            uploadPacer?.cancel()
            queuedRequest.removeAll()
            queuedBytes = 0
            upstream?.channel.close(promise: nil)
            if let downloadPacer {
                downloadPacer.afterWrites { [weak self] in self?.finishResponse(safe) }
            } else {
                finishResponse(safe)
            }
        }
    }

    private func finishResponse(_ trailers: NIOHTTP1.HTTPHeaders?) {
        guard let downstream, let tx = transaction, !responseEnded else { return }
        let recorded = Self.capturedHeaders(trailers ?? .init())
        bodyCapture?.finishSSE()
        responseEnded = true
        if capture {
            onMain {
                tx.responseTrailers = recorded
                tx.responseBodyComplete = true
                tx.duration = Date().timeIntervalSince(tx.startedAt)
                tx.state = .completed
                self.engine.sink?.transactionUpdated(tx)
            }
        }
        downstream.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: nil)
        if upstream?.protocolName == "HTTP/1.1" { upstream?.channel.close(promise: nil) }
        setReading(downstream, true)
    }

    private func armResponseWait() {
        guard let downstream, responseWait == nil, !responseStarted, !responseEnded,
              gate?.phase != .response else { return }
        responseWait = downstream.eventLoop.scheduleTask(in: .seconds(30)) { [weak self] in
            self?.fail(ProxyHTTP2Error.responseTimeout, status: 504)
        }
    }

    private func sendLocal(status: Int, type: String, data: Data, error: CapturedFailure? = nil) {
        let body = requestMethod == .HEAD ? ByteBuffer() : ByteBuffer(bytes: data)
        sendLocal(status: status, type: type, body: body, contentLength: data.count, headers: HTTPHeaders(), error: error)
    }

    private func sendLocal(status: Int, type: String, body: ByteBuffer, contentLength: Int,
                           headers: HTTPHeaders, error: CapturedFailure? = nil, file: MapLocalFile? = nil) {
        guard let downstream, !responseEnded else { return }
        let sendBody = requestMethod != .HEAD && ![204, 205, 304].contains(status)
        var fields = Self.endToEndHeaders(NIOHTTP1.HTTPHeaders(headers.pairs.map { ($0.name, $0.value) }))
        fields.replaceOrAdd(name: "content-type", value: type)
        fields.remove(name: "content-length")
        if ![204, 304].contains(status) {
            fields.add(name: "content-length", value: String(status == 205 ? 0 : contentLength))
        }
        fields = annotatedHeaders(fields)
        if let tx = transaction {
            capturedRequestHeaders = diagnosticHeaders.appending(to: capturedRequestHeaders)
            let headers = capturedRequestHeaders
            commitMetadata(tx) { $0.requestHeaders = headers }
        }
        let head = NIOHTTP1.HTTPResponseHead(version: .init(major: 2, minor: 0),
                                             status: HTTPResponseStatus(statusCode: status), headers: fields)
        waitingForUpstream = false
        queuedRequest.removeAll()
        queuedBytes = 0
        responseStarted = true
        if let tx = transaction {
            let recorded = Self.capturedHeaders(fields)
            commitMetadata(tx) { tx in
                tx.statusCode = status
                tx.statusReason = ""
                tx.responseHeaders = recorded
                tx.contentType = type
            }
            publish(tx)
        }
        downstream.write(wrapOutboundOut(.head(head)), promise: nil)
        if let file {
            downstream.flush()
            if capture, let tx = transaction {
                let recorded = Self.capturedHeaders(fields)
                onMain {
                    tx.statusCode = status
                    tx.statusReason = ""
                    tx.responseHeaders = recorded
                    tx.contentType = type
                    self.engine.sink?.transactionUpdated(tx)
                }
            }
            let sender = MapLocalSender(file: file, channel: downstream, write: { [weak self] channel, bytes in
                self?.bodyCapture?.append(bytes.readableBytesView, direction: .downstream)
                return channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(bytes)))
            }, completion: { [weak self] result in
                guard let self, !self.responseEnded else { return }
                self.mapLocalSender = nil
                switch result {
                case .success: self.finishResponse(nil)
                case .failure(let error): self.fail(error)
                }
            })
            mapLocalSender = sender
            setReading(downstream, true)
            sender.resume()
            return
        }
        if sendBody && body.readableBytes > 0 {
            bodyCapture?.append(body.readableBytesView, direction: .downstream)
            downstream.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        }
        bodyCapture?.finishSSE()
        responseEnded = true
        downstream.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        setReading(downstream, true)
        if capture, let tx = transaction {
            let recorded = Self.capturedHeaders(fields)
            onMain {
                tx.statusCode = status
                tx.statusReason = ""
                tx.responseHeaders = recorded
                tx.contentType = type
                tx.responseBodyComplete = true
                tx.setFailure(error)
                tx.state = error == nil ? .completed : .failed
                tx.duration = Date().timeIntervalSince(tx.startedAt)
                self.engine.sink?.transactionUpdated(tx)
            }
        }
    }

    fileprivate func fail(_ error: Error, status: Int = 502) {
        guard !responseEnded else { return }
        finishFailedInterception()
        let failure = NetworkFailure.capture(error)
        let message = failure.diagnostic
        if responseStarted {
            markAborted(failure)
            downstream?.close(promise: nil)
        } else {
            sendLocal(status: status, type: "text/plain", data: Data(message.utf8), error: failure)
        }
        simulatedDelay?.cancel()
        responseWait?.cancel()
        queuedRequest.removeAll()
        uploadPacer?.cancel()
        downloadPacer?.cancel()
        upstream?.channel.close(promise: nil)
    }

    private func markAborted(_ failure: CapturedFailure) {
        guard !responseEnded else { return }
        mapLocalSender?.cancel()
        mapLocalSender = nil
        finishFailedInterception()
        bodyCapture?.finishSSE(complete: false)
        responseEnded = true
        if capture, let tx = transaction {
            let sink = published ? engine.sink : nil
            let elapsed = Date().timeIntervalSince(tx.startedAt)
            commitMetadata(tx) { tx in
                tx.state = .failed
                tx.setFailure(failure)
                tx.duration = elapsed
                sink?.transactionUpdated(tx)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        markAborted(NetworkFailure.capture(NetworkFailure(.networkH2Cancelled)))
        bodyCapture?.finishSSE(complete: false)
        bodyCapture = nil
        simulatedDelay?.cancel()
        responseWait?.cancel()
        queuedRequest.removeAll()
        uploadPacer?.cancel()
        downloadPacer?.cancel()
        upstream?.channel.close(promise: nil)
        downstream = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Malformed or reset downstream streams cannot receive an HTTP response.
        markAborted(NetworkFailure.capture(error))
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        resumeResponseReads()
        mapLocalSender?.resume()
        context.fireChannelWritabilityChanged()
    }

    fileprivate func resumeRequestReads() {
        if !waitingForUpstream, let downstream {
            setReading(downstream, (upstream?.channel.isWritable ?? true) && uploadPacer?.isBackpressured != true)
        }
    }

    private func resumeResponseReads() {
        if let channel = upstream?.channel, let downstream {
            let heldResponse = gate?.phase == .response && gate?.submitted == true
            setReading(channel, !heldResponse && downstream.isWritable && downloadPacer?.isBackpressured != true)
        }
    }

    fileprivate func upstreamClosed() {
        if !upstreamResponseEnded && !queuedResponseEnded { fail(ProxyHTTP2Error.connectionClosed) }
    }

    fileprivate func upstreamFailed(_ error: Error) {
        if !upstreamResponseEnded && !queuedResponseEnded { fail(error) }
    }

    private func setReading(_ channel: Channel, _ enabled: Bool) {
        channel.setOption(ChannelOptions.autoRead, value: enabled).whenSuccess {
            // NIO's stream channel only toggles the flag. A read also releases already-buffered frames.
            if enabled {
                channel.eventLoop.execute {
                    if channel.isActive { channel.read() }
                }
            }
        }
    }

    private func annotatedHeaders(_ headers: NIOHTTP1.HTTPHeaders) -> NIOHTTP1.HTTPHeaders {
        let annotated = diagnosticHeaders.appending(to: Self.capturedHeaders(headers))
        return NIOHTTP1.HTTPHeaders(annotated.pairs.map { ($0.name.lowercased(), $0.value) })
    }

    static func endToEndHeaders(_ headers: NIOHTTP1.HTTPHeaders) -> NIOHTTP1.HTTPHeaders {
        let nominated = headers[canonicalForm: "connection"].map { $0.lowercased() }
        let removed = Set(["connection", "proxy-connection", "proxy-authorization", "proxy-authenticate",
                           "keep-alive", "upgrade", "transfer-encoding"] + nominated)
        return NIOHTTP1.HTTPHeaders(headers.compactMap { field in
            let name = field.name.lowercased()
            if removed.contains(name) || (name == "te" && field.value.lowercased() != "trailers") { return nil }
            return (name, field.value)
        })
    }

    static func capturedHeaders(_ headers: NIOHTTP1.HTTPHeaders) -> HTTPHeaders {
        HTTPHeaders(headers.map { ($0.name, $0.value) })
    }
}

final class HTTP2UpstreamRelay: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private weak var owner: HTTP2ProxyStream?

    init(owner: HTTP2ProxyStream) { self.owner = owner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        owner?.receiveResponse(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.upstreamClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner?.upstreamFailed(error)
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        owner?.resumeRequestReads()
        context.fireChannelWritabilityChanged()
    }
}
