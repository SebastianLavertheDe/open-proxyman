import Foundation
import Network

/// An opt-in URLSession wrapper for HTTP(S) data requests in a development app.
public final class BridgeSession: Sendable {
    private let session: URLSession
    private let sender: CaptureSender
    private let app: String
    private let device: String
    private static let privateHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
    ]

    /// Paste the pairing code shown in the Mac app. The supplied session performs the original request.
    public init(pairingCode: String, deviceName: String, session: URLSession = .shared) throws {
        self.session = session
        sender = try CaptureSender(pairing: BridgeWire.Pairing(code: pairingCode))
        app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        device = String(deviceName.prefix(128))
    }

    public func data(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        let startedAt = Date()
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            if let http = response as? HTTPURLResponse {
                report(request, response: http, data: data, startedAt: startedAt, start: start, error: nil)
            }
            return (data, response)
        } catch {
            report(request, response: nil, data: Data(), startedAt: startedAt, start: start, error: error)
            throw error
        }
    }

    private func report(_ request: URLRequest, response: HTTPURLResponse?, data: Data,
                        startedAt: Date, start: TimeInterval, error: Error?) {
        guard let url = Self.captureURL(request.url) else { return }
        let body = request.httpBody ?? Data()
        let requestData = Self.sample(body)
        let responseData = Self.sample(data)
        let responseHeaders = response?.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String { result[name] = String(describing: field.value) }
        } ?? [:]
        let failure = error.map { error in
            let error = error as NSError
            return "\(error.domain) (\(error.code))"
        }
        let header = BridgeWire.Header(
            app: app, device: device, url: url,
            method: request.httpMethod ?? "GET", startedAt: startedAt,
            duration: max(0, ProcessInfo.processInfo.systemUptime - start),
            status: response?.statusCode, error: failure,
            requestHeaders: Self.fields(request.allHTTPHeaderFields ?? [:]),
            responseHeaders: Self.fields(responseHeaders),
            requestBytes: body.count, responseBytes: data.count,
            requestStreamed: request.httpBodyStream != nil, requestLength: requestData.count,
            responseLength: responseData.count
        )
        sender.send(BridgeWire.Capture(header: header, request: requestData, response: responseData))
    }

    private static func captureURL(_ url: URL?) -> URL? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.host != nil else { return nil }
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        return parts.url
    }

    private static func fields(_ headers: [String: String]) -> [BridgeWire.Header.Field] {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.prefix(128).map { name, value in
            BridgeWire.Header.Field(name: String(name.prefix(256)),
                                    value: privateHeaders.contains(name.lowercased()) ? "[redacted]" : String(value.prefix(2048)))
        }
    }

    private static func sample(_ body: Data) -> Data {
        body.count <= BridgeWire.bodyLimit ? body : body.subdata(in: 0..<BridgeWire.bodyLimit)
    }
}

private final class CaptureSender: @unchecked Sendable {
    private let pairing: BridgeWire.Pairing
    private let queue = DispatchQueue(label: "ProxyMirrorBridgeKit.sender", qos: .utility)
    private let slots = DispatchSemaphore(value: 8)
    private var connections: [UUID: NWConnection] = [:]

    init(pairing: BridgeWire.Pairing) { self.pairing = pairing }

    func send(_ capture: BridgeWire.Capture) {
        guard slots.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            guard let frame = try? BridgeWire.encode(capture, pairing: pairing) else {
                slots.signal()
                return
            }
            let id = capture.header.id
            let endpoint = NWEndpoint.service(name: pairing.name, type: BridgeWire.serviceType, domain: "local.", interface: nil)
            let connection = NWConnection(to: endpoint, using: .tcp)
            connections[id] = connection
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    connection.send(content: frame, completion: .contentProcessed { [self] error in
                        if error != nil { finish(id); return }
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] _, _, _, _ in
                            finish(id)
                        }
                    })
                case .failed, .cancelled: finish(id)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        slots.signal()
    }
}
