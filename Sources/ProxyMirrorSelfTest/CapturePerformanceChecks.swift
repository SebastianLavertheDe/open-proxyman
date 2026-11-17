import Combine
import Foundation
import NIOCore
import NIOPosix
@testable import ProxyMirrorCore

func runCapturePerformanceChecks() {
    do {
        let budget = CaptureBudget(limit: 5)
        var first: Transaction? = Transaction(captureBudget: budget)
        first?.appendResponseBody(Data("abcd".utf8))
        let second = Transaction(captureBudget: budget)
        second.appendResponseBody(Data("efg".utf8))
        eq(second.responseBody, Data("e".utf8), "抓包预算: 跨交易只保留可用前缀")
        check(second.responseTruncated && second.responseBytes == 3, "抓包预算: 截断仍保留完整字节计数")
        eq(first?.responseBody, Data("abcd".utf8), "抓包预算: 已留存正文不受后续记录影响")
        first = nil
        second.appendResponseBody(Data("hi".utf8))
        eq(second.responseBody, Data("e".utf8), "抓包预算: 截断后不跨过缺失区间捕获")
        let third = Transaction(captureBudget: budget)
        third.appendRequestBody(Data("jklo".utf8))
        eq(third.requestBody, Data("jklo".utf8), "抓包预算: 交易释放后归还额度")
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let loop = group.next()
    let tx = Transaction(captureBudget: CaptureBudget(limit: 16))
    tx.captureLimit = 4
    var notifications = 0
    let observation = tx.objectWillChange.sink { _ in notifications += 1 }
    let capture = TransactionCapture(transaction: tx, on: loop)
    do {
        try loop.submit {
            capture.append(ByteBuffer(string: "ab").readableBytesView, direction: .downstream)
            capture.append(ByteBuffer(string: "cdef").readableBytesView, direction: .downstream)
            capture.append(ByteBuffer(string: "ghi").readableBytesView, direction: .downstream)
            capture.flush()
        }.wait()
        let deadline = Date().addingTimeInterval(1)
        while tx.responseBytes == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        eq(tx.responseBody, Data("abcd".utf8), "抓包批次: 只复制前缀并保持顺序")
        eq(tx.responseBytes, 9, "抓包批次: 统计已超额度的数据")
        check(tx.responseTruncated, "抓包批次: UI 收到截断状态")
        eq(notifications, 1, "抓包批次: 三个正文块仅发布一次变更")
        eq(tx.responseBodyRevision, 1, "抓包批次: 一次正文版本更新")
    } catch {
        check(false, "抓包批次: \(error)")
    }
    observation.cancel()

    do {
        let buffer = ByteBuffer(string: "2\r\nab\r\n3\r\ncde\r\n0\r\nX-End: test\r\n\r\nNEXT")
        var tracker = ChunkedTracker()
        var payload = Data()
        let wireBytes = try tracker.consume(buffer.readableBytesView) { payload.append(contentsOf: $0) }
        eq(payload, Data("abcde".utf8), "Chunked 捕获: 从原始缓冲访问已解帧正文")
        eq(wireBytes, buffer.readableBytes - 4, "Chunked 捕获: 保持流水线边界")
        eq(tracker.trailers.value(of: "X-End"), "test", "Chunked 捕获: 保留 trailer")
    } catch {
        check(false, "Chunked 捕获: \(error)")
    }
}
