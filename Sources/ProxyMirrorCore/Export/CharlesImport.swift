import CoreFoundation
import Foundation

enum CharlesImport {
    static let sessionExtensions = ["xml", "chlsx", "chlsj", "chls", "chlz"]
    private static let sessionLimit = 128 * 1024 * 1024

    struct ImportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Session {
        let records: [Transaction]
        let skipped: Int
    }

    static func readSession(_ url: URL) throws -> Session {
        let data = try contents(of: url, limit: sessionLimit)
        let binary = data.prefix(2) == Data([0xac, 0xed]) || data.prefix(2) == Data([0x1f, 0x8b]) || data.prefix(2) == Data([0x50, 0x4b])
        if binary, ["chls", "chlz"].contains(url.pathExtension.lowercased()) {
            return Session(records: try SessionFile.importHAR(CharlesSessionConverter.convertToHAR(url)), skipped: 0)
        }
        return try readSession(data)
    }

    static func readSession(_ data: Data) throws -> Session {
        guard data.count <= sessionLimit else { throw ImportError("Charles 会话超过 128 MiB。请拆分后再导入。") }
        let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        if bytes.first(where: { ![0x20, 0x09, 0x0a, 0x0d].contains($0) }) == 0x5b {
            return try readJSONSession(Data(bytes))
        }
        let root: Element
        do {
            root = try parseXML(data)
        } catch {
            // Charles's native binary formats can be converted by its File > Export command.
            if data.prefix(2) == Data([0xac, 0xed]) || data.prefix(2) == Data([0x1f, 0x8b])
                || data.prefix(2) == Data([0x50, 0x4b]) {
                throw ImportError("请先在 Charles 中将原生会话导出为 XML 或 JSON Session。")
            }
            throw error
        }
        guard root.name == "charles-session" else { throw ImportError("请选择 Charles XML 会话导出文件。") }
        return collect(root.children("transaction")) { node, index in
            let a = node.attributes
            let request = node.child("request")
            let response = node.child("response")
            let timing = SessionTiming(start: epoch(a["startTimeMillis"]), response: epoch(a["responseTimeMillis"]),
                                       end: epoch(a["endTimeMillis"]), connected: epoch(a["requestBeginTimeMillis"]))
            return try transaction(
                index: index, method: a["method"], scheme: a["protocol"], host: a["host"],
                port: validPort(a["actualPort"]) ?? validPort(a["port"]), path: a["path"], query: a["query"],
                version: a["protocolVersion"], request: xmlMessage(request), response: xmlMessage(response),
                status: response?.attributes["status"].flatMap(Int.init), timing: timing,
                clientAddress: a["clientAddress"], remoteAddress: a["remoteAddress"],
                error: failure(a["status"], message: a["errorMessage"] ?? node.child("errorMessage")?.text),
                comment: a["notes"] ?? node.child("notes")?.text)
        }
    }

    private struct JSONExchange: Decodable {
        var method, scheme, host, path, query, protocolVersion: String?
        var port, actualPort: Int?
        var clientAddress, remoteAddress, status, errorMessage, notes: String?
        var request, response: JSONMessage?
        var times: Times?

        struct Times: Decodable {
            var start, response, responseBegin, end, requestBegin: String?
        }
    }

    private struct JSONMessage: Decodable {
        var status: Int?
        var header: Header?
        var body: Body?
        var mimeType, charset: String?
        var sizes: Sizes?
        var bodySize: Int?

        struct Sizes: Decodable { var body: Int? }

        struct Header: Decodable {
            var firstLine: String?
            var headers: HTTPHeaders?
        }

        struct Body: Decodable {
            var text, encoded, charset: String?
            var decoded: Bool?
            var encoding: String?
        }

        func message() throws -> Message {
            var bytes = Data()
            if let base64 = body?.encoded {
                guard body?.encoding == nil || body?.encoding?.lowercased() == "base64" else {
                    throw ImportError("Charles JSON 正文使用无法读取的编码。")
                }
                bytes = try binaryBody(base64)
            }
            else if let text = body?.text { bytes = try textBody(text, charset: body?.charset ?? charset) }
            var headers = header?.headers ?? HTTPHeaders()
            let decoded = body?.decoded == true
            if decoded { headers.remove(name: "Content-Encoding") }
            return Message(headers: headers, firstLine: header?.firstLine, body: bytes,
                           bodySize: decoded ? nil : (sizes?.body ?? bodySize), mimeType: mimeType)
        }
    }

