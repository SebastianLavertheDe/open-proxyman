# ProxyMirrorBridgeKit

用于自研 iOS 调试应用。SDK 记录显式交给 `BridgeSession.data(for:delegate:)` 的 HTTP/HTTPS 请求和响应，并通过局域网发送到 Mac。原请求继续由传入的 `URLSession` 执行，其 TLS 信任、缓存及代理配置由调用方控制。

## 接入

1. 将本目录作为本地 Swift Package 加入 iOS 15+ 工程，链接 `ProxyMirrorBridgeKit`。
2. 在 iOS App 的 Info.plist 添加 `NSLocalNetworkUsageDescription`，并在 `NSBonjourServices` 数组中加入 `_proxymirror._tcp`。在 iOS 的权限提示中允许访问本地网络。[Apple 本地网络权限说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
3. 在 Mac 端的「设置 → General」启用局域网代理，选择 Mac 的 IPv4 并填写测试设备的 IPv4。启动监听后，打开「工具 → 应用内捕获配对」，将配对码传给调试应用。
4. 在调试代码中重用一个 `BridgeSession`，结束后通过「工具 → 停止应用内捕获」撤销配对。

```swift
let bridge = try BridgeSession(pairingCode: pairingCode, deviceName: "QA iPhone",
                               session: existingURLSession)
let (data, response) = try await bridge.data(for: request)
```

样例位于 `Tests/Fixtures/BridgeDemo/BridgeDemo.xcodeproj`。从 Xcode 打开，选择测试设备并运行。填入配对码和测试接口的 HTTPS URL，发送后在 Mac 流量列表检查来源为 `Bridge` 的记录。真机调试需配置本机 Xcode 的开发团队签名。

## 协议 v1

Bonjour 实例名和 256 位 AES 密钥组成一次监听有效的配对码。Mac 使用单独的 TCP 端口并仅接收已授权设备的 IPv4。每个连接传输一个记录，开头是 4 字节大端密文长度，随后是 AES-GCM 封装。加密内容依次为 4 字节大端 JSON 头长度、UTF-8 JSON、请求正文和响应正文。Mac 验证消息后返回一个字节。

请求完成后异步发送记录。授权头和 Cookie 默认脱敏。每侧正文最多发送 1 MiB，接收端继续应用 Mac 的抓包配额。v1 使用 HTTP 请求和响应语义，记录传给 URLSession 的请求与最终响应，支持普通 data task。流式请求正文、后台任务、WebSocket 和逐跳重定向记录不在 v1 范围内。
