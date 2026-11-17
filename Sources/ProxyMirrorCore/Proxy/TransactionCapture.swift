import Foundation
import NIOCore

/// Bounds retained payloads and bytes still queued for publication.
final class CaptureBudget: @unchecked Sendable {
    static let live = CaptureBudget(limit: 256 * 1024 * 1024)

    private let limit: Int
    private let lock = NSLock()
    private var used = 0
    private var age = 0
    private var retained: [Entry] = []

    fileprivate final class Entry {
        let age: Int
        weak var transaction: Transaction?
        var pending = 0
        var published = 0
        var heapIndex: Int?
        var finished = false
        var evicted = false

        init(age: Int) { self.age = age }
    }

    init(limit: Int) { self.limit = max(0, limit) }

    fileprivate func makeEntry() -> Entry {
        lock.withLock {
            age += 1
            return Entry(age: age)
        }
    }

    fileprivate func reserve(_ bytes: Int, copies: Int, exact: Bool, for entry: Entry) -> Int {
        var discarded: [Transaction] = []
        let accepted = lock.withLock {
            guard !entry.evicted, !exact || bytes <= limit / copies else { return 0 }
            let desired = min(bytes, limit / copies) * copies
            while limit - used < desired, let oldest = retained.first, oldest.age < entry.age {
                removeRetained(oldest)
                oldest.evicted = true
                if let transaction = oldest.transaction {
                    transaction.discardCapturedPayload()
                    discarded.append(transaction)
                }
                used -= oldest.published
                oldest.published = 0
            }
            let available = (limit - used) / copies
            let accepted = exact && available < bytes ? 0 : min(bytes, available)
            let charge = accepted * copies
            used += charge
            entry.pending += charge
            return accepted
        }
        for transaction in discarded { transaction.notifyCaptureEviction() }
        return accepted
    }

    fileprivate func finish(_ entry: Entry, transaction: Transaction) {
        lock.withLock {
            entry.transaction = transaction
            entry.finished = true
            indexRetained(entry)
        }
    }

    fileprivate func publish(_ entry: Entry, charge: Int, update: (Bool) -> Void) {
        lock.withLock {
            update(!entry.evicted)
            entry.pending -= charge
            if entry.evicted {
                used -= charge
            } else {
                entry.published += charge
                indexRetained(entry)
            }
        }
    }

    fileprivate func release(_ entry: Entry) {
        lock.withLock {
            removeRetained(entry)
            used -= entry.pending + entry.published
        }
    }

    /// Completed transactions can be published out of order. Index them by creation age.
    private func indexRetained(_ entry: Entry) {
        guard entry.finished, entry.published > 0, !entry.evicted, entry.heapIndex == nil else { return }
        entry.heapIndex = retained.count
        retained.append(entry)
        siftUp(retained.count - 1)
    }

    private func removeRetained(_ entry: Entry) {
        guard let index = entry.heapIndex else { return }
        entry.heapIndex = nil
        let last = retained.removeLast()
        guard last !== entry else { return }
        retained[index] = last
        last.heapIndex = index
        if index > 0, last.age < retained[(index - 1) / 2].age {
            siftUp(index)
        } else {
            siftDown(index)
        }
    }

    private func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard retained[child].age < retained[parent].age else { return }
            swapEntries(child, parent)
            child = parent
        }
    }

    private func siftDown(_ start: Int) {
        var parent = start
        while parent * 2 + 1 < retained.count {
            let left = parent * 2 + 1
            let right = left + 1
            let child = right < retained.count && retained[right].age < retained[left].age ? right : left
            guard retained[child].age < retained[parent].age else { return }
            swapEntries(parent, child)
            parent = child
        }
    }

    private func swapEntries(_ first: Int, _ second: Int) {
        retained.swapAt(first, second)
        retained[first].heapIndex = first
        retained[second].heapIndex = second
    }
}

final class CaptureReservation: @unchecked Sendable {
    private let budget: CaptureBudget
    private let entry: CaptureBudget.Entry

    init(_ budget: CaptureBudget) {
        self.budget = budget
        entry = budget.makeEntry()
    }

    func reserve(_ bytes: Int, copies: Int = 1) -> Int {
        budget.reserve(bytes, copies: copies, exact: false, for: entry)
    }