    private static func readJSONSession(_ data: Data) throws -> Session {
        let entries = try JSONDecoder().decode([JSONExchange].self, from: data)
        let dates = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ text: String?) -> Date? {
            text.flatMap { fractional.date(from: $0) ?? dates.date(from: $0) }
        }
        return collect(entries) { entry, index in
            try transaction(
                index: index, method: entry.method, scheme: entry.scheme, host: entry.host,
                port: [entry.actualPort, entry.port].compactMap { $0 }.first(where: { (1...65535).contains($0) }),
                path: entry.path, query: entry.query, version: entry.protocolVersion,
                request: entry.request?.message(), response: entry.response?.message(), status: entry.response?.status,
                timing: SessionTiming(start: date(entry.times?.start), response: date(entry.times?.responseBegin ?? entry.times?.response),
                                      end: date(entry.times?.end), connected: date(entry.times?.requestBegin)),
                clientAddress: entry.clientAddress, remoteAddress: entry.remoteAddress,
                error: failure(entry.status, message: entry.errorMessage),
                comment: entry.notes)
        }
    }

    private static func collect<Entry>(_ entries: [Entry], convert: (Entry, Int) throws -> Transaction?) -> Session {
        var records: [Transaction] = []
        for entry in entries {
            if let transaction = try? convert(entry, records.count + 1) { records.append(transaction) }
        }
        return Session(records: records, skipped: entries.count - records.count)
    }

    private struct Message {
        var headers: HTTPHeaders
        var firstLine: String?
        var body: Data
        var bodySize: Int?
        var mimeType: String?
    }

    private struct SessionTiming {
        var start, response, end, connected: Date?
    }

    private static func transaction(
        index: Int, method: String?, scheme: String?, host: String?, port: Int?, path: String?, query: String?,
        version: String?, request: Message?, response: Message?, status: Int?, timing: SessionTiming,
        clientAddress: String?, remoteAddress: String?, error: String?, comment: String?
    ) -> Transaction? {
        guard let host, !host.isEmpty, let method, isHeaderName(method), let scheme = scheme?.lowercased(),
              ["http", "https"].contains(scheme) || method == "CONNECT", let request else { return nil }
        let responseLine = response?.firstLine?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
        let requestLine = request.firstLine?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
        let start = timing.start ?? timing.response ?? timing.end ?? Date(timeIntervalSince1970: 0)
        let tx = Transaction(startedAt: start)
        tx.seq = index
        tx.method = method
        tx.scheme = scheme
        tx.host = URLParser.bareHost(host)
        tx.port = port ?? (scheme == "https" || method == "CONNECT" ? 443 : 80)
        let target = path.flatMap { $0.isEmpty ? nil : $0 } ?? (requestLine.count == 3 ? requestLine[1] : "/")
        let targetPath = URLParser.parse(target: target)?.path ?? target
        (tx.path, tx.query) = splitQueryPath(targetPath)
        if !tx.path.hasPrefix("/") && tx.path != "*" { tx.path = "/" + tx.path }
        if let query, !query.isEmpty { tx.query = query }
        tx.isTunnel = method == "CONNECT"
        tx.isTLSIntercepted = !tx.isTunnel && scheme == "https"
        tx.statusCode = status ?? (responseLine.count >= 2 ? Int(responseLine[1]) : nil) ?? 0
        tx.statusReason = responseLine.count == 3 ? responseLine[2] : ""
        tx.isWebSocket = tx.statusCode == 101
        let httpVersion = version.map { $0.hasPrefix("HTTP/") ? $0 : "HTTP/\($0)" } ?? "HTTP/1.1"
        tx.requestVersion = requestLine.count == 3 ? requestLine[2] : httpVersion
        tx.responseVersion = responseLine.first ?? httpVersion
        tx.requestHeaders = request.headers
        tx.responseHeaders = response?.headers ?? HTTPHeaders()
        tx.requestBody = request.body
        tx.responseBody = response?.body ?? Data()
        tx.requestBytes = max(request.bodySize ?? 0, tx.requestBody.count)
        tx.responseBytes = max(response?.bodySize ?? 0, tx.responseBody.count)
        tx.requestTruncated = tx.requestBody.count < tx.requestBytes
        tx.responseTruncated = tx.responseBody.count < tx.responseBytes
        tx.requestBodyComplete = true
        tx.errorText = error.flatMap { $0.isEmpty ? nil : $0 }
        tx.state = tx.statusCode > 0 && tx.errorText == nil ? .completed : .failed
        tx.responseBodyComplete = tx.state == .completed
        tx.contentType = tx.responseHeaders.value(of: "Content-Type") ?? response?.mimeType ?? ""
        tx.clientAddress = clientAddress
        tx.resolvedAddress = remoteAddress
        tx.duration = max(0, (timing.end ?? timing.response ?? start).timeIntervalSince(start))
        tx.tConnected = timing.connected
        tx.tHeaderAt = timing.response
        tx.comment = comment ?? ""
        return tx
    }

    private static func xmlMessage(_ node: Element?) throws -> Message? {
        guard let node else { return nil }
        let header = node.child("headers")
        let fields = header?.children("header").compactMap { field -> (String, String)? in
            guard let name = field.child("name")?.text, let value = field.child("value")?.text else { return nil }
            return (name, value)
        } ?? []
        var bytes = Data()
        if let body = node.child("body") {
            switch body.attributes["encoding"]?.lowercased() {
            case "base64": bytes = try binaryBody(body.text)
            case nil, "", "text": bytes = try textBody(body.text, charset: node.attributes["charset"])
            default: throw ImportError("Charles XML 正文使用无法读取的编码。")
            }
        }
        var headers = HTTPHeaders(fields)
        let decoded = node.child("body")?.attributes["decoded"] == "true"
        if decoded { headers.remove(name: "Content-Encoding") }
        return Message(headers: headers, firstLine: header?.child("first-line")?.text, body: bytes,
                       bodySize: decoded ? nil : node.attributes["body"].flatMap(Int.init),
                       mimeType: node.attributes["mime-type"])
    }

    private static func binaryBody(_ string: String) throws -> Data {
        let unwrapped = string.utf8.filter { ![0x20, 0x09, 0x0a, 0x0d].contains($0) }
        guard let data = Data(base64Encoded: Data(unwrapped)) else { throw ImportError("Charles 正文的 Base64 无效。") }
        return data
    }

    private static func textBody(_ text: String, charset: String?) throws -> Data {
        guard let charset, !charset.isEmpty else { return Data(text.utf8) }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        guard cfEncoding != kCFStringEncodingInvalidId, let bytes = text.data(using: encoding) else {
            throw ImportError("Charles 正文使用无法读取的字符编码。")
        }
        return bytes
    }

    private static func validPort(_ raw: String?) -> Int? {
        guard let port = raw.flatMap(Int.init), (1...65535).contains(port) else { return nil }
        return port
    }

    private static func failure(_ status: String?, message: String?) -> String? {
        if let message, !message.isEmpty { return message }
        return status.flatMap { $0.isEmpty || $0 == "COMPLETE" ? nil : "Charles · \($0)" }
    }

    private static func epoch(_ raw: String?) -> Date? {
        guard let milliseconds = raw.flatMap(Int64.init), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func isHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }

    private static func contents(of url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportError("请选择普通文件。") }
        guard values.fileSize.map({ $0 <= limit }) == true else { throw ImportError("Charles 导出文件超出大小限制。") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ImportError("Charles 导出文件超出大小限制。") }
        return data
    }

    private static func parseXML(_ data: Data) throws -> Element {
        let delegate = TreeParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.externalEntityResolvingPolicy = .never
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else {
            throw ImportError("无法读取 Charles XML。请选择 Charles 导出的会话或规则文件。")
        }
        return root
    }

    private final class Element {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Element] = []

        init(_ name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func child(_ name: String) -> Element? { children.first { $0.name == name } }
        func children(_ name: String) -> [Element] { children.filter { $0.name == name } }
        func value(_ name: String) -> String? {
            child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func flag(_ name: String, default defaultValue: Bool = true) -> Bool {
            guard let value = value(name) else { return defaultValue }
            return value == "true" || value == "1"
        }
    }

    private final class TreeParser: NSObject, XMLParserDelegate {
        var root: Element?
        private var stack: [Element] = []
        private var nodeCount = 0
        private var textBytes = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            nodeCount += 1
            guard nodeCount <= 1_000_000, stack.count < 32 else { parser.abortParsing(); return }
            let element = Element(elementName, attributes: attributes)
            if let parent = stack.last { parent.children.append(element) }
            else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBytes += string.utf8.count
            guard textBytes <= CharlesImport.sessionLimit else { parser.abortParsing(); return }
            stack.last?.text.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            parser.abortParsing()
        }
    }
}

