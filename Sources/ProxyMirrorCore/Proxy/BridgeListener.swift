import Foundation
import Network
@_spi(Transport) import ProxyMirrorBridgeKit

/// Publishes a separate Bonjour port for app captures from the approved device.
final class BridgeListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ProxyMirror.bridge", qos: .utility)
    private let listener: NWListener
    private let pairing = BridgeWire.Pairing()
    private let device: IPv4Address
    private let deviceAddress: String
    private let deliver: @MainActor @Sendable (BridgeWire.Capture, String) -> Void
    private var clients: [UUID: NWConnection] = [:]
    private var seen = Set<UUID>()
    private var seenOrder: [UUID] = []
    private var pending = 0
    private var stopped = false

    var pairingCode: String { pairing.code }

    init(address: String, device: String,
         deliver: @escaping @MainActor @Sendable (BridgeWire.Capture, String) -> Void) throws {
        guard let local = IPv4Address(address), let device = IPv4Address(device) else {
            throw ProxyError.invalidLANAccess
        }
        self.device = device
        deviceAddress = device.debugDescription
        self.deliver = deliver
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(local), port: .any)
        listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: pairing.name, type: BridgeWire.serviceType)
    }

    func start(onState: @escaping @Sendable (NWListener.State) -> Void) {
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            listener.cancel()
            for client in clients.values { client.cancel() }
            clients.removeAll()
        }
    }

    private func accept(_ client: NWConnection) {
        guard !stopped, clients.count < 8, pending < 8,
              case .hostPort(.ipv4(let peer), _) = client.endpoint, peer == device else {
            client.cancel()
            return
        }
        let id = UUID()
        clients[id] = client
        client.start(queue: queue)
        client.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, self.clients[id] != nil else { return }
            if let data, data.count == 4, error == nil {
                self.receiveFrame(id, size: BridgeWire.length(data))
            } else {
                self.finish(id)
            }
        }
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(id) }
    }

    private func receiveFrame(_ id: UUID, size: Int) {
        guard let client = clients[id], (32...BridgeWire.frameLimit).contains(size) else {
            finish(id)
            return
        }
        client.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, _, error in
            guard let self, self.clients[id] != nil else { return }
            guard error == nil, let data, data.count == size, self.pending < 8,
                  let capture = try? BridgeWire.decode(data, pairing: self.pairing),
                  self.seen.insert(capture.header.id).inserted else {
                self.finish(id)
                return
            }
            self.seenOrder.append(capture.header.id)
            if self.seenOrder.count > 1024 { self.seen.remove(self.seenOrder.removeFirst()) }
            self.pending += 1
            Task { @MainActor in
                self.deliver(capture, self.deviceAddress)
                self.queue.async {
                    self.pending -= 1
                    self.clients[id]?.send(content: Data([1]), completion: .contentProcessed { _ in
                        self.finish(id)
                    })
                }
            }
        }
    }

    private func finish(_ id: UUID) {
        clients.removeValue(forKey: id)?.cancel()
    }
}

extension Transaction {
    @MainActor
    convenience init?(bridge capture: BridgeWire.Capture, deviceAddress: String,
                      limit: Int, sink: TrafficSink?) {
        let header = capture.header
        guard let parsed = URLParser.parse(target: header.url.absoluteString),
              let scheme = parsed.scheme, let host = parsed.host, !host.isEmpty,
              (1...65535).contains(parsed.port), header.startedAt >= .distantPast,
              header.startedAt <= .distantFuture, !header.method.isEmpty else { return nil }
        self.init(startedAt: header.startedAt, captureBudget: .live)
        (path, query) = splitQueryPath(parsed.path)
        self.scheme = scheme
        self.host = host
        port = parsed.port
        method = header.method
        clientName = "Bridge · \(header.device.isEmpty ? deviceAddress : header.device) · \(header.app)"
        clientBundle = header.app
        clientAddress = deviceAddress
        requestHeaders = HTTPHeaders(header.requestHeaders.map { ($0.name, $0.value) })
        responseHeaders = HTTPHeaders(header.responseHeaders.map { ($0.name, $0.value) })
        contentType = responseHeaders.value(of: "Content-Type") ?? ""
        let requestCount = captureReservation?.reserve(min(max(0, limit), capture.request.count)) ?? 0
        let responseCount = captureReservation?.reserve(min(max(0, limit), capture.response.count)) ?? 0
        receiveCapture(request: Data(capture.request.prefix(requestCount)), requestBytes: header.requestBytes,
                       response: Data(capture.response.prefix(responseCount)), responseBytes: header.responseBytes,
                       charge: requestCount + responseCount, sink: sink)
        requestBodyComplete = !header.requestStreamed
        if header.requestStreamed { requestTruncated = true }
        responseBodyComplete = header.status != nil
        statusCode = header.status ?? 0
        duration = header.duration
        errorText = header.error
        state = header.status == nil ? .failed : .completed
    }
}
