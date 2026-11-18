import Foundation
import NIOCore

/// WebSocket 帧脚本改写动作
enum WSFrameAction: Sendable, Equatable {
    case pass
    case drop
    case close
    case modify(payload: Data, note: String)
}

/// RFC 6455 帧编码（客户端方向按规范重新掩码；服务端方向不掩码）
enum WSFrameCodec {
    static func encode(opcode: UInt8, fin: Bool, payload: Data, mask: Bool, compressed: Bool = false) -> Data {
        var out: [UInt8] = [(fin ? 0x80 : 0) | (compressed ? 0x40 : 0) | (opcode & 0x0F)]
        let length = payload.count
        let maskBit: UInt8 = mask ? 0x80 : 0
        if length < 126 {
            out.append(maskBit | UInt8(length))
        } else if length <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((UInt64(length) >> UInt8(shift)) & 0xFF))
            }
        }
        if mask {
            var key = [UInt8](repeating: 0, count: 4)
            for index in 0..<4 { key[index] = UInt8.random(in: 0...255) }
            out.append(contentsOf: key)
            out.append(contentsOf: payload.enumerated().map { index, byte in byte ^ key[index & 3] })
        } else {
            out.append(contentsOf: [UInt8](payload))
        }
        return Data(out)
    }
}

/// WebSocket 双向脚本拦截管道（G6）。
/// 同方向内严格保序，等待脚本期间的原始字节队列上限为 1 MiB。
/// 命中改写时以单帧 FIN 形式重发（分片已按 RFC 重组），客户端→服务器方向重新掩码。
final class WSRelayInterceptor: @unchecked Sendable {
    private let direction: WSFrame.Direction
    private let maskOutgoing: Bool
    /// 决策回调投递回本方向事件循环
    private let loop: EventLoop
    private let emit: @Sendable (Data, WSFrame.Direction) -> Void
    private let close: @Sendable () -> Void
    private let issue: @Sendable (String) -> Void
    private let decoder: WebSocketDeflate.Decoder?
    private let encoder: WebSocketDeflate.Encoder?
    private let script: (@Sendable (WSFrame, @escaping @Sendable (WSFrameAction) -> Void) -> Void)?

    private var parser = WSFrameParser()
    private var backlog: [Data] = []
    private var backlogBytes = 0
    private var queue: [WSFrame] = []
    private var decisionID: UUID?
    private var decisionTimeout: Scheduled<Void>?
    private var stopped = false

    private static let maxPendingBytes = 1024 * 1024

    init(direction: WSFrame.Direction, maskOutgoing: Bool, loop: EventLoop,
         emit: @escaping @Sendable (Data, WSFrame.Direction) -> Void,
         close: @escaping @Sendable () -> Void = {},
         deflate: WebSocketDeflate? = nil,
         issue: @escaping @Sendable (String) -> Void = { _ in },
         script: (@Sendable (WSFrame, @escaping @Sendable (WSFrameAction) -> Void) -> Void)?) {
        self.direction = direction
        self.maskOutgoing = maskOutgoing
        self.loop = loop
        self.emit = emit
        self.close = close
        self.issue = issue
        decoder = deflate.map(WebSocketDeflate.Decoder.init)
        encoder = deflate.map(WebSocketDeflate.Encoder.init)
        self.script = script
    }

    /// 引擎事件循环调用；测试在单线程上串行调用同样安全
    func feed(_ data: Data) {
        guard !stopped else { return }
        guard script != nil else { emit(data, direction); return }
        guard data.count <= Self.maxPendingBytes - backlogBytes - parser.pendingBytes else {
            stop()
            return
        }
        backlog.append(data)
        backlogBytes += data.count
        drain()
    }

    private func drain() {
        guard !stopped, decisionID == nil, let script else { return }
        while true {
            if !queue.isEmpty {
                var frame = queue.removeFirst()
                if frame.rsv1 == true {
                    // Always advance the incoming dictionary, including messages later dropped.
                    guard let decoded = decoder?.preview(frame.payload, retaining: 8 * 1024 * 1024), !decoded.truncated else {
                        issue("WebSocket 压缩消息无法解码或超过 8 MiB，已关闭连接")
                        stop()
                        return
                    }
                    frame = WSFrame(direction: frame.direction, opcode: frame.opcode, fin: frame.fin,
                                    masked: frame.masked, payload: decoded.data, rsv1: true)
                }
                let message = frame
                let id = UUID()
                decisionID = id
                decisionTimeout = loop.scheduleTask(in: .milliseconds(400)) { [weak self] in
                    self?.apply(.pass, to: message, id: id)
                }
                script(message) { [weak self] action in
                    guard let self else { return }
                    self.loop.execute { self.apply(action, to: message, id: id) }
                }
                return
            }
            guard !backlog.isEmpty else { return }
            let chunk = backlog.removeFirst()
            backlogBytes -= chunk.count
            queue = parser.feed(chunk, direction: direction)
        }
    }

    private func apply(_ action: WSFrameAction, to frame: WSFrame, id: UUID) {
        guard decisionID == id, !stopped else { return }
        decisionID = nil
        decisionTimeout?.cancel()
        decisionTimeout = nil
        let control = (0x8...0xA).contains(frame.opcode)
        switch action {
        case .pass:
            write(frame)
        case .drop:
            break
        case .close:
            if control { write(frame) } else { stop(); return }
        case .modify(let payload, _):
            if control {
                write(frame)
            } else {
                let modified = WSFrame(direction: direction, opcode: frame.opcode, fin: frame.fin,
                                       masked: false, payload: payload, rsv1: frame.rsv1)
                write(modified)
            }
        }
        drain()
    }

    private func stop() {
        stopped = true
        decisionID = nil
        decisionTimeout?.cancel()
        decisionTimeout = nil
        backlog.removeAll()
        backlogBytes = 0
        queue.removeAll()
        close()
    }

    private func write(_ frame: WSFrame) {
        let payload: Data
        if frame.rsv1 == true {
            guard let compressed = encoder?.encode(frame.payload) else {
                issue("WebSocket 压缩消息无法重新编码，已关闭连接")
                stop()
                return
            }
            payload = compressed
        } else { payload = frame.payload }
        emit(WSFrameCodec.encode(opcode: frame.opcode, fin: frame.fin, payload: payload,
                                 mask: maskOutgoing, compressed: frame.rsv1 == true), direction)
    }
}