extension CharlesImport {
    struct Rules {
        var backup = RuleBackup(version: 1)
        var skipped: [String] = []
        var notes: [String] = []

        var counts: (rewrite: Int, mapLocal: Int, blockList: Int) {
            (backup.rewrite?.reduce(0) { $0 + $1.rules.count } ?? 0,
             backup.mapLocal?.count ?? 0, backup.blockList?.count ?? 0)
        }

        var hasRules: Bool { counts.rewrite + counts.mapLocal + counts.blockList > 0 }
    }

    static func readRules(_ url: URL) throws -> Rules {
        try readRules(contents(of: url, limit: RuleBackup.fileLimit))
    }

    static func readRules(_ data: Data) throws -> Rules {
        guard data.count <= RuleBackup.fileLimit else { throw ImportError("Charles 规则超过 2 MiB。请按工具拆分。") }
        let root = try parseXML(data)
        var result = Rules()
        let tools: [Element]
        if root.name == "charles-export" {
            let container = root.child("toolConfiguration")?.child("configs") ?? root
            let entries = container.children("entry")
            tools = entries.isEmpty ? container.children : entries.compactMap { $0.children.dropFirst().first }
        } else {
            tools = [root]
        }

        var recognized = false
        for tool in tools {
            switch tool.name {
            case "rewriteSet-array", "rewriteSet", "rewrite":
                recognized = true
                readRewrite(tool, into: &result)
            case "mapLocal", "mapLocalMapping-array":
                recognized = true
                readMapLocal(tool, into: &result)
            case "blacklist", "blockList", "blocklist", "locationMatch-array":
                recognized = true
                readBlockList(tool, into: &result)
            default:
                if root.name == "charles-export" {
                    result.skipped.append("工具 \(tool.name)")
                }
            }
        }
        guard recognized else { throw ImportError("请选择 Charles 的 Rewrite、Map Local、Block List 或设置 XML 导出。") }
        return result
    }

