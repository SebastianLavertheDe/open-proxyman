import Foundation
import ProxyMirrorFoundation

enum LocalControlError: Error, LocalizedError {
    case usage(String), failed(String), noMatches(String)
    var errorDescription: String? {
        switch self { case .usage(let value), .failed(let value), .noMatches(let value): return value }
    }
}

enum TxState: String, Codable { case pending, awaiting, completed, failed }
struct WSFrame: Identifiable, Codable, Sendable {
    enum Direction: String, Codable, Sendable { case upstream = "send", downstream = "recv" }
    var id = UUID()
    let direction: Direction
    let opcode: UInt8
    let fin: Bool
    let masked: Bool
    let payload: Data
    var timestamp = Date()
    var rsv1: Bool? = nil
    var decompressedPreview: Data? = nil
    var decompressedPreviewTruncated: Bool? = nil
}
final class Transaction {
    let id = UUID()
    var fixtureFullURL = "https://example.test/"
    var fullURL: String { fixtureFullURL }
    var state = TxState.completed
    var isWebSocket = false
    var websocketFrames: [WSFrame] = []
    var requestBody = Data(), responseBody = Data()
    func capturedPayloadSnapshot() -> (request: Data, requestBytes: Int, requestTruncated: Bool,
                                      response: Data, responseBytes: Int, responseTruncated: Bool, frames: [WSFrame]) {
        (requestBody, requestBody.count, false, responseBody, responseBody.count, false, websocketFrames)
    }
}
struct SessionRecord: Codable, Sendable {
    var id: UUID
    var url: String
    var requestBody: Data
    var responseBody: Data
    init(_ transaction: Transaction) {
        id = transaction.id; url = transaction.fullURL
        requestBody = transaction.requestBody; responseBody = transaction.responseBody
    }
}
@MainActor
final class TrafficStore {
    var transactions: [Transaction] = []
    func add(_ transaction: Transaction) { transactions.append(transaction) }
}
final class AppSettings {
    var mcpEnabled = true, mcpRedactSensitiveData = true
}
final class CertificateAuthority: @unchecked Sendable {
    var caCertPath: URL { URL(fileURLWithPath: "/does-not-exist/fixture.pem") }
}
struct ProxyRuntimeContext: Sendable {}
@MainActor
final class AppState {
    static let shared = AppState()
    let defaultsName = "pm.workbench.fixture." + UUID().uuidString
    lazy var defaults = UserDefaults(suiteName: defaultsName)!
    let store = TrafficStore(), settings = AppSettings(), certificateAuthority = CertificateAuthority()
    var caInstalled = false, proxyRunning = true
    var listenerPort: UInt16 = 9090
    var runtimeContext: ProxyRuntimeContext { ProxyRuntimeContext() }
    var refreshes = 0
    func refreshCertificateStatus(completion: ((Bool) -> Void)? = nil) {
        refreshes += 1; completion?(caInstalled)
    }
}

enum ComposeService {
    typealias ParsedRequest = HTTPRequest
    final class RequestTask: @unchecked Sendable {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    static var deferred = false
    static var dispatchCompletion = false
    static var resultState = TxState.completed
    static var responseBytes = Data("{\"token\":\"result-secret\",\"answer\":42}".utf8)
    static var pending: [(RequestTask, (Transaction) -> Void, Transaction)] = []
    @discardableResult
    static func execute(_ request: ParsedRequest, runtime: ProxyRuntimeContext, proxyPort: UInt16? = nil,
                        onResult: @escaping (Transaction) -> Void) -> RequestTask? {
        let task = RequestTask(), result = Transaction()
        result.fixtureFullURL = request.url; result.requestBody = request.body ?? Data(); result.responseBody = responseBytes
        result.state = resultState
        if deferred { pending.append((task, onResult, result)) }
        else if dispatchCompletion { DispatchQueue.main.async { onResult(result) } }
        else { onResult(result) }
        return task
    }
    static func finishPending() {
        let saved = pending; pending = []
        for (_, callback, result) in saved { callback(result) }
    }
}

enum CertificatePlatformGuides {
    static let simulatorPlatforms = ["watchOS"], frameworks = ["Java"]
    struct Link: Identifiable { let title: String, url: URL; var id: String { url.absoluteString } }
    struct Guide { var steps = ["fixture step"]; var commands = "fixture command"; var links: [Link] = [] }
    static func guide(for platform: String, certificatePath: String, port: Int) -> Guide { Guide() }
}
enum RequestCode {
    enum Format: String, CaseIterable { case curl }
}
enum LocalControl {
    static func automationRequest(_ object: [String: Any], isMCP: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
enum LocalControlSocket {
    static func request(_ data: Data) throws -> Data {
        try MainActor.assumeIsolated {
            let arguments = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return Data([0]) + (try AutomationControl.execute(arguments, app: .shared, isMCP: true))
        }
    }
}
