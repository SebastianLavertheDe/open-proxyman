import Foundation
import ProxyMirrorBridgeKit
@testable import ProxyMirrorCore

@MainActor
func checkBridge(_ test: CoreAssertions) throws {
    guard let address = LANAccess.addresses.first else {
        return
    }
    let received = TrafficStore()
    let listener = try BridgeListener(address: address, device: address) { capture, peer in
        if let tx = Transaction(bridge: capture, deviceAddress: peer, limit: 8, sink: nil) {
            received.ingestCaptured(tx)
        }
    }
    defer { listener.stop() }
    let ready = BridgeTestValue()
    listener.start { state in
        switch state {
        case .ready: ready.set(true)
        case .failed, .waiting: ready.set(false)
        default: break
        }
    }
    spinUntil { ready.value != nil }
    test.expect(ready.value == true, "Bridge Bonjour 监听就绪")
    guard ready.value == true else { return }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BridgeOriginFixture.self]
    let bridge = try BridgeSession(pairingCode: listener.pairingCode, deviceName: "Local Fixture",
                                   session: URLSession(configuration: config))
    var request = URLRequest(url: URL(string: "https://bridge-fixture.invalid/item?count=2")!)
    request.httpMethod = "POST"
    request.httpBody = Data("payload".utf8)
    request.setValue("test-only-token", forHTTPHeaderField: "Authorization")
    let clientResult = BridgeTestValue()
    Task {
        let result = try? await bridge.data(for: request)
        clientResult.set(result?.0 == BridgeOriginFixture.body && (result?.1 as? HTTPURLResponse)?.statusCode == 201)
    }
    spinUntil { clientResult.value != nil && !received.transactions.isEmpty }
    test.expect(clientResult.value == true, "Bridge SDK 保留 URLSession 原有返回值")
    let tx = received.transactions.first
    test.equal(tx?.clientAddress, address, "Bridge 接收端保留设备 IP")
    test.expect(tx?.clientName?.contains("Bridge · Local Fixture") == true, "Bridge 流量标明来源")
    test.equal(tx?.fullURL, request.url?.absoluteString, "Bridge 完整 URL 入表")
    test.equal(tx?.requestHeaders.value(of: "Authorization"), "[redacted]", "Bridge 授权头默认脱敏")
    test.equal(tx?.requestBody, request.httpBody, "Bridge 捕获请求正文")
    test.equal(tx?.responseBody, Data(BridgeOriginFixture.body.prefix(8)), "Bridge 保留响应正文前缀")
    test.equal(tx?.responseBytes, BridgeOriginFixture.body.count, "Bridge 保留原始响应字节数")
    test.expect(tx?.responseTruncated == true, "Bridge 标记被截断的正文")
    test.equal(tx?.statusCode, 201, "Bridge HTTP 状态入表")
}

private func spinUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

private final class BridgeTestValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}

private final class BridgeOriginFixture: URLProtocol, @unchecked Sendable {
    static let body = Data("{\"fixture\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bridge-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