    private struct Location {
        let label: String
        let regex: String
    }

    private static func readRewrite(_ tool: Element, into result: inout Rules) {
        let groups = tool.name == "rewriteSet" ? [tool] : (tool.child("sets") ?? tool).children("rewriteSet")
        var migrated: [RewriteRuleSet] = []
        for (groupIndex, group) in groups.enumerated() {
            let title = "Rewrite \(groupIndex + 1)"
            let name = group.value("name").flatMap { $0.isEmpty ? nil : $0 } ?? title
            let paths = group.child("hosts")?.child("locationPatterns")?.children("locationMatch") ?? []
            var locations: [Location] = []
            for (index, match) in paths.enumerated() where match.flag("enabled") {
                if let location = parseLocation(match.child("location")) {
                    locations.append(location)
                } else {
                    result.skipped.append("\(title) 的位置 \(index + 1)：匹配条件无法转换")
                }
            }
            let nodes = group.child("rules")?.children("rewriteRule") ?? []
            guard !locations.isEmpty || paths.isEmpty else {
                if !nodes.isEmpty { result.skipped.append("\(title)：没有可迁移的启用位置，共 \(nodes.count) 条规则") }
                continue
            }
            let alternatives = locations.map(\.regex)
            let regex = "\\A(?:\(alternatives.isEmpty ? "https?://[^#]+" : alternatives.joined(separator: "|")))\\z"
            guard regex.utf8.count <= 8192, URLRule.regexCache(regex) != nil else {
                result.skipped.append("\(title)：位置匹配表达式过长或无效")
                continue
            }

            var rules: [RewriteRule] = []
            for (index, node) in nodes.enumerated() {
                let actions = rewriteActions(node)
                guard !actions.isEmpty else {
                    result.skipped.append("\(title) 的规则 \(index + 1)：不支持的 Rewrite 操作或匹配条件")
                    continue
                }
                let label = actions.map(\.summary).joined(separator: " / ")
                let matcher = URLRule(name: label, includeSubpaths: false, matchMode: .regex, regexPattern: regex)
                rules.append(RewriteRule(enabled: node.flag("active"), rule: matcher, actions: actions))
            }
            if !rules.isEmpty {
                migrated.append(RewriteRuleSet(name: name, enabled: tool.flag("toolEnabled") && group.flag("active"),
                                               rules: rules))
            }
        }
        if !migrated.isEmpty {
            result.backup.rewrite = (result.backup.rewrite ?? []) + migrated
        }
    }

