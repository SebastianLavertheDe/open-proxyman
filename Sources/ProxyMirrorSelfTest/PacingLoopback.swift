import Foundation
import NIOCore
import NIOPosix
@testable import ProxyMirrorCore

func runPacingLoopbackTests() {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let loop = group.next()
    let first = Array(repeating: UInt8(ascii: "a"), count: 16 * 1024)
    let second = Array(repeating: UInt8(ascii: "b"), count: 448 * 1024)
    let marker = Array("|ordered|".utf8)
    let expected = first + marker + second
    let received = loop.makePromise(of: [UInt8].self)
    let source = PacingLoopbackObserver()

    do {
        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(PacingLoopbackReceiver(expectedCount: expected.count, received: received))
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        guard let port = server.localAddress?.port else {
            check(false, "弱网回环：无法取得本地监听端口")
            return
        }
        let client = try ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }
        let start = DispatchTime.now().uptimeNanoseconds
        try loop.submit {
            let discarded = BytePacingQueue(loop: loop, onFailure: { _ in })
            discarded.write(ByteBuffer(string: "canceled"), kilobitsPerSecond: nil, pauseMs: 1000, send: { client.writeAndFlush($0) })
            discarded.cancel()
            discarded.afterWrites { source.barrierRanAfterCancel = true }

            let writer = BytePacingQueue(loop: loop, onBackpressure: { source.pressure.append($0) }, onFailure: {
                received.fail($0)
            })
            source.writer = writer
            writer.write(ByteBuffer(bytes: first), kilobitsPerSecond: 128, send: { client.writeAndFlush($0) })
            writer.afterWrites(pauseMs: 30) { client.writeAndFlush(ByteBuffer(bytes: marker), promise: nil) }
            writer.write(ByteBuffer(bytes: second), kilobitsPerSecond: 4096, pauseMs: 100, send: { client.writeAndFlush($0) })
        }.wait()
        let timeout = loop.scheduleTask(in: .seconds(8)) { received.fail(PacingLoopbackTimeout()) }
        defer { timeout.cancel() }
        let bytes = try received.futureResult.wait()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        check(bytes == expected, "弱网回环：两档限速与控制写入按原顺序到达")
        check(elapsed >= 2.02, "弱网回环：正文按指定速率传输并保留暂停")
        check(source.pressure == [true, false], "弱网回环：写队列在水位变化时暂停和恢复读取")
        check(!source.barrierRanAfterCancel, "弱网回环：取消移除已排队的写入和控制操作")

        let settings = LatencyConditions(enabled: true, milliseconds: 200, host: "*.pm.test",
                                         uploadKbps: 128, downloadKbps: 4096, jitterMilliseconds: 40,
                                         disconnectPercent: 20, responseSpikePercent: 75, bodyPausePercent: 100)
        let data = try RuleBackup(latency: settings).exportData()
        let (restored, unknown) = try RuleBackup.read(data)
        check(restored.latency == settings && unknown.isEmpty, "弱网回环：新增条件随规则备份往返")
        let firstRoll = settings.sample(for: "upload.pm.test", using: { $0.lowerBound })
        check(firstRoll.requestDelay == 160 && firstRoll.disconnect && firstRoll.responseDelay == 0,
              "弱网回环：抖动下界和断连概率命中")
        var outcomes = [240, 21, 75].makeIterator()
        let lastRoll = settings.sample(for: "upload.pm.test", using: { outcomes.next() ?? $0.upperBound })
        check(lastRoll.requestDelay == 240 && !lastRoll.disconnect && lastRoll.responseDelay == 500,
              "弱网回环：抖动上界和响应尖峰概率命中")
        check(lastRoll.bandwidth == LinkBandwidth(uploadKbps: 128, downloadKbps: 4096),
              "弱网回环：上行和下行速率持久化并按主机应用")
        check(lastRoll.bodyPause.sample(using: { $0.upperBound }) == 600,
              "弱网回环：正文暂停后按原延迟倍数恢复")
        var sampledUnmatchedHost = false
        let unmatched = settings.sample(for: "other.test", using: {
            sampledUnmatchedHost = true
            return $0.upperBound
        })
        check(unmatched == LatencySimulation() && !sampledUnmatchedHost, "弱网回环：未匹配主机直接放行")
        let legacy = Data(#"{"latency":{"enabled":true,"milliseconds":40,"host":""}}"#.utf8)
        let (legacyBackup, _) = try RuleBackup.read(legacy)
        let legacySettings = legacyBackup.latency?.sample(for: "localhost")
        check(legacySettings == LatencySimulation(requestDelay: 40),
              "弱网回环：旧版备份正常启用延迟，新条件默认关闭")
        let invalid = Data(#"{"latency":{"enabled":true,"milliseconds":40,"host":"","responseSpikePercent":101}}"#.utf8)
        check((try? RuleBackup.read(invalid)) == nil, "弱网回环：规则备份拒绝超范围概率")
        let preset = LatencyConditions.Preset.threeG.settings(for: "demo.test")
        check(preset.validationError == nil && preset.host == "demo.test" && preset.enabled,
              "弱网回环：3G 预设保留目标主机并使用有效配置")
    } catch {
        check(false, "弱网回环：\(error.localizedDescription)")
    }
}

private final class PacingLoopbackObserver: @unchecked Sendable {
    var writer: BytePacingQueue?
    var pressure: [Bool] = []
    var barrierRanAfterCancel = false
}

private final class PacingLoopbackReceiver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var bytes: [UInt8] = []
    private let expectedCount: Int
    private let received: EventLoopPromise<[UInt8]>

    init(expectedCount: Int, received: EventLoopPromise<[UInt8]>) {
        self.expectedCount = expectedCount
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard bytes.count < expectedCount else { return }
        bytes += unwrapInboundIn(data).readableBytesView
        if bytes.count >= expectedCount { received.succeed(bytes) }
    }
}

private struct PacingLoopbackTimeout: Error {}
