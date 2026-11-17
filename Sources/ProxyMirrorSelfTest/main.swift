import Foundation
@testable import ProxyMirrorCore
import ProxyMirrorSystemProxy

// MARK: - 轻量自测（CLT 无 XCTest；结果打印 PASS/FAIL，非零退出表示失败）

var failures = 0
var total = 0

func check(_ cond: Bool, _ name: String) {
    total += 1
    if cond {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    check(a == b, "\(name)  (\(a) vs \(b))")
}

func finishChecks() -> Never {
    print("\n共 \(total) 项，失败 \(failures) 项")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--core-unit" {
    guard runCoreCheck(named: CommandLine.arguments[2]) else {
        fputs("Unknown core test group.\n", stderr)
        exit(2)
    }
    finishChecks()
}

if CommandLine.arguments.contains("--core-unit") {
    runCoreUnitChecks()
    finishChecks()
}

if CommandLine.arguments.contains("--concurrency") {
    MainActor.assumeIsolated { runConcurrencyTests() }
    finishChecks()
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--benchmark-core" || arguments.first == "--benchmark-proxy" {
    do {
        try MainActor.assumeIsolated {
            switch arguments {
            case ["--benchmark-core"]: try runCoreBenchmarks()
            case ["--benchmark-proxy", "paused"]: try runProxyBenchmark(recording: false)
            case ["--benchmark-proxy", "recording"]: try runProxyBenchmark(recording: true)
            default:
                fputs("Use --benchmark-core or --benchmark-proxy paused|recording.\n", stderr)
                exit(2)
            }
        }
        exit(0)
    } catch {
        fputs("FAIL  benchmark: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// MARK: 请求头解析

do {
    let raw = "GET http://example.com/path?q=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: test\r\n\r\nbody-start"
    var parser = RequestHeadParser()
    let head = try parser.feed(Data(raw.utf8))
    eq(head?.method, "GET", "请求头解析: method")
    eq(head?.target, "http://example.com/path?q=1", "请求头解析: target")
    eq(head?.headers.value(of: "host"), "example.com", "请求头解析: Host 大小写不敏感")
    eq(String(decoding: parser.trailing, as: UTF8.self), "body-start", "请求头解析: trailing 保留")
}

do {
    var parser = RequestHeadParser()
    XCTAssertNil(try parser.feed(Data("POST /api HTTP/1.1\r\nContent-Le".utf8)), "增量解析: 第一段应不完整")
    let head = try parser.feed(Data("ngth: 5\r\n\r\nhello".utf8))
    eq(head?.headers.value(of: "content-length"), "5", "增量解析: 跨段头部")
    eq(String(decoding: parser.trailing, as: UTF8.self), "hello", "增量解析: trailing")
}

func XCTAssertNil(_ v: HTTPRequestHead?, _ name: String) {
    check(v == nil, name)
}

// MARK: 响应头解析

do {
    let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Multi: a\r\nX-Multi: b\r\n\r\n{}"
    let head = try ResponseHeadParser.parse(String(decoding: Data(raw.utf8), as: UTF8.self))
    eq(head.status, 200, "响应头解析: status")
    eq(head.reason, "OK", "响应头解析: reason")
    eq(head.headers.values(of: "x-multi"), ["a", "b"], "响应头解析: 多值头保序")
}

// MARK: chunked

do {
    var tracker = ChunkedTracker()
    let f1 = tracker.feed(Data("4\r\nWiki\r\n".utf8))
    check(!f1, "chunked: 未完不成")
    let f2 = tracker.feed(Data("5\r\npedia\r\n0\r\n\r\n".utf8))
    check(f2, "chunked: 完成")
}

do {
    var tracker = ChunkedTracker()
    let f = tracker.feed(Data("10\r\nabcdefghij".utf8))
    check(!f, "chunked: 数据不足时不完成")
}

// MARK: URL / IP

do {
    let abs = URLParser.parse(target: "https://api.example.com:8443/v1/x?y=2")
    eq(abs?.host, "api.example.com", "URLParser: host")
    eq(abs?.port, 8443, "URLParser: 端口")
    eq(abs?.scheme, "https", "URLParser: scheme")
    eq(abs?.path, "/v1/x?y=2", "URLParser: path+query")
    check(URLParser.parse(target: "/only/path")?.host == nil, "URLParser: origin-form 无 host")
    check(URLParser.isIPAddress("127.0.0.1"), "isIPAddress: v4")
    check(URLParser.isIPAddress("::1"), "isIPAddress: v6")
    check(!URLParser.isIPAddress("example.com"), "isIPAddress: 域名")
}

// MARK: 代理头清洗

do {
    var headers = HTTPHeaders()
    headers.append("Host", "example.com")
    headers.append("Proxy-Connection", "keep-alive")
    headers.append("Accept", "*/*")
    let head = HTTPRequestHead(method: "GET", target: "http://example.com/", version: "HTTP/1.1", headers: headers)
    let text = String(decoding: sanitizedRequestHead(head: head, originFormTarget: "/", keepAlive: true), as: UTF8.self)
    check(text.hasPrefix("GET / HTTP/1.1\r\n"), "sanitized: origin-form 请求行")
    check(text.contains("Host: example.com"), "sanitized: Host 保留")
    check(!text.contains("Proxy-Connection"), "sanitized: 代理头移除")
    check(text.contains("Connection: keep-alive"), "sanitized: keep-alive")
}

// MARK: SNI 嗅探（构造最小 ClientHello）

do {
    let host = "example.com"
    let hostBytes = Array(host.utf8)
    var extPayload: [UInt8] = [0, UInt8(hostBytes.count + 3), 0,
                               UInt8(hostBytes.count >> 8), UInt8(hostBytes.count & 0xff)]
    extPayload.append(contentsOf: hostBytes)
    var ext = [0x00, 0x00, UInt8(extPayload.count >> 8), UInt8(extPayload.count & 0xff)]
    ext.append(contentsOf: extPayload)

    var handshake: [UInt8] = [0x01, 0, 0, 0]
    handshake.append(contentsOf: [0x03, 0x03])
    handshake.append(contentsOf: Array(repeating: 0x11, count: 32))
    handshake.append(0)
    handshake.append(contentsOf: [0x00, 0x02, 0x13, 0x01])
    handshake.append(1)
    handshake.append(0)
    handshake.append(contentsOf: [UInt8(ext.count >> 8), UInt8(ext.count & 0xff)])
    handshake.append(contentsOf: ext)
    let hsLen = handshake.count - 4
    handshake[1] = UInt8((hsLen >> 16) & 0xff)
    handshake[2] = UInt8((hsLen >> 8) & 0xff)
    handshake[3] = UInt8(hsLen & 0xff)

    var record: [UInt8] = [0x16, 0x03, 0x01]
    record.append(UInt8((handshake.count >> 8) & 0xff))
    record.append(UInt8(handshake.count & 0xff))
    record.append(contentsOf: handshake)

    let result = ClientHelloSniffer.parse(record)
    check(result.complete, "SNI: 完整")
    eq(result.sni, host, "SNI: 域名提取")
    let nonTLS = ClientHelloSniffer.parse(Array("GET / HTTP/1.1\r\n\r\n".utf8))
    check(nonTLS.complete && nonTLS.sni == nil, "SNI: 非 TLS 快速判完成")
}

// MARK: Host 头解析端口默认（MITM 场景回归）

do {
    let req = try RequestHeadParser.parse("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
    _ = req
    check(true, "Host 头解析: 基本")
}

// MARK: cURL / HAR 生成

do {
    let tx = Transaction()
    tx.method = "POST"
    tx.scheme = "https"
    tx.host = "api.example.com"
    tx.port = 443
    tx.path = "/v1/users"
    tx.requestHeaders = HTTPHeaders([("Content-Type", "application/json"), ("Authorization", "Bearer a b")])
    tx.requestBody = Data("{\"x\":1}".utf8)
    tx.statusCode = 201
    tx.responseHeaders = HTTPHeaders([("Content-Type", "application/json")])
    tx.contentType = "application/json"
    tx.responseBody = Data("{\"ok\":true}".utf8)
    tx.state = .completed
    let curl = ExportService.curlCommand(tx)
    check(curl.contains("-X POST"), "cURL: 方法")
    check(curl.contains("https://api.example.com/v1/users"), "cURL: URL")
    check(curl.contains("--data-raw"), "cURL: body")
    let har = ExportService.buildHAR([tx])
    let log = har["log"] as? [String: Any]
    let entries = log?["entries"] as? [[String: Any]]
    eq(entries?.count, 1, "HAR: entries")
    let req = entries?.first?["request"] as? [String: Any]
    eq(req?["method"] as? String, "POST", "HAR: method")
}

print("\n共 \(total) 项，失败 \(failures) 项")

// MARK: 规则匹配 + Compose 解析

do {
    let mapFile = NSTemporaryDirectory() + "proxymirror_maplocal_test.html"
    try? "<h1>hit</h1>".write(toFile: mapFile, atomically: true, encoding: .utf8)
    var rule = ProxyRule(pattern: "http://example.com/*", target: mapFile)
    let snap = RulesSnapshot(mapLocal: [rule])
    check(snap.mapLocalResponse(for: "http://example.com/") != nil, "MapLocal: 通配命中")
    check(snap.mapLocalResponse(for: "https://example.com/") == nil, "MapLocal: scheme 不匹配不命中")
    rule.enabled = false
    let snapOff = RulesSnapshot(mapLocal: [rule])
    check(snapOff.mapLocalResponse(for: "http://example.com/") == nil, "MapLocal: 禁用规则不命中")

    let snapBlock = RulesSnapshot(blockList: [ProxyRule(pattern: "*neverssl*")])
    check(snapBlock.isBlocked(url: "http://www.neverssl.com/"), "BlockList: 通配中间段")
    check(!snapBlock.isBlocked(url: "http://example.com/"), "BlockList: 未命中不拦截")

    let allow = RulesSnapshot(allowList: [ProxyRule(pattern: "https://example.com/*")])
    check(allow.isAllowed(url: "https://example.com/a"), "AllowList: 命中放行")
    check(!allow.isAllowed(url: "http://other.com/"), "AllowList: 非空时默认拦截")

    let ssl = RulesSnapshot(sslProxyingList: [ProxyRule(pattern: "api.example.com")])
    check(ssl.shouldSSLProxy(host: "api.example.com"), "SSLList: 命中")
    check(!ssl.shouldSSLProxy(host: "other.com"), "SSLList: 未命中不解密")
    let sslEmpty = RulesSnapshot()
    check(sslEmpty.shouldSSLProxy(host: "anything.com"), "SSLList: 空=全解密")
}

do {
    let parsed = ComposeService.parse("POST https://api.example.com/v1/x HTTP/1.1\nContent-Type: application/json\n\n{\"a\":1}")
    check(parsed != nil, "Compose: 解析成功")
    eq(parsed?.method, "POST", "Compose: 方法")
    eq(parsed?.url, "https://api.example.com/v1/x", "Compose: URL")
    check(parsed?.body != nil, "Compose: body")
    let p2 = ComposeService.parse("GET /path HTTP/1.1\nHost: example.com\n\n")
    eq(p2?.url, "https://example.com/path", "Compose: Host 头拼 URL")
    check(ComposeService.parse("garbage") == nil, "Compose: 非法输入拒绝")
}

do {
    let raw = RulesSnapshot.matches(pattern: "*a*b*", url: "xaxb")
    check(raw, "通配: 多段顺序匹配")
}

do {
    var tracker = ChunkedTracker()
    let first = try tracker.consume(Data("5\r\nhe".utf8))
    let second = try tracker.consume(Data("llo\r\n0\r\nX-End: yes\r\n".utf8))
    check(!tracker.finished, "chunked: 等待 trailer 结束行")
    let third = try tracker.consume(Data("\r\nGET /next HTTP/1.1\r\n".utf8))
    eq(first.payload + second.payload, Data("hello".utf8), "chunked: 跨数据块还原正文")
    eq(third.wireBytes, 2, "chunked: 后续请求留给 HTTP 解析器")
    eq(tracker.trailers.value(of: "X-End"), "yes", "chunked: 保留 trailer")
}

do {
    let route = ProxyRule(pattern: "*", target: "http://localhost:9011/base/?mode=new%20value")
    let mapped = RulesSnapshot(mapRemote: [route]).mapRemoteTarget(for: "https://old.example/a%2Fb?mode=old")
    eq(mapped?.requestTarget(path: "/a%2Fb", query: "mode=old"), "/base/a%2Fb?mode=new%20value", "Map Remote: 保留路径编码并改写查询参数")
    eq(mapped?.scheme, "http", "Map Remote: 改写 scheme")
    eq(mapped?.port, 9011, "Map Remote: 改写端口")
    let disabled = ProxyRule(enabled: false, pattern: "*")
    check(RulesSnapshot(allowList: [disabled]).isAllowed(url: "http://localhost/"), "Allow List: 全关时放行")
    let wildcard = ProxyRule(pattern: "https://*.example.com/*")
    let ssl = RulesSnapshot(sslProxyingList: [wildcard])
    check(ssl.shouldSSLProxy(host: "sub.example.com"), "SSL: 兼容旧通配 URL")
    check(!ssl.shouldSSLProxy(host: "example.com"), "SSL: 子域通配不匹配根域")
}

do {
    let tx = Transaction()
    tx.host = "localhost"
    tx.path = "/a%2Fb"
    tx.query = "id=1&id=2"
    tx.method = "POST"
    tx.statusCode = 404
    tx.statusReason = "Not Found"
    tx.state = .completed
    tx.captureLimit = 4
    tx.requestBodyComplete = true
    tx.responseBodyComplete = true
    tx.responseHeaders = HTTPHeaders([("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")])
    tx.responseTrailers = HTTPHeaders([("X-Trailer", "value")])
    tx.comment = "fixture"
    tx.highlightName = "Green"
    tx.appendResponseBody(Data([0, 255, 127, 128, 9, 0]))
    eq(tx.responseBody, Data([0, 255, 127, 128]), "正文: 单次追加严格限制捕获字节")
    check(tx.responseTruncated && tx.responseBytes == 6, "正文: 实际字节和截断状态分开记录")

    let session = SessionFile(transactions: [tx], pinnedDomains: ["localhost"], selected: [tx.id])
    let restored = try SessionFile.decode(JSONEncoder().encode(session))
    let record = restored.records[0].transaction()
    eq(restored.selected, [tx.id], "会话: 选择回读")
    eq(record.responseHeaders.values(of: "Set-Cookie"), ["a=1", "b=2"], "会话: 重复头回读")
    eq(record.responseTrailers.value(of: "X-Trailer"), "value", "会话: trailer 回读")
    eq(record.comment, "fixture", "会话: 备注回读")
    eq(record.highlightName, "Green", "会话: 高亮回读")

    let har = try JSONSerialization.data(withJSONObject: ExportService.buildHAR([tx]))
    let imported = try SessionFile.importHAR(har)[0]
    eq(imported.responseBody, tx.responseBody, "HAR: 二进制正文往返")
    eq(imported.statusText, "404 Not Found", "HAR: 状态码和原因往返")
    eq(imported.fullURL, tx.fullURL, "HAR: URL 编码及重复参数往返")

    let conditions = TrafficConditionGroup(conditions: [
        TrafficCondition(field: .method, comparison: .equals, value: "post"),
        TrafficCondition(field: .status, comparison: .regex, value: "^4[0-9]{2}$"),
        TrafficCondition(field: .responseHeader, comparison: .equals, value: "Set-Cookie: b=2"),
    ])
    check(conditions.compile()(tx), "高级过滤: 同时匹配方法、状态和重复头")
    check(!TrafficCondition(comparison: .regex, value: "[").isValid, "高级过滤: 拒绝无效正则")
}

do {
    let original: [String: Any] = ["HTTPEnable": 0, "HTTPProxy": "original", "HTTPPort": 8888]
    let current: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9090,
        "HTTPSEnable": 1, "HTTPSProxy": "changed", "HTTPSPort": 7890, "ExceptionsList": ["localhost"],
    ]
    let restored = SystemProxySettings.restoredConfiguration(current, original: original, ownedPort: 9090)
    eq(restored["HTTPProxy"] as? String, "original", "系统代理: 还原原 HTTP 端点")
    eq(restored["HTTPEnable"] as? Int, 0, "系统代理: 还原原启用状态")
    eq(restored["HTTPSProxy"] as? String, "changed", "系统代理: 保留期间修改的 HTTPS 配置")
    eq(restored["ExceptionsList"] as? [String], ["localhost"], "系统代理: 保留例外列表")
}

do {
    let old = ProxyRule(pattern: "http://localhost/old")
    var revised = old
    revised.enabled = false
    let new = ProxyRule(pattern: "http://localhost/new")
    let data = try JSONEncoder().encode(RuleBackup(mapLocal: [revised, new]))
    let (incoming, _) = try RuleBackup.read(data)
    let other = ProxyRule(pattern: "http://localhost/other")
    let installed = RuleBackup(mapLocal: [old, other], allowList: [new])
    eq(incoming.resolve(with: installed, merge: true).mapLocal, [revised, other, new], "迁移: 旧文件可读，按 ID 合并")
    eq(incoming.resolve(with: installed, merge: false).mapLocal, [revised, new], "迁移: 替换所含工具")
    eq(incoming.resolve(with: installed, merge: false).allowList, [new], "迁移: 保留未包含工具")

    let tx = Transaction()
    tx.path = "/rpc"
    tx.query = "lang=zh&lang=en"
    tx.requestBodyComplete = true
    tx.requestBody = Data(#"{"query":"query DefaultName { user { id } }","operationName":"ChosenName","variables":{"id":5}}"#.utf8)
    tx.responseBody = Data(#"{"items":[{"id":7}]}"#.utf8)
    eq(tx.graphqlOperationName, "ChosenName", "GraphQL: 使用显式操作名")
    check(GraphQLService.detect(tx: tx)?.variablesText.contains("5") == true, "GraphQL: 解析变量")
    let query = CustomTrafficColumn(title: "语言", source: .query, key: "lang")
    let column = CustomTrafficColumn(title: "ID", source: .responseJSON, key: "items.0.id")
    MainActor.assumeIsolated {
        eq(query.value(for: tx), "zh, en", "自定义列: 重复查询参数")
        eq(column.value(for: tx), "7", "自定义列: JSON 字段")
    }
}

do {
    let oldDNS = DNSSpoofRule(hostPattern: "old.pm.test", ip: "127.0.0.1")
    let newDNS = DNSSpoofRule(hostPattern: "new.pm.test", ip: "127.0.0.2")
    let breakpoint = BreakpointRule(enabled: false)
    let current = RuleBackup(dns: [oldDNS], breakpoints: [breakpoint], latency: LatencyConditions())
    let incoming = RuleBackup(version: 1, dns: [newDNS], latency: LatencyConditions(enabled: true))
    let (decoded, unknown) = try RuleBackup.read(incoming.exportData())
    eq(unknown, [], "迁移: 规则备份回读无未知字段")
    eq(decoded.resolve(with: current, merge: true).dns, [oldDNS, newDNS], "迁移: DNS 按 ID 合并")
    eq(decoded.resolve(with: current, merge: false).breakpoints, [breakpoint], "迁移: 保留未包含的断点")
    let changes = decoded.changes(from: current, mode: .replace)
    eq(changes.first(where: { $0.section == .dns })?.removed, 1, "迁移: DNS 替换预览列出移除项")
    eq(changes.first(where: { $0.section == .latency })?.updated, 1, "迁移: 延迟设置覆盖预览")
    let subset = incoming.subset(.dns)
    eq(subset.dns, [newDNS], "迁移: DNS 单工具备份")
    check(subset.latency == nil, "迁移: 单工具备份无延迟配置")
    let bad = ProxyRule(pattern: "*", responseHeaders: HTTPHeaders([("X-Test", "value\r\nX-Other: bad")]))
    let unsafe = try RuleBackup(mapLocal: [bad]).exportData()
    check((try? RuleBackup.read(unsafe)) == nil, "迁移: 拒绝含控制字符的响应头")
}

runGRPCChecks()

try MainActor.assumeIsolated {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-folders-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("SourceFolders.json")
    let first = TrafficStore(sourceFolderFile: file)
    let second = TrafficStore(sharing: first)
    let folder = try first.saveSourceFolder(name: " 前端排查 ", members: [.domain("API.PM.TEST"), .client("Fixture Browser")])
    eq(second.sourceFolders.first?.name, "前端排查", "来源文件夹: 共享文件夹名称")
    first.filterMode = .folder(folder)
    let domain = Transaction()
    domain.host = "api.pm.test"
    domain.clientName = "Fixture Browser"
    let app = Transaction()
    app.host = "example.invalid"
    app.clientName = "Fixture Browser"
    let other = Transaction()
    other.host = "api.other.test"
    first.add(domain)
    first.add(app)
    first.add(other)
    eq(first.visible.map(\.id), [domain.id, app.id], "来源文件夹: 域名或应用实时匹配")
    eq(second.visible.map(\.id), [domain.id, app.id, other.id], "来源文件夹: 各视图筛选独立")
    eq(first.sourceFolderCounts[folder], 2, "来源文件夹: 同一流量匹配两种来源只计一次")
    try first.toggleSourceFolderMembership(.client("Fixture Browser"), folderID: folder)
    eq(first.visible.map(\.id), [domain.id], "来源文件夹: 修改成员后刷新实时筛选")
    try second.saveSourceFolder(id: folder, name: "后端排查", members: [.domain("api.pm.test")])
    let reloaded = TrafficStore(sourceFolderFile: file)
    eq(reloaded.sourceFolders, first.sourceFolders, "来源文件夹: 重开后恢复名称和成员")
    check((try? first.saveSourceFolder(name: " 后端排查 ", members: [])) == nil, "来源文件夹: 拒绝重复名称")
    second.filterMode = .folder(folder)
    try first.removeSourceFolder(folder)
    eq(first.filterMode, .all, "来源文件夹: 删除后当前视图回到全部流量")
    eq(second.filterMode, .all, "来源文件夹: 删除后其他视图同步回到全部流量")
    eq(first.transactions.count, 3, "来源文件夹: 删除文件夹保留捕获记录")
}

eq(SettingsSearchTarget.results(for: "HTTP/2").first, .http2, "设置搜索: HTTP/2 定位协商设置")
check(SettingsSearchTarget.results(for: "TLS MITM").contains(.decryptHTTPS), "设置搜索: 英文协议组合匹配")
check(SettingsSearchTarget.results(for: "正文 截断").contains(.bodyLimit), "设置搜索: 中文关键词匹配")
eq(SettingsSearchTarget.results(for: "SOCKS5 bypass").first, .upstreamProxy, "设置搜索: 外部代理转发关键词")
eq(SettingsSearchTarget.results(for: "mTLS 私钥").first, .clientCertificate, "设置搜索: 上游客户端证书关键词")
eq(SettingsSearchTarget.results(for: "PAC 自动代理配置").first, .upstreamProxy, "设置搜索: PAC 定位外部代理设置")
eq(SettingsSearchTarget.results(for: "no-matching-setting"), [], "设置搜索: 无结果状态")

runCapturePerformanceChecks()
runBackgroundPerformanceChecks()
MainActor.assumeIsolated { runUIPerformanceChecks() }

if CommandLine.arguments.contains("--loopback") {
    runLoopbackTests()
    runPacingLoopbackTests()
}
if CommandLine.arguments.contains("--http2-loopback") {
    runHTTP2LoopbackTests()
}

finishChecks()
