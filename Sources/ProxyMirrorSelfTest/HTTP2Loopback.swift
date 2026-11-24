import CryptoKit
import Foundation
import Combine
import NIOCore
@testable import ProxyMirrorCore

private final class HTTP2LoopbackSink: TrafficSink {
    var records: [Transaction] = []
    private var metadataSubscriptions: [AnyCancellable] = []
    func transactionCreated(_ tx: Transaction) {
        precondition(Thread.isMainThread, "HTTP/2 publication must run on the main thread")
        records.append(tx)
        metadataSubscriptions.append(tx.objectWillChange.sink { _ in
            precondition(Thread.isMainThread, "Published HTTP/2 metadata, including cancellation, changed off main")
        })
    }
    func transactionUpdated(_ tx: Transaction) { precondition(Thread.isMainThread) }
}

func runHTTP2LoopbackTests() {
    struct Observation: Decodable {
        let `protocol`: String
        let origin: String
        let connection: String
        let overlap: String
        let body: Data?
        let trailer: String
        let grpcStatus: String
        let sentTrailer: String
        let status: Int
        let bodySize: Int
        let length: Int
        let bodySHA256: String
        let ruleResult: String?
        let error: String?

        var text: String { String(decoding: body ?? Data(), as: UTF8.self) }
    }

    let env = ProcessInfo.processInfo.environment
    guard let fixture = env["PM_HTTP2_FIXTURE"], let first = env["PM_HTTP2_ORIGIN"],
          let fallback = env["PM_HTTP2_FALLBACK"], let cert = env["PM_HTTP2_CA"],
          let support = env["PM_SUPPORT_DIR"], support.hasPrefix("/"),
          !FileManager.default.fileExists(atPath: RulesStore.rulesPath.path) else {
        check(false, "HTTP/2: use Scripts/test_http2.py to start an isolated fixture")
        return
    }

    let engine = ProxyEngine.shared
    let sink = HTTP2LoopbackSink()
    let rules = RulesStore.shared
    engine.sink = sink
    engine.captureLimit = 4096
    defer { engine.stop(); TLSKeyLog.shared.stop() }

    do {
        try UpstreamTrust.install(Data(contentsOf: URL(fileURLWithPath: cert)))
        try CertificateAuthority.shared.ensureCA()
        let keyLog = URL(fileURLWithPath: support).appendingPathComponent("test-tls.keys")
        try TLSKeyLog.shared.start(at: keyLog)
        InterceptionConfig.shared.dnsSpoof.set([DNSSpoofRule(hostPattern: "allowed.pm.test", ip: "127.0.0.1")])
        rules.sslProxyingList = [ProxyRule(pattern: "allowed.pm.test")]
        rules.mapRemote = [ProxyRule(pattern: "https://allowed.pm.test:\(first)/mapped",
                                    target: "https://allowed.pm.test:\(fallback)/forwarded?from=rule")]
        try engine.start(port: 0)

        func runClient(_ scenario: String, whileRunning: () -> Void = {}) throws -> [String: Observation] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: fixture)
            process.arguments = ["client", "http://\(engine.listenAddress)", CertificateAuthority.shared.caCertPath.path,
                                 first, fallback, scenario]
            process.standardOutput = output
            try process.run()
            let deadline = Date().addingTimeInterval(45)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                whileRunning()
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                throw NSError(domain: "HTTP2Fixture", code: Int(process.terminationStatus))
            }
            return try JSONDecoder().decode([String: Observation].self, from: data)
        }

        let client = try runClient("h2")
        for (name, value) in client where value.error != nil { print("HTTP/2 fixture \(name): \(value.error ?? "")") }
        eq(client["warm"]?.protocol, "HTTP/2.0", "HTTP/2: downstream TLS negotiates h2")
        eq(client["warm"]?.origin, "HTTP/2.0", "HTTP/2: upstream TLS negotiates h2")
        eq(client["left"]?.text, "/left", "HTTP/2: left stream body")
        eq(client["right"]?.text, "/right", "HTTP/2: right stream body")
        check(client["left"]?.overlap == "true" || client["right"]?.overlap == "true", "HTTP/2: concurrent upstream handlers")
        check(client["left"]?.connection == client["right"]?.connection && client["left"]?.connection == client["warm"]?.connection
              && client["warm"]?.connection.isEmpty == false, "HTTP/2: upstream streams share one TLS connection")
        eq(client["left"]?.trailer, "/left", "HTTP/2: left response trailer")
        eq(client["right"]?.trailer, "/right", "HTTP/2: right response trailer")
        eq(client["cancel"]?.text, "started", "HTTP/2: cancelled stream started normally")
        eq(client["keep"]?.text, "survived", "HTTP/2: sibling completes after cancellation")
        eq(client["cancel-status"]?.text, "true", "HTTP/2: downstream cancellation reaches upstream")
        eq(client["fallback"]?.protocol, "HTTP/2.0", "HTTP/2: downstream unaffected by upstream fallback")
        eq(client["fallback"]?.origin, "HTTP/1.1", "HTTP/2: upstream HTTP/1.1 fallback")
        eq(client["mapped"]?.text, "/forwarded/mapped", "HTTP/2: Map Remote reaches configured upstream path")
        eq(client["large"]?.bodySize, 294_912, "HTTP/2: bidirectional payload exceeds the initial stream window")
        eq(client["large"]?.bodySHA256, "e781d20bc8ec496139840b710d1540bcf027533036ad997d3063be3139e42cd7",
           "HTTP/2: flow-controlled body arrives intact")

        let left = sink.records.first { $0.path == "/left" && !$0.isTunnel }
        let right = sink.records.first { $0.path == "/right" && !$0.isTunnel }
        check(left?.connectionDetails?.downstreamStream != nil &&
              left?.connectionDetails?.downstreamStream != right?.connectionDetails?.downstreamStream, "HTTP/2: distinct captured stream IDs")
        eq(left?.responseTrailers.value(of: "x-fixture-trailer"), "/left", "HTTP/2: capture correct trailer")
        eq(left?.statusText, "200", "HTTP/2: status without reason phrase")
        eq(left?.upstreamProtocol, "HTTP/2", "HTTP/2: capture negotiated upstream protocol")
        eq(sink.records.first { $0.path == "/fallback" }?.upstreamProtocol, "HTTP/1.1", "HTTP/2: capture fallback protocol")
        eq(sink.records.first { $0.path == "/cancel" }?.state, .failed, "HTTP/2: cancelled stream recorded as failed")
        let large = sink.records.first { $0.path == "/large" }
        check(large?.requestBytes == 294_912 && large?.responseBytes == 294_912 &&
              large?.requestBody.count == 4096 && large?.responseBody.count == 4096 &&
              large?.requestTruncated == true && large?.responseTruncated == true, "HTTP/2: capture cap does not limit forwarding")
        check(left?.connectionDetails?.tlsMilliseconds != nil && left?.connectionDetails?.alpn == "h2" &&
              left?.connectionDetails?.upstreamStream != nil, "HTTP/2: TLS phase and upstream stream ID recorded")

        engine.captureLimit = 1024 * 1024
        let savedExtendedScripts = InterceptionConfig.shared.rewrite.value
        InterceptionConfig.shared.rewrite.set([RewriteRuleSet(rules: [RewriteRule(
            rule: URLRule(method: "CONNECT", host: "allowed.pm.test", path: "/rfc8441"),
            actions: [.script(phase: .webSocket,
                source: #"if (message.direction === "send" && message.opcode === 1 && message.body === "before") return "after";"#)]),
        ])])
        let extended = try runClient("rfc8441")
        InterceptionConfig.shared.rewrite.set(savedExtendedScripts)
        for (name, value) in extended where value.error != nil { print("RFC8441 fixture \(name): \(value.error ?? "")") }
        eq(extended["rfc8441"]?.status, 200, "RFC8441: extended CONNECT receives HTTP/2 200")
        eq(extended["rfc8441"]?.ruleResult, "enable-connect=1", "RFC8441: client observes SETTINGS_ENABLE_CONNECT_PROTOCOL")
        eq(extended["rfc8441"]?.text, "after", "RFC8441: a real frame script rewrites the final text before END_STREAM")
        eq(extended["rfc8441"]?.bodySize, 196_608, "RFC8441: a bidirectional WS frame crosses the initial stream/connection windows")
        eq(extended["sibling"]?.text, "/rfc8441-sibling", "RFC8441: ordinary HTTP stream shares the connection")
        eq(extended["cancel"]?.text, "true", "RFC8441: RST_STREAM cancels the origin without closing sibling streams")
        let extendedCapture = sink.records.last { $0.path == "/rfc8441" && !$0.isTunnel }
        check(extendedCapture?.method == "CONNECT" && extendedCapture?.requestVersion == "HTTP/2" &&
              extendedCapture?.responseVersion == "HTTP/2" && extendedCapture?.statusCode == 200 &&
              extendedCapture?.isWebSocket == true, "RFC8441: capture preserves downstream CONNECT/H2 semantics")
        check(extendedCapture?.upstreamProtocol == "HTTP/1.1" && extendedCapture?.connectionDetails?.downstreamStream != nil,
              "RFC8441: capture records actual upstream protocol and downstream stream ID")
        check(extendedCapture?.requestHeaders.value(of: "Sec-WebSocket-Key") == nil &&
              extendedCapture?.responseHeaders.value(of: "Sec-WebSocket-Accept") == nil &&
              extendedCapture?.responseHeaders.value(of: "Connection") == nil,
              "RFC8441: origin-only handshake headers are absent from downstream capture")
        check(extendedCapture?.websocketFrames.contains { $0.direction == .upstream && $0.kind == .close } == true &&
              extendedCapture?.websocketFrames.contains { $0.direction == .downstream && $0.kind == .close } == true,
              "RFC8441: frame capture retains the bidirectional close handshake")

        engine.captureLimit = 4096

        let localFile = URL(fileURLWithPath: support).appendingPathComponent("http2-local.bin")
        let localBody = Data(repeating: 0x6C, count: 8 * 1024 * 1024)
        try localBody.write(to: localFile)
        rules.mapLocal = [ProxyRule(pattern: "https://allowed.pm.test:\(first)/local-stream",
                                    target: localFile.path, responseStatus: 201,
                                    responseHeaders: HTTPHeaders([("X-Rule-Result", "map-local")]))]
        let local = try runClient("map-local")
        rules.mapLocal = []
        let localDigest = SHA256.hash(data: localBody).map { String(format: "%02x", $0) }.joined()
        eq(local["body"]?.protocol, "HTTP/2.0", "HTTP/2 Map Local: stream uses HTTP/2")
        eq(local["body"]?.bodySize, localBody.count, "HTTP/2 Map Local: all chunks arrive")
        eq(local["body"]?.bodySHA256, localDigest, "HTTP/2 Map Local: body digest matches")
        eq(local["body"]?.status, 201, "HTTP/2 Map Local: custom status")
        eq(local["body"]?.ruleResult, "map-local", "HTTP/2 Map Local: custom header")
        eq(local["head"]?.status, 201, "HTTP/2 Map Local: HEAD status")
        eq(local["head"]?.bodySize, 0, "HTTP/2 Map Local: HEAD carries no body")
        eq(local["head"]?.length, localBody.count, "HTTP/2 Map Local: HEAD preserves Content-Length")
        eq(local["slow"]?.body, Data(repeating: 0x6C, count: 16), "HTTP/2 Map Local: canceled stream starts normally")
        let localCapture = sink.records.last { $0.path == "/local-stream" && $0.method == "GET" }
        check(localCapture?.matchedByMapLocal == true && localCapture?.responseBytes == localBody.count
              && localCapture?.responseBody == localBody.prefix(4096) && localCapture?.responseTruncated == true,
              "HTTP/2 Map Local: total bytes and capped prefix are captured")

        let grpc = sink.records.first { $0.path == "/pm.Echo/Echo" }
        let payload = Data([0, 0, 0, 0, 4, 10, 2, 111, 107, 0, 0, 0, 0, 0])
        eq(client["grpc"]?.body, payload, "gRPC: two framed messages forwarded verbatim")
        eq(client["grpc"]?.sentTrailer, "present", "gRPC: request trailer reaches server")
        eq(client["grpc"]?.grpcStatus, "0", "gRPC: status trailer reaches client")
        eq(grpc?.requestBody, payload, "gRPC: captured request messages")
        eq(grpc?.responseBody, payload, "gRPC: captured response messages")
        eq(grpc?.requestTrailers.value(of: "x-request-check"), "present", "gRPC: captured request trailer")
        eq(grpc?.responseTrailers.value(of: "grpc-message"), "fixture%20ok", "gRPC: captured status message")
        if let grpc {
            let exported = try JSONSerialization.data(withJSONObject: ExportService.buildHAR([grpc]))
            let reloaded = try SessionFile.importHAR(exported).first
            check(reloaded?.state == .completed && reloaded?.requestBody == payload && reloaded?.responseBody == payload &&
                  reloaded?.responseTrailers.value(of: "grpc-status") == "0", "gRPC: HAR preserves bytes, status and trailers")
        }

        let webTrailer = Data("grpc-status: 7\r\ngrpc-message: fixture%20denied\r\nx-fixture-trailer: grpc-web\r\n".utf8)
        let webResponse = payload + Data([0x80, 0, 0, 0, UInt8(webTrailer.count)]) + webTrailer
        func checkGRPCWeb(_ observations: [String: Observation], version: String) throws {
            for (name, path, transport, requestBody, responseBody) in [
                ("grpc-web-binary", "/pm.Web/Binary", GRPCFrames.Transport.webBinary, payload, webResponse),
                ("grpc-web-text", "/pm.Web/Text", GRPCFrames.Transport.webText, payload.base64EncodedData(),
                 payload.prefix(4).base64EncodedData() + webResponse.dropFirst(4).base64EncodedData()),
            ] {
                let label = "\(version) \(name)"
                let wire = observations[name]
                check(wire?.protocol == version && wire?.origin == version && wire?.body == responseBody,
                      "\(label): framed response forwarded verbatim")
                guard let captured = sink.records.last(where: { $0.path == path }) else {
                    check(false, "\(label): captured transaction")
                    continue
                }
                check(captured.isGRPCWeb && captured.requestBody == requestBody && captured.responseBody == responseBody,
                      "\(label): traffic type and wire bytes are captured")
                var scanner = GRPCFrames.Scanner()
                let scan = scanner.scan(captured.responseBody, complete: captured.responseBodyComplete,
                                        truncated: captured.responseTruncated, transport: transport)
                let frames = scanner.frameData(captured.responseBody, transport: transport)
                check(scan.messages.count == 2 && scan.issue == nil, "\(label): response contains two decoded messages")
                if let firstMessage = scan.messages.first {
                    let bytes = try GRPCFrames.payload(of: firstMessage, in: frames, encoding: nil)
                    let decoded = try GRPCProtobuf.describe(bytes, type: nil, schema: nil)
                    check(decoded == "#1: 2 字节 · 6f 6b", "\(label): Protobuf message decodes from captured response")
                }
                let status = GRPCFrames.status(headers: captured.responseHeaders, trailers: scan.trailers)
                check(status.code == "7" && status.message == "fixture denied"
                      && scan.trailers.value(of: "x-fixture-trailer") == "grpc-web",
                      "\(label): status and trailers decode from response body")

                let har = try JSONSerialization.data(withJSONObject: ExportService.buildHAR([captured]))
                let reloaded = try SessionFile.importHAR(har).first
                check(reloaded?.isGRPCWeb == true && reloaded?.responseBody == responseBody
                      && reloaded?.requestBody == requestBody, "\(label): HAR retains the original body encoding")
            }
        }
        try checkGRPCWeb(client, version: "HTTP/2.0")

        if let external = env["PM_HTTP2_EXTERNAL"].flatMap(Int.init) {
            var config = ExternalProxyConfig()
            config.enabled = true
            config.host = "127.0.0.1"
            config.port = external
            InterceptionConfig.shared.externalProxy.set(config)
            let routed = try runClient("external")
            eq(routed["external"]?.origin, "HTTP/2.0", "External proxy: tunneled origin still negotiates HTTP/2")
            check(sink.records.first { $0.path == "/external" }?.connectionDetails?.externalProxy?.contains(String(external)) == true,
                  "External proxy: capture records the route")
            config.bypassHosts = ["allowed.pm.test"]
            InterceptionConfig.shared.externalProxy.set(config)
            let bypass = try runClient("bypass")
            eq(bypass["bypass"]?.text, "/bypass", "External proxy: matched host connects directly")
            check(sink.records.first { $0.path == "/bypass" }?.connectionDetails?.externalProxy == nil,
                  "External proxy: bypass does not record a tunnel")
            let script = URL(fileURLWithPath: support).appendingPathComponent("fixture.pac")
            let contents = """
                function FindProxyForURL(url, host) {
                    return host === "allowed.pm.test" ? "PROXY 127.0.0.1:\(external)" : "DIRECT";
                }
                """
            try Data(contents.utf8).write(to: script)
            config.mode = .pac
            config.pacURL = script.absoluteString
            config.bypassHosts = nil
            InterceptionConfig.shared.externalProxy.set(config)
            let pac = try runClient("pac")
            eq(pac["pac"]?.text, "/pac", "PAC: file-selected CONNECT route forwards HTTP/2")
            check(sink.records.first { $0.path == "/pac" }?.connectionDetails?.externalProxy?.contains(String(external)) == true,
                  "PAC: resolved proxy is recorded in the connection log")
            InterceptionConfig.shared.externalProxy.set(ExternalProxyConfig())
        }

        check(LatencyConditions.install(LatencyConditions(enabled: true, milliseconds: 0, host: "allowed.pm.test",
                                                           uploadKbps: 64, downloadKbps: 64)),
              "HTTP/2: save bandwidth profile")
        let pacedAt = Date()
        let paced = try runClient("paced")
        check(Date().timeIntervalSince(pacedAt) >= 1, "HTTP/2: paced upload/download take measurable time")
        eq(paced["paced"]?.body, Data(String(repeating: "pace", count: 2048).utf8), "HTTP/2: paced body stays intact")
        let volatile = LatencyConditions(enabled: true, milliseconds: 35, host: "allowed.pm.test",
                                         jitterMilliseconds: 10, responseSpikePercent: 100, bodyPausePercent: 100)
        check(LatencyConditions.install(volatile), "HTTP/2: save response spike and body pause")
        let delayed = try runClient("paced")
        let delayedRecord = sink.records.last { $0.path == "/paced" }
        eq(delayed["paced"]?.body, Data(String(repeating: "pace", count: 2048).utf8),
           "HTTP/2: body remains intact with weak network effects")
        check((25...45).contains(delayedRecord?.simulatedLatencyMs ?? -1) && (delayedRecord?.duration ?? 0) >= 0.60,
              "HTTP/2: request jitter, response spike and bidirectional body pauses are applied")

        let disconnect = LatencyConditions(enabled: true, milliseconds: 0, host: "allowed.pm.test", disconnectPercent: 100)
        check(LatencyConditions.install(disconnect), "HTTP/2: save disconnect profile")
        let reset = try runClient("paced")
        let resetRecord = sink.records.last { $0.path == "/paced" }
        check(reset["paced"]?.error?.contains("CANCEL") == true && resetRecord?.state == .failed
              && resetRecord?.errorText == LatencyConditions.disconnectReason && resetRecord?.statusCode == 0,
              "HTTP/2: simulated disconnect resets the stream without an HTTP response")
        _ = LatencyConditions.install(LatencyConditions())

        let plain = try startPlainHTTP2Fixture(group: engine.group)
        defer { try? plain.close().wait() }
        if let port = plain.localAddress?.port {
            InterceptionConfig.shared.h2cUpstream.set(H2CUpstreamConfig(enabled: true, hosts: ["127.0.0.1"]))
            rules.mapRemote.append(ProxyRule(pattern: "https://allowed.pm.test:\(first)/h2c",
                                             target: "http://127.0.0.1:\(port)"))
            let cleartext = try runClient("h2c")
            eq(cleartext["h2c"]?.origin, "HTTP/2.0", "h2c: configured cleartext upstream uses HTTP/2 prior knowledge")
            eq(cleartext["h2c"]?.trailer, "h2c", "h2c: trailers cross the cleartext hop")

            let config = InterceptionConfig.shared
            let originalDNS = config.dnsSpoof.value
            let originalRules = rules.mapRemote
            defer {
                config.dnsSpoof.set(originalDNS)
                config.h2cUpstream.set(H2CUpstreamConfig())
                rules.mapRemote = originalRules
            }
            config.dnsSpoof.set(originalDNS + [DNSSpoofRule(hostPattern: "*.pool.pm.test", ip: "127.0.0.1")])
            config.h2cUpstream.set(H2CUpstreamConfig(enabled: true, hosts: ["*.pool.pm.test"]))
            let names = (0..<40).map { String(format: "pool-%02d", $0) }
            rules.mapRemote += names.map { name in
                ProxyRule(pattern: "https://allowed.pm.test:\(first)/\(name)",
                          target: "http://\(name).pool.pm.test:\(port)")
            }
            let offset = sink.records.count
            let acrossOrigins = try runClient("pool")
            check(names.allSatisfy { acrossOrigins[$0]?.text == "/\($0)" },
                  "HTTP/2 pool: all 40 origins complete")
            let downstreamPeers = Set(sink.records.dropFirst(offset).filter {
                $0.path.hasPrefix("/pool-")
            }.map(\.peerPort))
            eq(downstreamPeers.count, 1, "HTTP/2 pool: all 40 origins share one downstream connection")
            let oldest = acrossOrigins["pool-00"]?.connection
            let newest = acrossOrigins["pool-39"]?.connection
            check(oldest?.isEmpty == false && acrossOrigins["oldest-again"]?.connection.isEmpty == false
                  && acrossOrigins["oldest-again"]?.connection != oldest,
                  "HTTP/2 pool: opening more than 32 origins evicts the oldest idle parent")
            check(newest?.isEmpty == false && acrossOrigins["newest-again"]?.connection == newest,
                  "HTTP/2 pool: recently used parent remains reusable")
        }
        try runPACCoalescingTests(engine: engine, support: support)

        try MainActor.assumeIsolated {
            let config = InterceptionConfig.shared
            let manager = BreakpointManager.shared
            let oldEnabled = manager.enabled
            let oldBreakpoints = config.breakpoints.value
            let oldScripts = config.rewrite.value
            manager.enabled = true
            defer {
                manager.discardAll()
                manager.enabled = oldEnabled
                config.breakpoints.set(oldBreakpoints)
                config.rewrite.set(oldScripts)
            }
            let intercepted = URLRule(name: "H2 编辑", host: "allowed.pm.test", path: "/intercept-request", includeSubpaths: false)
            let canceled = URLRule(name: "H2 取消", host: "allowed.pm.test", path: "/intercept-drop", includeSubpaths: false)
            let graphql = URLRule(name: "H2 GraphQL", host: "allowed.pm.test", path: "/intercept-graphql",
                                  includeSubpaths: false, graphqlQueryName: "FindUser")
            config.breakpoints.set([
                BreakpointRule(rule: intercepted, phase: .request),
                BreakpointRule(rule: intercepted, phase: .response),
                BreakpointRule(rule: canceled, phase: .request),
            ])
            config.rewrite.set([RewriteRuleSet(rules: [
                RewriteRule(rule: intercepted, actions: [.script(phase: .response,
                    source: #"message.headers.push({name:"X-Rule-Result", value:"ran"});"#)]),
                RewriteRule(rule: graphql, actions: [.script(phase: .response,
                    source: #"message.status = 203; message.body = message.graphqlOperationName + " matched";"#)]),
            ])])

            var siblingCompletedWhileHeld = false
            var editingError: String?
            let result = try runClient("intercept") {
                let items = manager.held
                if items.contains(where: { $0.summary.hasSuffix("/intercept-request") && $0.phase == .request }),
                   items.contains(where: { $0.summary.hasSuffix("/intercept-drop") }),
                   sink.records.contains(where: { $0.path == "/intercept-sibling" && $0.state == .completed }) {
                    siblingCompletedWhileHeld = true
                }
                for item in items {
                    if item.phase == .request && !siblingCompletedWhileHeld { continue }
                    do {
                        if item.summary.hasSuffix("/intercept-drop") {
                            manager.drop(item)
                        } else if item.phase == .request {
                            let draft = item.message.text.replacingOccurrences(of: "\n\nbefore", with: "\nX-Manual: h2\n\nafter")
                            try manager.applyAndExecute(item, draft: draft)
                        } else {
                            let draft = item.message.text.replacingOccurrences(of: "HTTP/2 200 ", with: "HTTP/2 202 Accepted")
                            try manager.applyAndExecute(item, draft: draft)
                        }
                    } catch {
                        editingError = error.localizedDescription
                        manager.drop(item)
                    }
                }
            }
            if let editingError { print("HTTP/2 breakpoint fixture: \(editingError)") }
            check(editingError == nil && siblingCompletedWhileHeld, "HTTP/2: sibling completes while two streams are paused")
            let changed = result["intercept-request"]
            eq(changed?.text, "h2:after", "HTTP/2: request breakpoint edits header and bounded text")
            eq(changed?.status, 202, "HTTP/2: response breakpoint edits status")
            eq(changed?.ruleResult, "ran", "HTTP/2: response script runs after breakpoint")
            eq(changed?.sentTrailer, "preserved", "HTTP/2: request trailer survives breakpoint")
            eq(changed?.trailer, "still-here", "HTTP/2: response trailer survives breakpoint")
            let dropped = sink.records.first { $0.path == "/intercept-drop" }
            check(result["intercept-drop"]?.status == 502 && dropped?.state == .failed && dropped?.tConnected == nil,
                  "HTTP/2: canceling a breakpoint leaves other streams intact and skips origin")
            check(result["graphql"]?.status == 203 && result["graphql"]?.text == "FindUser matched",
                  "HTTP/2: GraphQL operation routes to a response script and rewrites bounded body")
            check(manager.held.isEmpty, "HTTP/2: completed and canceled holds leave the queue")
        }

        TLSKeyLog.shared.stop()
        let keyBytes = try Data(contentsOf: keyLog)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyLog.path)
        check(!keyBytes.isEmpty && attributes[.posixPermissions] as? Int == 0o600, "TLS key log: real handshake and owner-only file")

        engine.http2Enabled = false
        let h1 = try runClient("h1")
        eq(h1["h1"]?.protocol, "HTTP/1.1", "HTTP/2: disabling negotiation preserves HTTP/1.1 client compatibility")
        try checkGRPCWeb(h1, version: "HTTP/1.1")
        check(try Data(contentsOf: keyLog) == keyBytes, "TLS key log: stop prevents subsequent writes")
    } catch {
        check(false, "HTTP/2 loopback: \(error)")
    }
}

private func runPACCoalescingTests(engine: ProxyEngine, support: String) throws {
    let script = URL(fileURLWithPath: support).appendingPathComponent("coalescing.pac")
    let contents = """
        function FindProxyForURL(url, host) {
            return host === "fixture.pm.test" ? "PROXY 127.0.0.1:8123" : "DIRECT";
        }
        """
    try Data(contents.utf8).write(to: script)
    let config = ExternalProxyConfig(enabled: true, mode: .pac, pacURL: script.absoluteString)
    let loop = engine.group.next()
    let selected = URL(string: "http://fixture.pm.test/selected")!
    let direct = URL(string: "http://different.pm.test/direct")!
    let results = try loop.flatSubmit {
        let sameURL = (0..<48).map { _ in config.resolve(for: selected, on: loop) }
        return EventLoopFuture.whenAllSucceed(sameURL + [config.resolve(for: direct, on: loop)], on: loop)
    }.wait()
    check(results.dropLast().allSatisfy { $0?.port == 8123 }, "PAC: concurrent lookups of the same complete URL share resolution")
    check(results.last == .some(nil), "PAC: a different target is resolved independently")
}
