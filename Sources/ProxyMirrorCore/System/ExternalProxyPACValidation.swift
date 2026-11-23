import Foundation
import NIOCore
import NIOPosix

/// Uses the same bounded CFNetwork resolver as live upstream routing.
enum ExternalProxyPACValidation {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    static func check(_ candidate: ExternalProxyConfig, completion: @escaping (Result<String, Error>) -> Void) {
        var config = candidate
        config.enabled = true; config.bypassHosts = []
        guard config.mode == .pac, config.validationError == nil else {
            if let issue = config.validationIssue { completion(.failure(SystemProxyOperationError(issue))) }
            else { completion(.failure(SystemProxyOperationError(.externalProxyPacvalidationSelectPacModeFirst))) }
            return
        }
        config.resolve(for: URL(string: "https://example.com/")!, on: group.next(), respectGlobalSwitch: false).whenComplete { result in
            let mapped = result.map { route -> String in
                guard let route else { return Strings.Errors.externalProxyPacvalidationPacLoadedAndExecutedTheRouteForExample }
                return Strings.Errors.externalProxyPacvalidationPacLoadedAndExecutedTheRouteForExample2(String(route.mode.rawValue), String(route.host), Int(route.port))
            }
            DispatchQueue.main.async { completion(mapped) }
        }
    }
}
