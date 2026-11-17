import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os
@testable import ProxyMirrorCore

@MainActor
func runConcurrencyTests() {
    do {
        let files = FileManager.default
        guard let path = ProcessInfo.processInfo.environment["PM_SUPPORT_DIR"], path.hasPrefix("/"),
              !files.fileExists(atPath: path) || (try? files.contentsOfDirectory(atPath: path).isEmpty) == true else {
            throw ConcurrencyFailure("需要独立、空白的 PM_SUPPORT_DIR")
        }
        let support = URL(fileURLWithPath: path, isDirectory: true)
        try files.createDirectory(at: support, withIntermediateDirectories: true)
        try exerciseRuleSnapshots()
        try exerciseAttributionCache()
        try exerciseCertificateCache()
        try exerciseConcurrentTraffic(support: support)
    } catch {
        check(false, "并发测试 \(error)")
    }
}

private struct ConcurrencyFailure: LocalizedError {
    let errorDescription: String?

    init(_ description: String) { errorDescription = description }
}

@MainActor
private func waitFor(_ description: String, timeout: TimeInterval = 30, until ready: () -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !ready() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw ConcurrencyFailure("等待\(description)超时")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func exerciseRuleSnapshots() throws {
    let rules = RulesStore.shared
    let initial = rules.mapRemote
    defer { rules.mapRemote = initial }
    let first = (1...4).map { ProxyRule(pattern: "http://127.0.0.1/\($0)", target: "http://127.0.0.1:9001") }
    let second = (1...4).map { ProxyRule(pattern: "http://127.0.0.1/\($0)", target: "http://127.0.0.1:9002") }
    rules.mapRemote = first
    let mixedSnapshot = LockedBox(false)
    let start = DispatchSemaphore(value: 0)
    let readers = DispatchGroup()
    for _ in 0..<4 {
        DispatchQueue.global().async(group: readers) {
            start.wait()
            for _ in 0..<1_024 {
                let snapshot = rules.snapshot().mapRemote
                if snapshot != first && snapshot != second { mixedSnapshot.set(true) }
            }
        }
    }
    for _ in 0..<4 { start.signal() }
    for index in 0..<512 { rules.mapRemote = index.isMultiple(of: 2) ? second : first }
    try waitFor("规则快照读取") { readers.wait(timeout: .now()) == .success }
    check(!mixedSnapshot.value, "并发: 规则读者只看到完整快照")
}

@MainActor
private func exerciseAttributionCache() throws {
    let samples = Dictionary(uniqueKeysWithValues: (0..<4).map { index in
        (UInt16(11_000 + index), ProcessAppInfo(pid: -10 - index, name: "Fixture \(index)", bundleID: nil, bundleURL: nil))
    })
    let ports = samples.keys.sorted()
    let cache = ProcessAttribution(snapshot: { samples })
    let invalid = LockedBox(false)
    let queries = DispatchGroup()
    for index in 0..<128 {
        queries.enter()
        DispatchQueue.global().async {
            let port = ports[index % ports.count]
            if index.isMultiple(of: 8) { cache.clearCache() }
            if let cached = cache.lookup(port), cached != samples[port] { invalid.set(true) }
            cache.attribute(peerPort: port) { result in
                if result != samples[port] { invalid.set(true) }
                queries.leave()
            }
        }
    }
    try waitFor("归因查询回调") { queries.wait(timeout: .now()) == .success }
    check(!invalid.value, "并发: 归因缓存清理与查询同时进行时返回预期进程")
}

@MainActor
private func exerciseCertificateCache() throws {
    let ca = CertificateAuthority.shared
    let invalid = LockedBox(false)
    let certificates = OSAllocatedUnfairLock(initialState: Set<Data>())
    let requests = DispatchGroup()
    for index in 0..<16 {
        DispatchQueue.global().async(group: requests) {
            let host = index.isMultiple(of: 2) ? "same.pm.test" : "host-\(index).pm.test"
            guard let data = try? ca.caDER(),
                  ca.leafContext(forHost: host, enableHTTP2: index.isMultiple(of: 3)) != nil else {
                invalid.set(true)
                return
            }
            _ = certificates.withLock { $0.insert(data) }
        }
    }
    try waitFor("证书签发") { requests.wait(timeout: .now()) == .success }
    check(!invalid.value && certificates.withLock { $0.count } == 1,
          "并发: 同域与异域叶证书均由同一测试 CA 签发")
}

private final class ConcurrentTrafficSink: TrafficSink {
    let store: TrafficStore

    @MainActor
    init(support: URL) {
        store = TrafficStore(sourceFolderFile: support.appendingPathComponent("folders.json"))
    }

    func transactionCreated(_ tx: Transaction) {
        DispatchQueue.main.async { [store] in store.add(tx) }
    }

    func transactionUpdated(_ tx: Transaction) {
        DispatchQueue.main.async { [store] in store.update(tx) }
    }
}

private final class HeldResponseOrigin: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let release: EventLoopFuture<Void>
    private let arrivals: OSAllocatedUnfairLock<Int>
    private var path = ""

    init(release: EventLoopFuture<Void>, arrivals: OSAllocatedUnfairLock<Int>) {
        self.release = release
        self.arrivals = arrivals
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            path = head.uri
        case .body:
            break
        case .end:
            if path.hasPrefix("/held/") {
                arrivals.withLock { $0 += 1 }
                release.hop(to: context.eventLoop).whenSuccess { self.respond(context: context) }
            } else {
                respond(context: context)
            }
        }
    }

    private func respond(context: ChannelHandlerContext) {
        let bytes = ByteBuffer(string: path + "\n")
        let headers = NIOHTTP1.HTTPHeaders([
            ("Connection", "close"), ("Content-Length", String(bytes.readableBytes))
        ])
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let written = context.eventLoop.makePromise(of: Void.self)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(bytes))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: written)
        written.futureResult.whenComplete { _ in context.close(promise: nil) }
    }
}

