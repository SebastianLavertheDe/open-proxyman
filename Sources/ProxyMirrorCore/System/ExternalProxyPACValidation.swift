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
            completion(.failure(ExternalProxyError(config.validationError ?? "请先选择 PAC 模式。"))); return
        }
        config.resolve(for: URL(string: "https://example.com/")!, on: group.next(), respectGlobalSwitch: false).whenComplete { result in
            let mapped = result.map { route -> String in
                guard let route else { return "PAC 已加载并执行，example.com 路由为 DIRECT。" }
                return "PAC 已加载并执行，example.com 路由为 \(route.mode.rawValue) \(route.host):\(route.port)。"
            }
            DispatchQueue.main.async { completion(mapped) }
        }
    }
}