    func reserveMetadata(_ bytes: Int) -> Bool {
        budget.reserve(bytes, copies: 1, exact: true, for: entry) == bytes
    }

    func finish(transaction: Transaction) {
        budget.finish(entry, transaction: transaction)
    }

    func publish(charge: Int, _ update: (Bool) -> Void) {
        budget.publish(entry, charge: charge, update: update)
    }

    deinit { budget.release(entry) }
}

private final class WebSocketCapture: @unchecked Sendable {
    static let queue = DispatchQueue(label: "ProxyMirror.WebSocketCapture", qos: .userInitiated)
    private var upstream = WSFrameParser()
    private var downstream = WSFrameParser()
    private var remaining = 5000
    private var upstreamDeflate: WebSocketDeflate.Decoder?
    private var downstreamDeflate: WebSocketDeflate.Decoder?

    init(headers: HTTPHeaders = HTTPHeaders()) {
        upstreamDeflate = WebSocketDeflate.negotiated(in: headers, direction: .upstream).map(WebSocketDeflate.Decoder.init)
        downstreamDeflate = WebSocketDeflate.negotiated(in: headers, direction: .downstream).map(WebSocketDeflate.Decoder.init)
    }

    func frames(_ data: Data, direction: WSFrame.Direction, timestamp: Date,
                reservation: CaptureReservation?) -> [WSFrame] {
        guard remaining > 0, !data.isEmpty else { return [] }
        var exhausted = false
        let admit = {
            let accepted = reservation?.reserveMetadata(WSFrame.captureMetadataCost) ?? true
            exhausted = !accepted
            return accepted
        }
        var frames = direction == .upstream
            ? upstream.feed(data, direction: direction, limit: remaining, admit: admit)
            : downstream.feed(data, direction: direction, limit: remaining, admit: admit)
        for index in frames.indices { frames[index].timestamp = timestamp }
        let inflater = direction == .upstream ? upstreamDeflate : downstreamDeflate
        if let inflater {
            for index in frames.indices where frames[index].rsv1 == true {
                guard let preview = inflater.preview(frames[index].payload),
                      preview.data.isEmpty || reservation?.reserveMetadata(preview.data.count) != false else { continue }
                frames[index].decompressedPreview = preview.data
                frames[index].decompressedPreviewTruncated = preview.truncated
            }
        }
        remaining = exhausted ? 0 : remaining - frames.count
        if remaining == 0 {
            upstream = WSFrameParser()
            downstream = WSFrameParser()
            upstreamDeflate = nil
            downstreamDeflate = nil
        }
        return frames
    }
}

/// The connection's event loop owns the accumulators. Final events flush before posting to the UI.
final class TransactionCapture: @unchecked Sendable {
    private struct WebSocketChunk: Sendable {
        let direction: WSFrame.Direction
        let bytes: Range<Int>
        let timestamp: Date
    }

    private struct PendingBody {
        var data = Data()
        var bytes = 0
        var charge = 0
        var captured = 0
        var truncated = false
        var webSocket = false

        mutating func append<C: Collection>(_ source: C, limit: Int, reservation: CaptureReservation?,
                                            webSocket: Bool) -> Range<Int> where C.Element == UInt8 {
            let count = source.count
            bytes += count
            self.webSocket = webSocket
            let start = data.count
            guard !truncated else { return start..<start }
            let wanted = min(count, max(0, limit - captured))
            // A WebSocket frame may keep a second copy of the captured payload.
            let copies = webSocket ? 2 : 1
            let accepted = wanted == 0 ? 0 : reservation?.reserve(wanted, copies: copies) ?? wanted
            if accepted > 0 { data.append(contentsOf: source.prefix(accepted)) }
            charge += accepted * copies
            captured += accepted
            truncated = accepted < count
            return start..<data.count
        }

        mutating func drain() -> (Data, Int, Bool, Int) {
            let batch = (data, bytes, webSocket, charge)
            data = Data()
            bytes = 0
            charge = 0
            return batch
        }
    }