    private static func rewriteActions(_ node: Element) -> [RewriteAction] {
        let flags = ["matchHeaderRegex", "matchValueRegex", "newHeaderRegex", "newValueRegex", "caseSensitive"]
        guard !flags.contains(where: { node.flag($0, default: false) }),
              node.child("matchValue")?.text.isEmpty != false else { return [] }
        let oldName = node.value("matchHeader") ?? ""
        let newName = node.value("newHeader") ?? ""
        let value = node.child("newValue")?.text ?? ""
        let operation: RewriteAction.HeaderOp
        let name: String
        switch node.value("ruleType") {
        case "1":
            (operation, name) = (.add, newName)
        case "2":
            (operation, name) = (.remove, oldName)
        case "3":
            guard newName.isEmpty || newName.caseInsensitiveCompare(oldName) == .orderedSame,
                  !value.isEmpty else { return [] }
            (operation, name) = (.replaceExisting, oldName)
        default:
            return []
        }
        let protected = ["host", "connection", "proxy-connection", "upgrade", "expect",
                         "content-length", "transfer-encoding", "trailer", "content-encoding"]
        guard isHeaderName(name), !protected.contains(name.lowercased()),
              !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else { return [] }
        var actions: [RewriteAction] = []
        if node.flag("matchRequest", default: false) {
            actions.append(.requestHeader(op: operation, name: name, value: value))
        }
        if node.flag("matchResponse", default: false) {
            actions.append(.responseHeader(op: operation, name: name, value: value))
        }
        return actions
    }

