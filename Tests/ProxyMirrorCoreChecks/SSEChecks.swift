import Foundation
import NIOEmbedded
@testable import ProxyMirrorCore

/// G4：SSE 事件流解析与捕获挂接
func checkSSE(_ test: CoreAssertions) {
    var state = SSEStreamState()
    state.append(Data("event: add\ndata: {\"a\": 1,\ndata:  \"b\": 2}\nid: 42\nretry: 3000\n\n".utf8))
    test.equal(state.events.count, 1, "SSE: 单事件解析")
    let event = state.events.first
    test.equal(event?.event, "add", "SSE: event 字段")
    test.equal(event?.data, "{\"a\": 1,\n \"b\": 2}", "SSE: 多行 data 合并")
    test.equal(event?.id, "42", "SSE: id 字段")
    test.equal(event?.retry, 3000, "SSE: retry 字段")
    test.equal(event?.index, 0, "SSE: 序号")

    // 注释行忽略 + 默认 message + 无 data 不派发
    state = SSEStreamState()
    state.append(Data(": keep-alive\n\ndata: first\n\n\n:ping\n\n".utf8))
    test.equal(state.events.count, 1, "SSE: 注释与空行不产生事件")
    test.equal(state.events.first?.event, "message", "SSE: 默认事件名 message")

    // CRLF 与 chunk 断行
    state = SSEStreamState()
    let stream = "data: a\r\ndata: b\r\n\ndata: c\n\n"
    let bytes = Array(stream.utf8)
    state.append(Data(bytes.prefix(bytes.count / 2)))
    test.equal(state.events.count, 0, "SSE: 跨 chunk 半行不提前派发")
    state.append(Data(bytes.suffix(bytes.count - bytes.count / 2)))
    test.equal(state.events.map(\.data), ["a\nb", "c"], "SSE: CRLF 与断行续接")

    // EOF 丢弃未以空行终止的事件
    state = SSEStreamState()
    state.append(Data("data: tail".utf8))
    test.equal(state.events.count, 0, "SSE: EOF 前保持 pending")

    state = SSEStreamState()
    state.append(Data("\u{FEFF}retry: 50\nid: 7\n\nevent:\nid: invalid\0id\nretry: +25\ndata:\n\n".utf8))
    test.equal(state.events.first?.id, "7", "SSE: 忽略含 NUL 的 id")
    test.equal(state.events.first?.retry, 50, "SSE: BOM 与纯数字 retry")
    test.equal(state.events.first?.data, "", "SSE: 空 data 也会派发事件")
    test.equal(state.events.first?.event, "message", "SSE: 空事件名使用 message")

    // 事件数上限
    state = SSEStreamState()
    let flood = String(repeating: "data: x\n\n", count: SSEStreamState.maxEvents + 50)
    state.append(Data(flood.utf8))
    test.equal(state.events.count, SSEStreamState.maxEvents, "SSE: 事件数上限")
    test.expect(state.truncated, "SSE: 超限标记截断")

    // 捕获挂接：content-type event-stream 的下游字节自动进 tx.sseEvents（主线程同步）
    let loop = EmbeddedEventLoop()
    let transaction = Transaction()
    transaction.contentType = "text/event-stream"
    let capture = TransactionCapture(transaction: transaction, on: loop)
    capture.setResponseHeadersForSSE(HTTPHeaders([("content-type", "text/event-stream")]))
    capture.append(Data("data: hello\n\n".utf8), direction: .downstream)
    capture.flush()
    test.equal(transaction.sseEvents.count, 1, "SSE: 捕获管线挂接")
    test.equal(transaction.sseEvents.first?.data, "hello", "SSE: 捕获事件内容")
    test.expect(transaction.isSSE, "SSE: isSSE 由 content-type 判定")
}