    private let transaction: Transaction
    private let loop: EventLoop
    private weak var sink: TrafficSink?
    private let limit: Int
    private var request = PendingBody()
    private var response = PendingBody()
    private var timer: Scheduled<Void>?
    private var webSocketCapture: WebSocketCapture?
    private var webSocketChunks: [WebSocketChunk] = []
    private var upgradedToWebSocket = false
    private var sseState: SSEStreamState?
    private var publishedSSECount = 0
    private var publishedSSETruncated = false

    init(transaction: Transaction, on loop: EventLoop, sink: TrafficSink? = nil) {
        self.transaction = transaction
        self.loop = loop
        self.sink = sink
        self.limit = transaction.captureLimit
    }

    func append<C: Collection>(_ source: C, direction: WSFrame.Direction, webSocket: Bool = false) where C.Element == UInt8 {
        loop.assertInEventLoop()
        guard !source.isEmpty else { return }
        let captured: Range<Int>
        switch direction {
        case .upstream:
            captured = request.append(source, limit: limit, reservation: transaction.captureReservation, webSocket: webSocket)
        case .downstream:
            captured = response.append(source, limit: limit, reservation: transaction.captureReservation, webSocket: webSocket)
            sseState?.append(source)
        }
        if webSocket && !captured.isEmpty {
            webSocketChunks.append(WebSocketChunk(direction: direction, bytes: captured, timestamp: Date()))
        }
        if timer == nil {
            timer = loop.scheduleTask(in: .milliseconds(40)) { [weak self] in self?.flush() }
        }
    }

    func setResponseHeadersForSSE(_ headers: HTTPHeaders) {
        loop.assertInEventLoop()
        let encodings = headers.values(of: "content-encoding")
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if SSEStreamState.matches(headers.value(of: "content-type") ?? ""),
           encodings.allSatisfy({ $0 == "identity" }) {
            sseState = SSEStreamState()
        }
    }

    func upgradeToWebSocket(headers: HTTPHeaders) {
        flush()
        upgradedToWebSocket = true
        webSocketCapture = WebSocketCapture(headers: headers)
    }

    func flush() {
        loop.assertInEventLoop()
        timer?.cancel()
        timer = nil
        guard request.bytes > 0 || response.bytes > 0 else { return }
        let (requestData, requestBytes, requestWS, requestCharge) = request.drain()
        let (responseData, responseBytes, responseWS, responseCharge) = response.drain()
        if let sseState, sseState.events.count > publishedSSECount || sseState.truncated != publishedSSETruncated {
            let events = Array(sseState.events.dropFirst(publishedSSECount))
            let truncated = sseState.truncated
            publishedSSECount = sseState.events.count
            publishedSSETruncated = truncated
            onMain { [transaction] in
                transaction.sseEvents.append(contentsOf: events)
                transaction.sseEventsTruncated = truncated
            }
        }
        let bodyCharge = requestCharge + responseCharge
        let publish = { [transaction, weak sink] (frames: [WSFrame]) in
            let previewCharge = frames.reduce(0) { $0 + ($1.decompressedPreview?.count ?? 0) }
            onMain {
                transaction.receiveCapture(request: requestData, requestBytes: requestBytes,
                                           response: responseData, responseBytes: responseBytes,
                                           frames: frames, charge: bodyCharge + frames.count * WSFrame.captureMetadataCost + previewCharge,
                                           sink: sink)
                sink?.transactionBodyUpdated(transaction)
            }
        }
        if requestWS || responseWS {
            let parser = webSocketCapture ?? WebSocketCapture()
            webSocketCapture = parser
            let reservation = transaction.captureReservation
            let chunks = webSocketChunks
            webSocketChunks = []
            WebSocketCapture.queue.async {
                var frames: [WSFrame] = []
                for chunk in chunks {
                    let data = chunk.direction == .upstream ? requestData : responseData
                    frames.append(contentsOf: parser.frames(data[chunk.bytes], direction: chunk.direction,
                                                             timestamp: chunk.timestamp, reservation: reservation))
                }
                publish(frames)
            }
        } else {
            publish([])
        }
    }

    deinit {
        guard upgradedToWebSocket || webSocketCapture != nil else { return }
        // The parser can retain a partial frame. Let it and all queued batches
        // drain before making a closed WebSocket eligible for reclamation.
        webSocketCapture = nil
        WebSocketCapture.queue.async { [transaction] in
            onMain { transaction.captureReservation?.finish(transaction: transaction) }
        }
    }
}
