import Foundation
import Network
import NetworkExtension

final class TransparentTCPRelay {
    private enum Phase {
        case connectingToEngine
        case authenticatingEngine
        case connectingToDestination
        case openingFlow
        case relaying
        case finished
    }

    private let queue: DispatchQueue
    private let flow: NEAppProxyTCPFlow
    private let destination: Network.NWEndpoint
    private let engine: Network.NWEndpoint
    private let handshake: TransparentRelayHandshake?
    private let onEngineUnavailable: () -> Void
    private let onFinish: () -> Void
    private var connection: NWConnection?
    private var deadline: DispatchWorkItem?
    private var phase: Phase = .connectingToEngine
    private var upstreamClosed = false
    private var downstreamClosed = false

    init(
        queue: DispatchQueue,
        flow: NEAppProxyTCPFlow,
        destination: Network.NWEndpoint,
        host: String,
        address: String?,
        port: Int,
        application: String?,
        enginePort: Network.NWEndpoint.Port,
        token: String,
        onEngineUnavailable: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.queue = queue
        self.flow = flow
        self.destination = destination
        self.engine = .hostPort(host: "127.0.0.1", port: enginePort)
        self.handshake = TransparentRelayHandshake(token: token, host: host, address: address, port: port, application: application)
        self.onEngineUnavailable = onEngineUnavailable
        self.onFinish = onFinish
    }

    func start() {
        if handshake == nil {
            connectToDestination()
        } else {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            connect(to: engine, parameters: parameters, timeout: .seconds(2))
        }
    }

    func stop() {
        finish(Self.error(.aborted, "Transparent proxy stopped"))
    }

    private func connectToDestination() {
        // This is only called before the app flow is opened or any app bytes are read.
        phase = .connectingToDestination
        let parameters = NWParameters.tcp
        if #available(macOS 15.0, *) {
            flow.setMetadata(on: parameters)
        }
        connect(to: destination, parameters: parameters, timeout: .seconds(10))
    }

    private func connect(to endpoint: Network.NWEndpoint, parameters: NWParameters, timeout: DispatchTimeInterval) {
        connection?.cancel()
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            self.connectionChanged(state, connection: connection)
        }
        scheduleDeadline(timeout, for: connection)
        connection.start(queue: queue)
    }

    private func connectionChanged(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            if phase == .connectingToEngine, let handshake {
                authenticate(handshake, connection: connection)
            } else if phase == .connectingToDestination {
                openFlow(connection)
            }
        case .waiting(let error):
            if phase == .connectingToEngine || phase == .authenticatingEngine {
                connectionFailed(Self.error(.hostUnreachable, error.localizedDescription))
            }
        case .failed(let error):
            // Network.framework may report a state failure after the remote FIN while
            // a receive still holds data. Let the I/O callbacks drain it and report EOF.
            if phase == .relaying {
                scheduleDeadline(.seconds(30), for: connection)
            } else {
                connectionFailed(Self.error(.hostUnreachable, error.localizedDescription))
            }
        case .cancelled:
            connectionFailed(Self.error(.aborted, "Transparent proxy connection was cancelled"))
        default:
            break
        }
    }

    private func authenticate(_ handshake: TransparentRelayHandshake, connection: NWConnection) {
        phase = .authenticatingEngine
        connection.send(content: handshake.request, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            if let error {
                self.connectionFailed(Self.error(.notConnected, error.localizedDescription))
                return
            }
            connection.receive(
                minimumIncompleteLength: TransparentRelayHandshake.responseLength,
                maximumLength: TransparentRelayHandshake.responseLength
            ) { [weak self, weak connection] response, _, isComplete, error in
                guard let self, let connection, self.connection === connection else { return }
                guard error == nil, !isComplete, let response, handshake.accepts(response) else {
                    self.connectionFailed(Self.error(.refused, "The local proxy failed authentication"))
                    return
                }
                self.openFlow(connection)
            }
        })
    }

    private func openFlow(_ connection: NWConnection) {
        phase = .openingFlow
        scheduleDeadline(.seconds(10), for: connection)
        let completion: (Error?) -> Void = { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                if let error {
                    self.finish(Self.error(.notConnected, error.localizedDescription))
                    return
                }
                self.deadline?.cancel()
                self.deadline = nil
                self.phase = .relaying
                self.readFromApplication(connection)
                self.readFromConnection(connection)
            }
        }
        if #available(macOS 15.0, *) {
            flow.open(withLocalFlowEndpoint: nil, completionHandler: completion)
        } else {
            flow.open(withLocalEndpoint: nil, completionHandler: completion)
        }
    }

    private func readFromApplication(_ connection: NWConnection) {
        flow.readData { [weak self, weak connection] data, error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                if let error {
                    self.finish(Self.error(.peerReset, error.localizedDescription))
                } else if let data, !data.isEmpty {
                    connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
                        guard let self, let connection, self.connection === connection else { return }
                        if let error {
                            self.finish(Self.error(.peerReset, error.localizedDescription))
                        } else {
                            self.readFromApplication(connection)
                        }
                    })
                } else {
                    self.closeUpstream(connection)
                }
            }
        }
    }

    private func closeUpstream(_ connection: NWConnection) {
        flow.closeReadWithError(nil)
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            if let error {
                self.finish(Self.error(.peerReset, error.localizedDescription))
                return
            }
            self.upstreamClosed = true
            if self.downstreamClosed { self.finish() }
        })
    }

    private func readFromConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let error {
                self.finish(Self.error(.peerReset, error.localizedDescription))
            } else if let data, !data.isEmpty {
                self.flow.write(data) { [weak self, weak connection] error in
                    guard let self, let connection else { return }
                    self.queue.async {
                        guard self.connection === connection else { return }
                        if let error {
                            self.finish(Self.error(.peerReset, error.localizedDescription))
                        } else {
                            self.didReceive(connection, isComplete: isComplete)
                        }
                    }
                }
            } else {
                self.didReceive(connection, isComplete: isComplete)
            }
        }
    }

    private func didReceive(_ connection: NWConnection, isComplete: Bool) {
        if isComplete {
            flow.closeWriteWithError(nil)
            downstreamClosed = true
            if upstreamClosed { finish() }
        } else {
            readFromConnection(connection)
        }
    }

    private func scheduleDeadline(_ interval: DispatchTimeInterval, for connection: NWConnection) {
        deadline?.cancel()
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else { return }
            self.connectionFailed(Self.error(.timedOut, "Transparent proxy connection timed out"))
        }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + interval, execute: deadline)
    }

    private func connectionFailed(_ error: Error) {
        if phase == .connectingToEngine || phase == .authenticatingEngine {
            onEngineUnavailable()
            connectToDestination()
        } else {
            finish(error)
        }
    }

    private func finish(_ error: Error? = nil) {
        guard phase != .finished else { return }
        phase = .finished
        deadline?.cancel()
        deadline = nil
        let connection = self.connection
        self.connection = nil
        connection?.cancel()
        if let error {
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
        }
        onFinish()
    }

    static func error(_ code: NEAppProxyFlowError.Code, _ description: String) -> NSError {
        NSError(domain: NEAppProxyErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
