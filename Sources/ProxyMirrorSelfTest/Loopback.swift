import Foundation
import Combine
import NIOPosix
@testable import ProxyMirrorCore

private final class LoopbackSink: TrafficSink {
    var records: [Transaction] = []
    private var metadataSubscriptions: [AnyCancellable] = []
    func transactionCreated(_ tx: Transaction) {
        precondition(Thread.isMainThread, "Capture publication must run on the main thread")
        records.append(tx)
        metadataSubscriptions.append(tx.objectWillChange.sink { _ in
            precondition(Thread.isMainThread, "Published HTTP/WS/SSE metadata changed off the main thread")
        })
    }
    func transactionUpdated(_ tx: Transaction) { precondition(Thread.isMainThread) }
}

func runLoopbackTests() {
    let env = ProcessInfo.processInfo.environment
    guard let portA = env["PM_FIXTURE_A"].flatMap(UInt16.init),
          let portB = env["PM_FIXTURE_B"].flatMap(UInt16.init),
          let support = env["PM_SUPPORT_DIR"], support.hasPrefix("/"),
          !FileManager.default.fileExists(atPath: RulesStore.rulesPath.path) else {
        check(false, "loopback: 需要两个测试服务端口和空白的 PM_SUPPORT_DIR")
        return
    }
    let engine = ProxyEngine.shared
    let sink = LoopbackSink()
    let rules = RulesStore.shared
    engine.sink = sink
    engine.captureLimit = 4096
    let source = "http://127.0.0.1:\(portA)"
    defer { engine.stop() }

    do {
        try engine.start(port: 0)
        let proxy = "http://127.0.0.1:\(engine.port)"
        func curl(_ path: String, _ options: [String] = [], base: String? = nil) throws -> (Int32, String) {
            let process = Process()
            let out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-q", "-sS", "--noproxy", "", "--proxy", proxy, "--max-time", "5"]
                + options + [(base ?? source) + path]
            process.standardOutput = out
            process.standardError = out
            try process.run()
            while process.isRunning { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        let result = try curl("/missing?id=a&id=b", ["-H", "Content-Type: text/plain", "--data-binary", "one\r\ntwo"])
        eq(result.0, 0, "loopback: 固定长度 POST")
        eq(sink.records.last?.statusText, "404 Not Found", "loopback: 原始状态原因")
        eq(sink.records.last?.requestBody, Data("one\r\ntwo".utf8), "loopback: 固定长度请求正文")
        eq(sink.records.last?.responseHeaders.values(of: "Set-Cookie"), ["sample=a", "sample=b"], "loopback: 重复头")

        let chunk = try curl("/chunk", ["-H", "Transfer-Encoding: chunked", "--data-binary", "chunked-body"])
        eq(chunk.0, 0, "loopback: chunked POST")
        eq(sink.records.last?.requestBody, Data("chunked-body".utf8), "loopback: 分块请求正文")
        eq(sink.records.last?.responseTrailers.value(of: "X-End"), "fixture", "loopback: 分块响应 trailer")
        eq(sink.records.last?.responseBody, Data(chunk.1.utf8), "loopback: 分块响应已解帧")

        let plain = Data(#"{"capture":"content-coding"}"#.utf8)
        for coding in ["gzip", "deflate", "br"] {
            let compressed = try curl("/coding/\(coding)")
            eq(compressed.0, 0, "loopback: \(coding) 响应转发")
            if let record = sink.records.last,
               case .success(let decoded)? = ContentCoding.decodeIfCompressed(record.responseBody, encodings: [coding]) {
                eq(decoded.0, plain, "loopback: \(coding) 检查器还原正文")
                check(record.responseBody != plain, "loopback: \(coding) 保存原始压缩正文")
            } else {
                check(false, "loopback: \(coding) 检查器应可解码")
            }
        }

        let sse = try curl("/events")
        eq(sse.0, 0, "loopback: SSE 流式响应转发")
        let events = sink.records.last?.sseEvents ?? []
        eq(events.map(\.data), [#"{"n": 1}"#, "one\ntwo"], "loopback: SSE 按事件与多行数据解析")
        eq(events.map(\.id), ["42", "42"], "loopback: SSE 继承事件 ID")
        eq(events.last?.retry, 2500, "loopback: SSE 捕获重连间隔")
        if events.count == 2, let first = events[0].at, let last = events[1].at {
            check(last.timeIntervalSince(first) >= 0.05, "loopback: SSE 保留事件到达间隔")
        } else {
            check(false, "loopback: SSE 实时事件应保留到达时间")
        }
        eq(sink.records.last?.responseBody, Data(sse.1.utf8), "loopback: SSE 保留原始响应正文")

        let closeDelimited = try curl("/closing")
        eq(closeDelimited.1, "close-delimited", "loopback: 关闭连接定界的响应")
        eq(closeDelimited.0, 0, "loopback: 客户端收到 EOF")
        let informational = try curl("/informational")
        eq(informational.0, 0, "loopback: 103 后转发最终响应")
        eq(sink.records.last?.statusCode, 200, "loopback: 记录最终状态")

        try MainActor.assumeIsolated {
            try runReverseLoopbackTests(engine: engine, upstream: portA, occupied: portB) { sink.records.last }
        }

        rules.mapRemote = [ProxyRule(pattern: source + "/map*", target: "http://127.0.0.1:\(portB)/base?new=2")]
        let mapped = try curl("/map%2Fitem?old=1")
        let echo = try JSONSerialization.jsonObject(with: Data(mapped.1.utf8)) as? [String: Any]
        eq(echo?["server"] as? Int, Int(portB), "loopback: Map Remote 连到第二个服务")
        eq(echo?["host"] as? String, "127.0.0.1:\(portB)", "loopback: Map Remote 更新 Host")
        eq(echo?["path"] as? String, "/base/map%2Fitem?new=2", "loopback: Map Remote 更新路径和查询")
        eq(sink.records.last?.originalURL, source + "/map%2Fitem?old=1", "loopback: 原始 URL 保留")

        InterceptionConfig.shared.dnsSpoof.set([DNSSpoofRule(hostPattern: "origin.pm.test", ip: "127.0.0.1")])
        let dns = try curl("/dns", base: "http://origin.pm.test:\(portA)")
        let dnsEcho = try JSONSerialization.jsonObject(with: Data(dns.1.utf8)) as? [String: Any]
        eq(dnsEcho?["host"] as? String, "origin.pm.test:\(portA)", "loopback: DNS 映射保留原 Host")
        eq(sink.records.last?.resolvedAddress, "127.0.0.1", "loopback: DNS 映射记录连接地址")

        check(LatencyConditions.install(LatencyConditions(enabled: true, milliseconds: 175, host: "origin.pm.test")),
              "loopback: 保存主机网络延迟配置")
        let start = Date()
        _ = try curl("/latency", base: "http://origin.pm.test:\(portA)")
        check(Date().timeIntervalSince(start) >= 0.17 && sink.records.last?.simulatedLatencyMs == 175,
              "loopback: 命中主机延迟转发")
        _ = try curl("/no-latency")
        check(sink.records.last?.simulatedLatencyMs == nil, "loopback: 网络延迟不影响其他主机")
        _ = LatencyConditions.install(LatencyConditions())

        let pacedBody = String(repeating: "p", count: 8192)
        let uploadSettings = LatencyConditions(enabled: true, milliseconds: 0,
                                               host: "127.0.0.1", uploadKbps: 64)
        check(LatencyConditions.install(uploadSettings), "loopback: 保存上传限速设置")
        let uploadStart = Date()
        let pacedUpload = try curl("/paced-upload", ["--data-binary", pacedBody])
        check(pacedUpload.0 == 0 && pacedUpload.1.contains(pacedBody)
              && Date().timeIntervalSince(uploadStart) >= 1,
              "loopback: HTTP/1.1 上传限速且正文完整")

        let downloadSettings = LatencyConditions(enabled: true, milliseconds: 0,
                                                 host: "127.0.0.1", downloadKbps: 64)
        check(LatencyConditions.install(downloadSettings), "loopback: 保存下载限速设置")
        let downloadStart = Date()
        let pacedDownload = try curl("/paced-download", ["--data-binary", pacedBody, "-H", "Connection: close"])
        check(pacedDownload.0 == 0 && pacedDownload.1.contains(pacedBody)
              && Date().timeIntervalSince(downloadStart) >= 1,
              "loopback: HTTP/1.1 下载限速，连接关闭前发送完整正文")
        let volatile = LatencyConditions(enabled: true, milliseconds: 35, host: "origin.pm.test",
                                         jitterMilliseconds: 10, responseSpikePercent: 100, bodyPausePercent: 100)
        check(LatencyConditions.install(volatile), "loopback: 保存响应尖峰和正文暂停配置")
        let volatileStart = Date()
        let delayed = try curl("/body-pause", ["--data-binary", "ordered-body"], base: "http://origin.pm.test:\(portA)")
        let delayedRecord = sink.records.last
        check(delayed.0 == 0 && delayed.1.contains("ordered-body") && Date().timeIntervalSince(volatileStart) >= 0.60
              && (25...45).contains(delayedRecord?.simulatedLatencyMs ?? -1)
              && (delayedRecord?.duration ?? 0) >= 0.60,
              "loopback: HTTP/1.1 抖动、响应尖峰及双向正文暂停保留内容和耗时")

        let disconnect = LatencyConditions(enabled: true, milliseconds: 0, host: "origin.pm.test", disconnectPercent: 100)
        check(LatencyConditions.install(disconnect), "loopback: 保存随机断连配置")
        let reset = try curl("/simulated-reset", base: "http://origin.pm.test:\(portA)")
        let resetRecord = sink.records.last
        check(reset.0 == 56 && resetRecord?.state == .failed && resetRecord?.statusCode == 0
              && resetRecord?.errorText == LatencyConditions.disconnectReason,
              "loopback: HTTP/1.1 TCP 重置，无 HTTP 响应")
        let unaffected = try curl("/unmatched-reset")
        eq(unaffected.0, 0, "loopback: 随机断连仅影响匹配主机")
        _ = LatencyConditions.install(LatencyConditions())

        let local = URL(fileURLWithPath: support).appendingPathComponent("sample.txt")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local fixture".utf8).write(to: local, options: .atomic)
        rules.mapLocal = [ProxyRule(pattern: source + "/local", target: local.path)]
        let localResult = try curl("/local")
        eq(localResult.1, "local fixture", "loopback: Map Local 返回指定文件")
        check(sink.records.last?.matchedByMapLocal == true, "loopback: Map Local 记录命中")
        let localHead = try curl("/local", ["--head"])
        check(localHead.0 == 0 && localHead.1.localizedCaseInsensitiveContains("Content-Length: 13"),
              "loopback: Map Local HEAD 保留文件长度")
        check(sink.records.last?.method == "HEAD" && sink.records.last?.responseBytes == 0,
              "loopback: Map Local HEAD 不捕获正文")

        let directory = URL(fileURLWithPath: support).appendingPathComponent("mapped")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("directory fixture".utf8).write(to: directory.appendingPathComponent("directory"), options: .atomic)
        rules.mapLocal.append(ProxyRule(pattern: source + "/directory", target: directory.path, responseStatus: 418,
                                       responseHeaders: HTTPHeaders([("X-Fixture", "directory")])))
        let fromDirectory = try curl("/directory")
        eq(fromDirectory.1, "directory fixture", "loopback: Map Local 映射目录下的文件")
        eq(sink.records.last?.statusCode, 418, "loopback: Map Local 自定义状态码")
        eq(sink.records.last?.responseHeaders.value(of: "X-Fixture"), "directory", "loopback: Map Local 自定义响应头")

        let parsed = ComposeService.ParsedRequest(method: "GET", url: source + "/local", headers: [], body: nil)
        var replay: Transaction?
        _ = ComposeService.execute(parsed, runtime: ProxyRuntimeContext(engine: engine, settings: .shared),
                                   proxyPort: engine.port) { replay = $0 }
        let deadline = Date().addingTimeInterval(8)
        while replay == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        eq(replay?.responseBody, Data("local fixture".utf8), "loopback: Compose 经代理命中 Map Local")

        rules.blockList = [ProxyRule(pattern: source + "/blocked")]
        let blocked = try curl("/blocked")
        check(blocked.1.contains("blocked by Block List"), "loopback: Block 拒绝")
        eq(sink.records.last?.statusCode, 403, "loopback: Block 状态码")
        rules.allowList = [ProxyRule(pattern: source + "/permitted")]
        let denied = try curl("/excluded")
        check(denied.1.contains("not in Allow List"), "loopback: Allow 拒绝未命中")
        rules.allowList[0].enabled = false
        let allowed = try curl("/excluded")
        check(allowed.1.contains("/excluded"), "loopback: 禁用最后一条 Allow 后放行")

        let count = sink.records.count
        engine.recordingEnabled = false
        let paused = try curl("/paused")
        eq(paused.0, 0, "loopback: 暂停录制保留转发")
        eq(sink.records.count, count, "loopback: 暂停录制时不新增记录")
        engine.recordingEnabled = true
        _ = try curl("/resumed")
        eq(sink.records.count, count + 1, "loopback: 恢复录制产生新记录")

        try runBackpressureLoopbackTests(engine: engine)

        let upgradeHeaders = [
            "--http1.1", "-i", "-H", "Connection: Upgrade", "-H", "Upgrade: websocket",
            "-H", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "-H", "Sec-WebSocket-Version: 13",
        ]
        let upgraded = try curl("/ws", upgradeHeaders)
        check(upgraded.1.contains("101 Switching Protocols"), "loopback: WebSocket 101 握手")
        eq(sink.records.last?.websocketFrames.first?.fullText, "hi", "loopback: 与响应头同批到达的 WebSocket 帧")

        let compressed = try curl("/ws-compressed", upgradeHeaders + ["-H", "Sec-WebSocket-Extensions: permessage-deflate"])
        check(compressed.1.contains("Sec-WebSocket-Extensions: permessage-deflate"), "loopback: 转发 WebSocket 压缩协商")
        eq(sink.records.last?.websocketFrames.first?.fullText, "Hello", "loopback: 解压与握手同批到达的消息")
        eq(sink.records.last?.responseBody, Data([0xc1, 7, 0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0]),
           "loopback: 原文保留 WebSocket 压缩帧字节")

        if let refusedPort = env["PM_FIXTURE_REFUSED"] {
            let refused = try curl("/refused", ["--max-time", "24"], base: "http://127.0.0.1:\(refusedPort)")
            check(refused.1.contains("无法连接上游"), "loopback: 连接失败给客户端返回可读错误")
            eq(sink.records.last?.statusCode, 502, "loopback: 捕获合成的 502")
            eq(sink.records.last?.state, .failed, "loopback: 连接失败状态")
        }
        if env["PM_FIXTURE_TIMEOUT"] == "1" {
            let timeout = try curl("/timeout", ["--max-time", "35"])
            check(timeout.1.contains("等待上游响应超时"), "loopback: 上游超时返回错误")
            eq(sink.records.last?.statusCode, 504, "loopback: 捕获合成的 504")
            eq(sink.records.last?.state, .failed, "loopback: 上游超时状态")
        }

        let conflictingEngine = ProxyEngine()
        defer { try? conflictingEngine.group.syncShutdownGracefully() }
        do {
            try conflictingEngine.start(port: engine.port)
            conflictingEngine.stop()
            check(false, "loopback: 监听端口冲突")
        } catch {
            check(!conflictingEngine.isRunning && engine.isRunning, "loopback: 端口冲突后原监听可用")
        }

        if let tlsPort = env["PM_FIXTURE_TLS"], let tlsCA = env["PM_FIXTURE_CA"] {
            try UpstreamTrust.install(Data(contentsOf: URL(fileURLWithPath: tlsCA)))
            try CertificateAuthority.shared.ensureCA()
            InterceptionConfig.shared.dnsSpoof.set([
                DNSSpoofRule(hostPattern: "allowed.pm.test", ip: "127.0.0.1"),
                DNSSpoofRule(hostPattern: "adjacent.pm.test", ip: "127.0.0.1"),
            ])
            rules.sslProxyingList = [ProxyRule(pattern: "allowed.pm.test")]
            let mitm = try curl("/ssl", ["--cacert", CertificateAuthority.shared.caCertPath.path],
                               base: "https://allowed.pm.test:\(tlsPort)")
            eq(mitm.0, 0, "loopback: 证书验证开启时 MITM HTTPS 成功")
            eq(sink.records.last?.isTLSIntercepted, true, "loopback: 包含域解密")
            check(sink.records.last?.responseBody.isEmpty == false, "loopback: 包含域记录正文")
            let tunnel = try curl("/ssl", ["--cacert", tlsCA], base: "https://adjacent.pm.test:\(tlsPort)")
            eq(tunnel.0, 0, "loopback: 相邻域保持 TLS 透传")
            check(sink.records.last?.isTunnel == true && sink.records.last?.isTLSIntercepted == false,
                  "loopback: 透传域仅记录 CONNECT")

            if let peer = env["PM_FIXTURE_TRANSPARENT_PEER"], let python = env["PM_FIXTURE_PYTHON"] {
                try runTransparentIngressTests(engine: engine, sink: sink, peer: peer, python: python,
                                               httpPort: portA, tlsPort: tlsPort)
            }

            engine.mitmExcludedHosts = ["allowed.pm.test"]
            let excluded = try curl("/ssl", ["--cacert", tlsCA], base: "https://allowed.pm.test:\(tlsPort)")
            eq(excluded.0, 0, "loopback: 排除项优先于包含规则")
            check(sink.records.last?.isTunnel == true && sink.records.last?.isTLSIntercepted == false,
                  "loopback: 排除项正文仍加密")

            if let appA = env["PM_FIXTURE_SSL_APP_A"], let appB = env["PM_FIXTURE_SSL_APP_B"] {
                try runApplicationSSLTests(engine: engine, sink: sink, appA: appA, appB: appB, tlsPort: tlsPort, tlsCA: tlsCA)
            }
        }
        try MainActor.assumeIsolated {
            try runBreakpointLoopback(engine: engine, source: source) { sink.records }
            try runScriptingLoopback(engine: engine, source: source) { sink.records }
        }
    } catch {
        check(false, "loopback: \(error)")
    }
}

private func runApplicationSSLTests(engine: ProxyEngine, sink: LoopbackSink, appA: String, appB: String,
                                    tlsPort: String, tlsCA: String) throws {
    let rules = RulesStore.shared
    let initial = rules.backup()
    let excluded = engine.mitmExcludedHosts
    let enabled = engine.mitmEnabled
    defer {
        engine.mitmEnabled = enabled
        engine.mitmExcludedHosts = excluded
        do { try rules.install(initial) }
        catch { check(false, "loopback: 恢复应用 SSL 测试配置 \(error)") }
    }
    let bundleA = "test.proxymirror.ssla"
    let bundleB = "test.proxymirror.sslb"
    var configured = initial
    configured.sslApplications = [SSLApplicationRule(bundleID: bundleA),
                                  SSLApplicationRule(bundleID: bundleB, action: .passthrough)]
    try rules.install(configured)
    let persisted = try RuleBackup.read(Data(contentsOf: RulesStore.rulesPath)).0
    eq(persisted.sslApplications, configured.sslApplications, "loopback: 应用 SSL 规则保存到磁盘")
    eq(persisted.sslProxyingList, initial.sslProxyingList, "loopback: 域名规则随应用规则保存")
    engine.mitmExcludedHosts = []

    let url = "https://allowed.pm.test:\(tlsPort)/same-domain"
    let proxy = "http://127.0.0.1:\(engine.port)"
    let proxyCA = CertificateAuthority.shared.caCertPath.path
    func start(_ path: String, ca: String) throws -> (Process, Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [proxy, ca, url]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, output)
    }
    func result(_ client: (Process, Pipe)) -> (Int32, String) {
        while client.0.isRunning { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (client.0.terminationStatus, String(decoding: client.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    let offset = sink.records.count
    let clientA = try start(appA, ca: proxyCA)
    let clientB = try start(appB, ca: tlsCA)
    let (statusA, bodyA) = result(clientA)
    let (statusB, bodyB) = result(clientB)
    check(statusA == 0 && statusB == 0 && bodyA == bodyB && bodyA.contains("/same-domain"),
          "loopback: 两个应用访问同一域名，分别验证代理 CA 和服务端 CA (\(statusA), \(statusB))")
    let transactions = sink.records.dropFirst(offset)
    let a = transactions.filter { $0.clientBundle == bundleA }
    let b = transactions.filter { $0.clientBundle == bundleB }
    check(a.count == 2 && a.contains { !$0.isTunnel && $0.isTLSIntercepted && $0.responseBody == Data(bodyA.utf8) },
          "loopback: 应用 A 记录 CONNECT 和已解密的请求正文")
    check(b.count == 1 && b.first?.isTunnel == true && b.first?.isTLSIntercepted == false && b.first?.responseBody.isEmpty == true,
          "loopback: 应用 B 只记录 CONNECT，无明文响应")

    let bypassA = result(try start(appA, ca: tlsCA))
    let decryptB = result(try start(appB, ca: proxyCA))
    check(bypassA.0 != 0 && decryptB.0 != 0, "loopback: 两个应用交换 CA 后都无法完成证书验证")
    check(sink.records.last(where: { $0.clientBundle == bundleA && $0.isTunnel })?.suspectedPinning == true,
          "loopback: 证书校验失败后标记疑似锁定")

    rules.sslApplications[1].enabled = false
    check(result(try start(appB, ca: proxyCA)).0 == 0 && sink.records.last?.isTLSIntercepted == true,
          "loopback: 禁用应用 B 规则后沿用域名解密")
    check(sink.records.last(where: { $0.clientBundle == bundleB && $0.isTunnel })?.suspectedPinning == false,
          "loopback: 正常解密不标记疑似锁定")
    rules.sslProxyingList = [ProxyRule(pattern: "adjacent.pm.test")]
    check(result(try start(appA, ca: proxyCA)).0 == 0 && sink.records.last?.isTLSIntercepted == true,
          "loopback: 应用 A 的解密规则优先于域名列表")
    check(result(try start(appB, ca: tlsCA)).0 == 0 && sink.records.last?.isTLSIntercepted == false,
          "loopback: 无启用规则的应用 B 仍按域名规则透传")

    engine.mitmExcludedHosts = ["allowed.pm.test"]
    check(result(try start(appA, ca: tlsCA)).0 == 0 && sink.records.last?.isTLSIntercepted == false,
          "loopback: 排除域名优先于应用解密")
    engine.mitmExcludedHosts = []
    engine.mitmEnabled = false
    check(result(try start(appA, ca: tlsCA)).0 == 0 && sink.records.last?.isTLSIntercepted == false,
          "loopback: 关闭全局 SSL 后应用解密规则停用")
}

private func runTransparentIngressTests(engine: ProxyEngine, sink: LoopbackSink, peer: String, python: String,
                                        httpPort: UInt16, tlsPort: String) throws {
    let rules = RulesStore.shared
    let savedMapRemote = rules.mapRemote
    let savedDomains = rules.sslProxyingList
    let savedApplications = rules.sslApplications
    let enableHTTP2 = engine.http2Enabled
    defer {
        engine.stopTransparentIngress()
        engine.http2Enabled = enableHTTP2
        rules.mapRemote = savedMapRemote
        rules.sslProxyingList = savedDomains
        rules.sslApplications = savedApplications
    }

    rules.mapRemote = [
        ProxyRule(pattern: "http://transparent.pm.test/transparent-http",
                  target: "http://127.0.0.1:\(httpPort)"),
        ProxyRule(pattern: "https://allowed.pm.test/transparent-tls",
                  target: "https://allowed.pm.test:\(tlsPort)"),
        ProxyRule(pattern: "https://allowed.pm.test/transparent-h2",
                  target: "https://allowed.pm.test:\(tlsPort)"),
    ]
    // Only the extension's source signing ID authorizes decryption in these two TLS cases.
    rules.sslProxyingList = [ProxyRule(pattern: "elsewhere.pm.test")]
    rules.sslApplications = [SSLApplicationRule(bundleID: "com.sebastianLavertheDe.proxymirror.fixture")]
    engine.http2Enabled = true
    let ingress = try engine.startTransparentIngress()
    check(ingress.port != engine.port, "透明抓包：独立回环监听")

    for (mode, version) in [("http", "HTTP/1.1"), ("tls", "HTTP/1.1"), ("h2", "HTTP/2")] {
        let runner = Process()
        let output = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["PM_TRANSPARENT_TEST_TOKEN"] = ingress.token
        runner.environment = env
        runner.executableURL = URL(fileURLWithPath: python)
        runner.arguments = [peer, String(ingress.port), mode, CertificateAuthority.shared.caCertPath.path]
        runner.standardOutput = output
        runner.standardError = output
        try runner.run()
        while runner.isRunning { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let details = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check(runner.terminationStatus == 0, "透明抓包：\(mode) 流量及握手 \(details)")
        let tx = sink.records.last
        check(tx?.isTransparent == true && tx?.clientBundle == "com.sebastianLavertheDe.proxymirror.fixture"
              && tx?.requestVersion == version && tx?.isTLSIntercepted == (mode != "http")
              && tx?.statusCode == 200,
              "透明抓包：\(mode) 记录入口、应用、协议与状态")
        if let tx {
            let archive = SessionFile(transactions: [tx], pinnedDomains: [], selected: [])
            let restored = try SessionFile.decode(JSONEncoder().encode(archive)).records.first?.transaction()
            check(restored?.isTransparent == true && restored?.clientBundle == tx.clientBundle,
                  "透明抓包：\(mode) 会话保留入口与应用")
        }
    }

    engine.stopTransparentIngress()
    let bootstrap = ClientBootstrap(group: engine.group).connectTimeout(.seconds(2))
    let closed = try? bootstrap.connect(host: "127.0.0.1", port: Int(ingress.port)).wait()
    check(closed == nil, "透明抓包：停止后回收独立监听")
    try? closed?.close().wait()
    let explicit = try bootstrap.connect(host: "127.0.0.1", port: Int(engine.port)).wait()
    try explicit.close().wait()
    let restarted = try engine.startTransparentIngress()
    check(restarted.token != ingress.token, "透明抓包：重新启动时更新会话密钥")
}
