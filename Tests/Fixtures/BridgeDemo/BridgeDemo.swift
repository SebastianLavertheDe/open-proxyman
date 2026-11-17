import SwiftUI
import UIKit
import ProxyMirrorBridgeKit

@main
struct BridgeDemo: App {
    var body: some Scene { WindowGroup { CaptureView() } }
}

private struct CaptureView: View {
    @State private var pairing = ""
    @State private var address = ""
    @State private var status = ""
    @State private var sending = false

    var body: some View {
        Form {
            SecureField("ProxyMirror 配对码", text: $pairing)
                .textContentType(.none)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("测试接口 URL", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("发送测试请求") { Task { await send() } }
                .disabled(pairing.isEmpty || address.isEmpty || sending)
            if !status.isEmpty { Text(status) }
        }
    }

    private func send() async {
        guard let url = URL(string: address), let scheme = url.scheme,
              ["https", "http"].contains(scheme), url.host != nil else {
            status = "请输入完整的 HTTP 或 HTTPS URL。"
            return
        }
        sending = true
        defer { sending = false }
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            let bridge = try BridgeSession(pairingCode: pairing, deviceName: UIDevice.current.model,
                                           session: URLSession(configuration: configuration))
            let (data, response) = try await bridge.data(for: URLRequest(url: url))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            status = "HTTP \(code) · \(data.count) B。请在 Mac 流量列表查看 Bridge 记录。"
        } catch {
            status = error.localizedDescription
        }
    }
}
