import Darwin
import Foundation
import Network
import NetworkExtension

@main
enum TransparentProxyExtension {
    static func main() {
        NEProvider.startSystemExtensionMode()
        dispatchMain()
    }
}

final class TransparentProxyProvider: NETransparentProxyProvider {
    private struct Destination {
        let endpoint: Network.NWEndpoint
        let host: String
        let address: String?
        let port: Int
    }

    private struct Configuration {
        let port: Network.NWEndpoint.Port
        let token: String
        let hostBundleIdentifier: String

        init?(_ values: [String: Any]) {
            guard let port = values["port"] as? Int,
                  let rawPort = UInt16(exactly: port), rawPort != 0,
                  let endpointPort = Network.NWEndpoint.Port(rawValue: rawPort),
                  let token = values["token"] as? String, !token.isEmpty, token.utf8.count <= 128,
                  let hostBundleIdentifier = values["hostBundleIdentifier"] as? String,
                  !hostBundleIdentifier.isEmpty else {
                return nil
            }
            self.port = endpointPort
            self.token = token
            self.hostBundleIdentifier = hostBundleIdentifier
        }
    }

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let flowLimit = 256
    private var configuration: Configuration?
    private var generation = 0
    private var relays: [UUID: TransparentTCPRelay] = [:]
    private var engineUnavailableUntil = DispatchTime(uptimeNanoseconds: 0)

    override init() {
        queue = DispatchQueue(label: "com.sebastianLavertheDe.proxymirror.transparent-proxy")
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let values = tunnelProtocol.providerConfiguration,
              let configuration = Configuration(values) else {
            completionHandler(TransparentTCPRelay.error(.invalidArgument, "Invalid transparent proxy configuration"))
            return
        }

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = ["0.0.0.0", "::"].flatMap { host in
            [Network.NWEndpoint.Port.http, .https].map { port in
                if #available(macOS 15.0, *) {
                    return NENetworkRule(
                        destinationNetworkEndpoint: .hostPort(host: Network.NWEndpoint.Host(host), port: port),
                        prefix: 0,
                        protocol: .TCP
                    )
                }
                return NENetworkRule(
                    destinationNetwork: NWHostEndpoint(hostname: host, port: String(port.rawValue)),
                    prefix: 0,
                    protocol: .TCP
                )
            }
        }

        queue.async {
            self.generation += 1
            let generation = self.generation
            self.setTunnelNetworkSettings(settings) { error in
                self.queue.async {
                    guard generation == self.generation else {
                        completionHandler(TransparentTCPRelay.error(.aborted, "Transparent proxy start was cancelled"))
                        return
                    }
                    if error == nil {
                        self.configuration = configuration
                        self.engineUnavailableUntil = DispatchTime(uptimeNanoseconds: 0)
                    }
                    completionHandler(error)
                }
            }
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.generation += 1
            self.configuration = nil
            let activeRelays = self.relays.values
            self.relays.removeAll()
            for relay in activeRelays {
                relay.stop()
            }
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let flow = flow as? NEAppProxyTCPFlow, !flow.isBound,
              let destination = Self.destination(of: flow) else {
            return false
        }
        let application = flow.metaData.sourceAppSigningIdentifier

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return admit(flow, destination: destination, application: application)
        }
        return queue.sync {
            admit(flow, destination: destination, application: application)
        }
    }

    private func admit(_ flow: NEAppProxyTCPFlow, destination: Destination, application: String) -> Bool {
        guard let configuration,
              !Self.isOwnApplication(application, hostIdentifier: configuration.hostBundleIdentifier),
              relays.count < flowLimit,
              DispatchTime.now() >= engineUnavailableUntil else {
            return false
        }

        let id = UUID()
        let relay = TransparentTCPRelay(
            queue: queue,
            flow: flow,
            destination: destination.endpoint,
            host: destination.host,
            address: destination.address,
            port: destination.port,
            application: application.isEmpty ? nil : application,
            enginePort: configuration.port,
            token: configuration.token,
            onEngineUnavailable: { [weak self] in
                self?.engineUnavailableUntil = .now() + .seconds(2)
            },
            onFinish: { [weak self] in
                self?.relays.removeValue(forKey: id)
            }
        )
        relays[id] = relay
        relay.start()
        return true
    }

    private static func isOwnApplication(_ application: String, hostIdentifier: String) -> Bool {
        application == hostIdentifier || application.hasPrefix(hostIdentifier + ".")
            || application == Bundle.main.bundleIdentifier
    }

    private static func destination(of flow: NEAppProxyTCPFlow) -> Destination? {
        let endpoint: Network.NWEndpoint
        if #available(macOS 15.0, *) {
            endpoint = flow.remoteFlowEndpoint
        } else {
            guard let legacy = flow.remoteEndpoint as? NWHostEndpoint,
                  let port = Network.NWEndpoint.Port(legacy.port) else { return nil }
            endpoint = .hostPort(host: Network.NWEndpoint.Host(legacy.hostname), port: port)
        }

        guard case let .hostPort(host, port) = endpoint, port.rawValue == 80 || port.rawValue == 443 else {
            return nil
        }
        guard !isLoopback(host) else { return nil }

        let endpointHost = String(describing: host)
        let address: String?
        switch host {
        case .ipv4:
            address = endpointHost
        case .ipv6(let value):
            // The capture engine receives numeric addresses without zone identifiers.
            // Leave scoped destinations with the system to preserve their interface.
            guard value.interface == nil else { return nil }
            address = endpointHost
        default:
            address = nil
        }
        let captureHost = flow.remoteHostname.flatMap { name in
            name.isEmpty || isLoopback(Network.NWEndpoint.Host(name)) ? nil : name
        } ?? endpointHost
        return Destination(endpoint: endpoint, host: captureHost, address: address, port: Int(port.rawValue))
    }

    private static func isLoopback(_ host: Network.NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return address.rawValue.first == 127
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes.last == 1
            let mappedLoopback = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127
            return loopback || mappedLoopback
        case .name(let name, _):
            let normalized = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return normalized == "localhost" || normalized.hasSuffix(".localhost")
        @unknown default:
            return true
        }
    }
}
