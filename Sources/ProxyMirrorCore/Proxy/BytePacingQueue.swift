import Foundation
import NIOCore

/// An event-loop confined writer. Writes preserve byte order across rate changes,
/// and barriers run after any previously paced write has completed.
final class BytePacingQueue {
    enum QueueError: LocalizedError {
        case capacityExceeded

        var errorDescription: String? { "弱网限速缓冲已满" }
    }

    private struct Pending {
        var bytes: ByteBuffer
        let rate: Int?
        let send: (ByteBuffer) -> EventLoopFuture<Void>
    }

    private enum Job {
        case bytes(Pending)
        case barrier(() -> Void)
        case pause(TimeAmount)
    }

    private let loop: EventLoop
    private let onBackpressure: (Bool) -> Void
    private let onFailure: (Error) -> Void
    private let lowWatermark = 128 * 1024
    private let highWatermark = 384 * 1024
    private let hardLimit = 4 * 1024 * 1024
    private let hardJobLimit = 1024

    private var jobs = CircularBuffer<Job>(initialCapacity: 16)
    private var current: Pending?
    private var scheduled: Scheduled<Void>?
    private var bufferedBytes = 0
    private var writing = false
    private var draining = false
    private var pressured = false
    private var stopped = false

    init(loop: EventLoop, onBackpressure: @escaping (Bool) -> Void = { _ in },
         onFailure: @escaping (Error) -> Void) {
        self.loop = loop
        self.onBackpressure = onBackpressure
        self.onFailure = onFailure
    }

    var hasPendingWrites: Bool { writing || current != nil || !jobs.isEmpty }
    var isBackpressured: Bool { pressured }

    func write(_ bytes: ByteBuffer, kilobitsPerSecond: Int?, pauseMs: Int = 0,
               send: @escaping (ByteBuffer) -> EventLoopFuture<Void>) {
        precondition(loop.inEventLoop)
        guard !stopped, bytes.readableBytes > 0 else { return }
        let rate = kilobitsPerSecond.flatMap { (1...1_000_000).contains($0) ? $0 : nil }
        if rate == nil && pauseMs == 0 && !hasPendingWrites && !draining {
            send(bytes).hop(to: loop).whenFailure { [weak self] error in self?.fail(error) }
            return
        }
        guard bytes.readableBytes <= hardLimit - bufferedBytes, hasRoom(pauseMs: pauseMs) else {
            fail(QueueError.capacityExceeded)
            return
        }
        bufferedBytes += bytes.readableBytes
        queuePause(pauseMs)
        jobs.append(.bytes(Pending(bytes: bytes, rate: rate, send: send)))
        notifyPressure()
        drain()
    }

    func afterWrites(pauseMs: Int = 0, _ action: @escaping () -> Void) {
        precondition(loop.inEventLoop)
        guard !stopped else { return }
        if pauseMs == 0 && !hasPendingWrites && !draining {
            action()
            return
        }
        guard hasRoom(pauseMs: pauseMs) else {
            fail(QueueError.capacityExceeded)
            return
        }
        queuePause(pauseMs)
        jobs.append(.barrier(action))
        drain()
    }

    private func hasRoom(pauseMs: Int) -> Bool {
        (pauseMs > 0 ? 2 : 1) <= hardJobLimit - jobs.count
    }

    private func queuePause(_ milliseconds: Int) {
        if milliseconds > 0 { jobs.append(.pause(.milliseconds(Int64(milliseconds)))) }
    }

    /// Cancels timers and queued writes. A write already accepted by the channel
    /// can complete, so the channel owner still decides when to close the transport.
    func cancel() {
        precondition(loop.inEventLoop)
        guard !stopped else { return }
        stopped = true
        scheduled?.cancel()
        scheduled = nil
        current = nil
        jobs.removeAll()
        writing = false
        bufferedBytes = 0
        notifyPressure()
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !writing, !stopped {
            if current == nil {
                guard let next = jobs.popFirst() else { return }
                switch next {
                case .bytes(let pending):
                    current = pending
                case .barrier(let action):
                    action()
                    continue
                case .pause(let delay):
                    writing = true
                    scheduled = loop.scheduleTask(in: delay) { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.scheduled = nil
                        self.writing = false
                        self.drain()
                    }
                    return
                }
            }

            guard var pending = current else { return }
            let chunkSize = pending.rate.map { max(16, min(16 * 1024, $0 * 2)) } ?? pending.bytes.readableBytes
            let count = min(chunkSize, pending.bytes.readableBytes)
            guard let bytes = pending.bytes.readSlice(length: count) else { return }
            current = pending.bytes.readableBytes > 0 ? pending : nil
            writing = true
            if let rate = pending.rate {
                // kbps uses decimal kilobits. Charge bytes before emitting so even
                // a response that fits in one chunk honors the configured rate.
                let ns = (Int64(count) * 8_000_000 + Int64(rate) - 1) / Int64(rate)
                let send = pending.send
                scheduled = loop.scheduleTask(in: .nanoseconds(ns)) { [weak self] in
                    self?.scheduled = nil
                    self?.emit(bytes, send: send)
                }
            } else {
                emit(bytes, send: pending.send)
            }
        }
    }

    private func emit(_ bytes: ByteBuffer, send: (ByteBuffer) -> EventLoopFuture<Void>) {
        guard !stopped else { return }
        send(bytes).hop(to: loop).whenComplete { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success:
                self.bufferedBytes -= bytes.readableBytes
                self.writing = false
                self.notifyPressure()
                self.drain()
            }
        }
    }

    private func notifyPressure() {
        if !pressured && bufferedBytes >= highWatermark {
            pressured = true
            onBackpressure(true)
        } else if pressured && bufferedBytes <= lowWatermark {
            pressured = false
            onBackpressure(false)
        }
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        cancel()
        onFailure(error)
    }
}
