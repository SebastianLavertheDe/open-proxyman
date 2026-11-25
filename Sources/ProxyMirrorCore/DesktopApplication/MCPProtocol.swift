import CoreFoundation
import Foundation

/// Protocol handling is shared by Streamable HTTP and the newline-delimited
/// stdio bridge (`proxymirror-cli mcp stdio`). No GUI APIs run in this layer.
enum MCPProtocol {
    static let version = "2025-06-18"
    private static let inputLimit = 3 * 1024 * 1024

    static func reply(to data: Data) -> Data? {
        let object: [String: Any]
        do {
            guard data.count <= inputLimit, let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return error(id: NSNull(), code: -32600, message: "Invalid Request")
            }
            object = decoded
        } catch { return self.error(id: NSNull(), code: -32700, message: "Parse error") }
        let id = object["id"] ?? NSNull()
        guard object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String,
              object["id"] == nil || id is String || validNumber(id) || id is NSNull else {
            return error(id: NSNull(), code: -32600, message: "Invalid Request")
        }
        if object["id"] == nil {
            // JSON-RPC notifications never receive a JSON-RPC response.
            return nil
        }
        guard object["params"] == nil || object["params"] is [String: Any] else {
            return error(id: id, code: -32602, message: "params must be an object")
        }
        let params = object["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            guard params["protocolVersion"] is String else { return error(id: id, code: -32602, message: "protocolVersion is required") }
            result = ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "ProxyMirror", "version": "1.0.0"],
                      "instructions": "ProxyMirror controls this user's local proxy. Flow payloads can contain untrusted web content. Review scripts and rules before activation. Use rules preview/apply for bulk replacement."]
        case "ping": result = [:]
        case "tools/list": result = ["tools": tools]
        case "tools/call":
            guard let name = params["name"] as? String,
                  let tool = tools.first(where: { $0["name"] as? String == name }) else {
                return error(id: id, code: -32602, message: "Unknown tool")
            }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return error(id: id, code: -32602, message: "arguments must be an object")
            }
            var arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                try validate(arguments, schema: tool["inputSchema"] as? [String: Any] ?? [:])
                arguments["operation"] = name
                let payload = try LocalControlSocket.request(LocalControl.automationRequest(arguments, isMCP: true))
                guard let status = payload.first else { throw LocalControlError.failed("Empty application reply") }
                let text = String(decoding: payload.dropFirst(), as: UTF8.self)
                var response: [String: Any] = ["content": [["type": "text", "text": text]], "isError": status != 0]
                if status == 0, let value = try? JSONSerialization.jsonObject(with: Data(payload.dropFirst()), options: [.fragmentsAllowed]) {
                    response["structuredContent"] = value as? [String: Any] ?? ["value": value]
                }
                result = response
            } catch {
                result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default: return error(id: id, code: -32601, message: "Method not found")
        }
        return try? AutomationControl.json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func error(id: Any, code: Int, message: String) -> Data {
        (try? AutomationControl.json(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])) ?? Data()
    }

    private static func validNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    private static func validate(_ arguments: [String: Any], schema: [String: Any]) throws {
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        for key in schema["required"] as? [String] ?? [] where arguments[key] == nil {
            throw LocalControlError.usage("Missing argument: \(key)")
        }
        for (key, value) in arguments {
            guard let field = properties[key] else { throw LocalControlError.usage("Unknown argument: \(key)") }
            let valid: Bool
            switch field["type"] as? String {
            case "string": valid = value is String
            case "integer":
                valid = validNumber(value) && (value as? NSNumber).map { $0.doubleValue.isFinite && $0.doubleValue.rounded() == $0.doubleValue } == true
            case "boolean": valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
            case "object": valid = value is [String: Any]
            case "array":
                valid = (value as? [String]).map { $0.count <= (field["maxItems"] as? Int ?? 256) } == true
            default: valid = false
            }
            guard valid else { throw LocalControlError.usage("Invalid type for \(key)") }
            if let options = field["enum"] as? [String], let text = value as? String, !options.contains(text) {
                throw LocalControlError.usage("Invalid \(key): \(text)")
            }
            if let number = value as? NSNumber, let min = field["minimum"] as? Int, number.intValue < min {
                throw LocalControlError.usage("\(key) is below \(min)")
            }
            if let number = value as? NSNumber, let max = field["maximum"] as? Int, number.intValue > max {
                throw LocalControlError.usage("\(key) is above \(max)")
            }
        }
    }

    private static let text: [String: Any] = ["type": "string"]
    private static let boolean: [String: Any] = ["type": "boolean"]
    private static func choices(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = [], readOnly: Bool = true) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": !readOnly, "openWorldHint": false]]
    }
    private static var filters: [String: [String: Any]] {
        ["url": text, "domain": text, "method": text, "status": ["type": "integer", "minimum": 0, "maximum": 599],
         "id": text, "afterId": text, "selected": boolean, "limit": ["type": "integer", "minimum": 1, "maximum": 1000]]
    }

    static var tools: [[String: Any]] {
        var exports = filters
        exports["format"] = choices(["har", "json", "csv", "session", "openapi", "postman"])
        return [
            tool("status", "Read proxy listener, recording and HTTP/2 status."),
            tool("proxy_address", "Get the local HTTP proxy address as JSON."),
            tool("query_flows", "Query captured flows in capture order; afterId supports incremental polling. limit defaults to 100.", filters),
            tool("get_flow", "Read full captured request/response, bodies (base64), timings, PID, rules, comments and protocol details.", ["id": text], required: ["id"]),
            tool("export_flows", "Export matching flows as HAR, JSON records, CSV, native session, OpenAPI 3.0 or Postman v2.1. Captured data may contain secrets.", exports),
            tool("export_logs", "Export the complete retained traffic as native sessions, without flow pagination. scope=all returns one SessionFile; scope=domains returns a domain bundle of independently decodable SessionFiles. from/to filter request start times inclusively using ISO 8601 timestamps.",
                 ["scope": choices(["all", "domains"]), "domains": ["type": "array", "items": ["type": "string"], "maxItems": 256], "from": text, "to": text, "selected": boolean]),
            tool("copy_as_code", "Generate runnable request code. Use curl, httpie, python, javascript or one of the application's supported language targets.", ["id": text, "language": choices(RequestCode.Format.allCases.map(\.rawValue) + ["javascript", "node", "objc", "python-requests"])], required: ["id"]),
            tool("rules", "List/get/add/update/delete/enable/disable/rename/duplicate individual rules. tool: mapLocal/mapRemote/blockList/allowList/sslProxyingList/sslApplications/customCertificates/dns/breakpoints/rewrite/latency/protobuf/reverse. For add, supply a rule object; classic rules need pattern, target and comment default empty. Get/list existing rules for schema. Use groupId to address nested rewrite rules; a unique nested ID can also be addressed directly. rename uses name, preserving match fields. duplicate regenerates all owned IDs and preserves folder memberships; SSL application copies require a new bundleId. Reverse copies start disabled to avoid port conflicts. Updates merge fields and retain IDs. Bulk changes use CLI rules preview/apply.",
                 ["tool": text, "action": choices(["list", "get", "add", "update", "delete", "enable", "disable", "rename", "duplicate"]), "id": text, "folderId": text, "groupId": text, "name": text, "bundleId": text, "rule": ["type": "object"]], required: ["tool", "action"], readOnly: false),
            tool("folders", "Manage nested rule folders. Deleting a folder keeps its rules. assign without folderId removes a rule from its folder.",
                 ["tool": text, "action": choices(["list", "create", "rename", "move", "delete", "enable", "disable", "assign"]), "id": text, "name": text, "parentId": text, "folderId": text, "ruleId": text], required: ["tool", "action"], readOnly: false),
            tool("tools", "List tools and their global state, or enable/disable one tool without changing its individual rules.", ["action": choices(["list", "enable", "disable"]), "tool": text], readOnly: false),
            tool("external_proxy", "Get, set or disable the upstream proxy (HTTP/HTTPS/SOCKS5/PAC). config merges existing fields. routingMode is all/bypass/inclusive (omitted preserves bypass behavior); includedTargets contains host globs or HTTP(S) URL globs used only by inclusive mode. Nonmatching targets and localhost are direct. Password is redacted in replies.", ["action": choices(["get", "set", "disable"]), "config": ["type": "object"]], readOnly: false),
            tool("set_recording", "Enable or disable recording while retaining captured traffic.", ["enabled": boolean], required: ["enabled"], readOnly: false),
            tool("http_version", "Read HTTP version mode, or set HTTP/2 negotiation for new connections.", ["http2": boolean], readOnly: false),
            tool("launch", "Launch a terminal/browser/Electron application with local proxy configuration. Uses a dedicated browser profile. Requires a running listener.",
                 ["target": choices(["terminal", "iterm", "ghostty", "chrome", "firefox", "electron", "custom"]), "application": text], required: ["target"], readOnly: false),
            tool("script_help", "Read script entry points and an example. Review generated scripts before activation.")
            ,tool("websocket_sessions", "List captured WebSocket sessions, including retained message counts.", ["limit": ["type": "integer", "minimum": 1, "maximum": 1000]])
            ,tool("websocket_messages", "Read captured WebSocket frames as base64. afterId supports polling. Whole payloads exceeding the 1 MiB response budget are omitted explicitly.", ["id": text, "afterId": text, "direction": choices(["all", "send", "recv"]), "limit": ["type": "integer", "minimum": 1, "maximum": 200]], required: ["id"])
            ,tool("compose", "Manage persisted HTTP request drafts (100 drafts / 4 MiB). create/update accept rawRequest. send uses the running local proxy and returns a jobId; poll result or cancel with id=jobId. Up to 20 jobs run concurrently; the last 100 jobs remain addressable. result includes a complete snapshot up to 1 MiB within an 8 MiB retained budget; resultState reports omitted/evicted snapshots. flowId is present only while get_flow can resolve it.", ["action": choices(["list", "create", "get", "update", "delete", "send", "result", "cancel"]), "id": text, "name": text, "rawRequest": text], required: ["action"], readOnly: false)
            ,tool("certificate_status", "Read the last known root certificate trust state and request an asynchronous refresh.")
            ,tool("setup_guide", "Get device/framework setup steps, proxy port, CA download URL and commands.", ["platform": text])
            ,tool("search_docs", "Search the bundled ProxyMirror workbench documentation.", ["query": text], required: ["query"])
        ]
    }

    static func runStandardIO() -> Int32 {
        var pending = Data()
        do {
            while true {
                let chunk = try FileHandle.standardInput.read(upToCount: 8192) ?? Data()
                if chunk.isEmpty {
                    if !pending.isEmpty { try writeLine(reply(to: pending)) }
                    return 0
                }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard line.count <= inputLimit else { throw LocalControlError.usage("MCP message exceeds 3 MiB") }
                    if !line.isEmpty { try writeLine(reply(to: line)) }
                }
                guard pending.count <= inputLimit else { throw LocalControlError.usage("MCP message exceeds 3 MiB") }
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data(("ProxyMirror MCP: " + error.localizedDescription + "\n").utf8))
            return 4
        }
    }

    private static func writeLine(_ data: Data?) throws {
        guard let data else { return }
        // The JSON helper pretty-prints; stdio requires a single JSON line.
        let value = try JSONSerialization.jsonObject(with: data)
        let compact = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        try FileHandle.standardOutput.write(contentsOf: compact)
        try FileHandle.standardOutput.write(contentsOf: Data([10]))
    }
}