private final class ConcurrentCurl {
    let process = Process()
    let output = Pipe()
    let expected: String

    init(proxyPort: UInt16, origin: String, paths: [String], prefix: String) throws {
        expected = paths.map { prefix + $0 + "\n" }.joined()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-q", "-fsS", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)",
                             "--max-time", "20"] + paths.map { origin + $0 }
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    deinit {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

@MainActor
private func assertClients(_ clients: [ConcurrentCurl], phase: String) throws {
    try waitFor(phase) { clients.allSatisfy { !$0.process.isRunning } }
    let errors = clients.enumerated().compactMap { index, client -> String? in
        let body = String(decoding: client.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard client.process.terminationStatus != 0 || body != client.expected else { return nil }
        return "客户端 \(index) 退出码 \(client.process.terminationStatus) 内容 \(body.prefix(160))"
    }
    check(errors.isEmpty, "并发: \(phase)正确转发 \(errors.prefix(2).joined(separator: " / "))")
}

@MainActor
private func exerciseConcurrentTraffic(support: URL) throws {
    let engine = ProxyEngine()
    defer { try? engine.group.syncShutdownGracefully() }
    let release = engine.group.next().makePromise(of: Void.self)
    let arrivals = OSAllocatedUnfairLock(initialState: 0)
    let origin = try ServerBootstrap(group: engine.group)
        .serverChannelOption(ChannelOptions.backlog, value: 64)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let pipeline = channel.pipeline.syncOperations
                try pipeline.configureHTTPServerPipeline()
                try pipeline.addHandler(HeldResponseOrigin(release: release.futureResult, arrivals: arrivals))
            }
        }
        .bind(host: "127.0.0.1", port: 0).wait()
    defer { try? origin.close().wait() }
    var released = false
    defer { if !released { release.succeed(()) } }
    guard let originPort = origin.localAddress?.port else { throw ConcurrencyFailure("无法取得源站端口") }
    let base = "http://127.0.0.1:\(originPort)"
    let sink = ConcurrentTrafficSink(support: support)
    let rules = RulesStore.shared
    let initial = rules.mapRemote
    engine.sink = sink
    defer {
        engine.stop()
        rules.mapRemote = initial
    }
    try engine.start(port: 0)
    let clientCount = 16
    let held = try (0..<clientCount).map {
        try ConcurrentCurl(proxyPort: engine.port, origin: base, paths: ["/held/\($0)"], prefix: "")
    }
    try waitFor("在途流量到达源站和流量仓库") {
        arrivals.withLock { $0 } == clientCount && sink.store.transactions.count == clientCount
    }

    engine.recordingEnabled = false
    rules.mapRemote = [ProxyRule(pattern: base + "/traffic/*", target: base + "/mapped")]
    let snapshot = sink.store.session(onlySelection: false, pinned: ["127.0.0.1"])
    let archive = support.appendingPathComponent("inflight.proxymirror")
    let archiveWrite = LockedBox<Result<Void, Error>?>(nil)
    SessionFile.fileQueue.async { archiveWrite.set(Result { try snapshot.write(to: archive) }) }

    let paused = try (0..<clientCount).map {
        try ConcurrentCurl(proxyPort: engine.port, origin: base, paths: ["/traffic/\($0)/0"], prefix: "/mapped")
    }
    try assertClients(paused, phase: "暂停录制并改写规则期间")
    eq(sink.store.transactions.count, clientCount, "并发: 暂停录制时新请求不写入流量列表")

    release.succeed(())
    released = true
    try assertClients(held, phase: "原规则下的在途请求")
    engine.recordingEnabled = true
    let resumed = try (0..<clientCount).map { index in
        let paths = (1...18).map { "/traffic/\(index)/\($0)" }
        return try ConcurrentCurl(proxyPort: engine.port, origin: base, paths: paths, prefix: "/mapped")
    }
    try assertClients(resumed, phase: "恢复录制后的 288 条请求")
    let recorded = clientCount * 19
    try waitFor("所有已录制请求完成") {
        sink.store.transactions.count == recorded && sink.store.transactions.allSatisfy { $0.state == .completed }
    }
    let live = sink.store.transactions
    let expectedPaths = Set((0..<clientCount).flatMap { index in
        ["/held/\(index)"] + (1...18).map { "/mapped/traffic/\(index)/\($0)" }
    })
    check(Set(live.map(\.path)) == expectedPaths && live.allSatisfy {
        $0.responseBodyComplete && $0.responseBody == Data(($0.path + "\n").utf8)
    }, "并发: 恢复录制后的捕获无串流、重复或正文丢失")

    try waitFor("会话写盘") { archiveWrite.value != nil }
    try archiveWrite.value?.get()
    let restored = try SessionFile.decode(Data(contentsOf: archive))
    let heldLive = live.filter { $0.path.hasPrefix("/held/") }
    check(restored.records.count == clientCount && restored.records.map(\.id) == heldLive.map(\.id)
          && restored.selected == snapshot.selected && restored.pinnedDomains == snapshot.pinnedDomains
          && restored.records.allSatisfy { $0.responseBody.isEmpty && !$0.responseBodyComplete && $0.state != .completed },
          "并发: 回读会话保留保存时的在途状态、请求 ID 和选中项")
}