    private static func readMapLocal(_ tool: Element, into result: inout Rules) {
        var migrated: [ProxyRule] = []
        let nodes = (tool.child("mappings") ?? tool).children("mapLocalMapping")
        for (index, node) in nodes.enumerated() {
            let title = "Map Local \(index + 1)"
            guard let location = parseLocation(node.child("sourceLocation"), caseSensitive: node.flag("caseSensitive"),
                                               ignoreQuery: true),
                  let target = node.value("dest"), target.hasPrefix("/"),
                  !target.hasSuffix("/"), !target.contains("\u{0}") else {
                result.skipped.append("\(title)：匹配条件或本地文件路径无法转换")
                continue
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else {
                result.skipped.append("\(title)：目录映射无法等价转换")
                continue
            }
            let enabled = tool.flag("toolEnabled") && node.flag("enabled")
            let readable = exists && FileManager.default.isReadableFile(atPath: target)
            migrated.append(ProxyRule(enabled: enabled && readable, pattern: location.label, target: target,
                                      comment: "Charles Map Local", urlRegex: "\\A\(location.regex)\\z"))
            if enabled && !readable {
                result.notes.append("\(title)：目标文件在此 Mac 上不可读取，已关闭。\n\(target)")
            }
        }
        if !migrated.isEmpty {
            result.backup.mapLocal = (result.backup.mapLocal ?? []) + migrated
        }
    }

    private static func readBlockList(_ tool: Element, into result: inout Rules) {
        var migrated: [ProxyRule] = []
        let nodes = (tool.child("locations")?.child("locationPatterns") ?? tool).children("locationMatch")
        for (index, node) in nodes.enumerated() {
            let title = "Block List \(index + 1)"
            guard tool.value("action").map({ $0 == "0" }) ?? true else {
                result.skipped.append("\(title)：连接终止动作无法转换为 HTTP 403")
                continue
            }
            guard let location = parseLocation(node.child("location")) else {
                result.skipped.append("\(title)：匹配条件无法转换")
                continue
            }
            migrated.append(ProxyRule(enabled: tool.flag("toolEnabled") && node.flag("enabled"), pattern: location.label,
                                      comment: "Charles Block List", urlRegex: "\\A\(location.regex)\\z"))
        }
        if !migrated.isEmpty {
            result.backup.blockList = (result.backup.blockList ?? []) + migrated
        }
    }

    private static func parseLocation(_ node: Element?, caseSensitive: Bool = true,
                                      ignoreQuery: Bool = false) -> Location? {
        guard let node, node.children.allSatisfy({ ["protocol", "host", "port", "path", "query"].contains($0.name) })
        else { return nil }
        let scheme = node.value("protocol")?.lowercased() ?? ""
        let host = node.value("host").flatMap { $0.isEmpty ? nil : $0 } ?? "*"
        let rawPort = node.value("port") ?? ""
        let rawPath = node.value("path") ?? ""
        var path = rawPath
        if path.hasSuffix("/$") { path.removeLast() }
        let query = ignoreQuery ? "" : (node.value("query") ?? "")
        guard ["", "*", "http", "https"].contains(scheme),
              rawPort.isEmpty || rawPort == "*" || validPort(rawPort) != nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@").union(.whitespacesAndNewlines)) == nil,
              host.firstIndex(of: ":") == nil || URLParser.isIPAddress(URLParser.bareHost(host)),
              path.isEmpty || path == "*" || path.hasPrefix("/"),
              !path.contains("#"), !path.contains("?"), !query.contains("#"),
              (host + path + query).utf8.count <= 1024,
              (host + path + query).filter({ $0 == "*" }).count <= 12 else { return nil }

        let displayScheme = scheme.isEmpty ? "*" : scheme
        let displayPort = rawPort.isEmpty ? "" : ":" + rawPort
        let urlHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let displayPath = path.isEmpty ? "/*" : path
        let displayQuery = query.isEmpty ? "" : "?" + query
        let label = "\(displayScheme)://\(urlHost)\(displayPort)\(displayPath)\(displayQuery)"

        let hostPattern = host == "*" ? "(?:\\[[^\\]]+\\]|[^/:?#]+)" : glob(urlHost, wildcard: "[^/:?#]*")
        let schemes = ["http", "https"].filter { scheme.isEmpty || scheme == "*" || $0 == scheme }
        let origins = schemes.map { item in
            let port: String
            if let number = validPort(rawPort) {
                port = number == (item == "https" ? 443 : 80) ? "" : ":\(number)"
            } else {
                port = "(?::[0-9]{1,5})?"
            }
            return "(?i:\(item)://\(hostPattern))\(port)"
        }
        let pathPattern = path.isEmpty || path == "*" ? "(?:/[^?#]*)?" : glob(path, wildcard: "[^?#]*")
        // The shared URL regex cache defaults to case-insensitive matching.
        let pathMatch = caseSensitive ? "(?-i:\(pathPattern))" : pathPattern
        let queryMatch = query.isEmpty ? "(?:\\?[^#]*)?" : "(?-i:\\?" + glob(query, wildcard: "[^#]*") + ")"
        return Location(label: label, regex: "(?:\(origins.joined(separator: "|")))\(pathMatch)\(queryMatch)")
    }

    private static func glob(_ pattern: String, wildcard: String) -> String {
        pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: wildcard)
    }
}
