import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cross-platform harness for the SAME URLSession bridge compiled into ScriptWorker.
/// JSON lines in: {request:{id,url,...}}, {cancel:id,delayMs:100}; JSON lines out.
@main
struct ScriptNetworkBridgeHarness {
    static func main() {
        let group = DispatchGroup()
        let outputLock = NSLock()
        var limits = ScriptNetworkBridge.Limits([
            "wallTimeMs": 2000, "requestTimeoutMs": 1000, "responseLimit": 32768,
            "blockedProxyPort": Int(ProcessInfo.processInfo.environment["PM_TEST_BLOCKED_PORT"] ?? "9090") ?? 9090,
        ])
        limits.maximumRequests = 8
        let bridge = ScriptNetworkBridge(limits: limits) { value in
            outputLock.lock(); defer { outputLock.unlock() }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            group.leave()
        }
        while let line = readLine() {
            do {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let request = object["request"] as? [String: Any] {
                    group.enter()
                    let data = try JSONSerialization.data(withJSONObject: request)
                    bridge.start(String(decoding: data, as: UTF8.self))
                } else if let milliseconds = object["sleepMs"] as? Int {
                    Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
                } else if let id = object["cancel"] as? String {
                    let delay = object["delayMs"] as? Int ?? 0
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay)) { bridge.cancel(id) }
                }
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            }
        }
        let result = group.wait(timeout: .now() + .seconds(5))
        bridge.cancelAll()
        if result != .success { exit(1) }
    }
}
