import Foundation
import CoreFoundation
import ProxyMirrorFoundation

/// Bounded workbench operations shared by MCP's tools and the automation socket.
@MainActor
enum AutomationWorkbench {
    static let operations: Set<String> = [
        "websocket_sessions", "websocket_messages", "compose", "certificate_status", "setup_guide", "search_docs",
    ]

    private struct Draft: Codable {
        var id: UUID
        var name: String
        var request: HTTPRequest
    }

    private struct SendJob {
        var task: ComposeService.RequestTask?
        var flowID: UUID?
        var state: String
        var sequence: UInt64
        var snapshot: Data?
        var snapshotState = "pending"
    }

    private static let draftsKey = "automation.composeDrafts.v1"
    private static var jobs: [UUID: SendJob] = [:]
    private static var jobSequence: UInt64 = 0
    private static let maximumJobs = 100
    private static let maximumRunningJobs = 20
    private static let maximumSnapshotBytes = 1024 * 1024
    private static let maximumRetainedSnapshotBytes = 8 * 1024 * 1024

    static func execute(_ arguments: [String: Any], app: AppState, defaults: UserDefaults = .standard) throws -> Data {
        let result: Any
        switch arguments["operation"] as? String {
        case "websocket_sessions":
            let limit = try boundedLimit(arguments, maximum: 1000)
            result = app.store.transactions.reversed().lazy.filter(\.isWebSocket).prefix(limit).reversed().map { transaction in
                ["id": transaction.id.uuidString, "url": transaction.fullURL,
                 "state": transaction.state.rawValue, "messages": transaction.websocketFrames.count] as [String: Any]
            }
        case "websocket_messages":
            let id = try identifier(arguments)
            guard let transaction = app.store.transactions.first(where: { $0.id == id && $0.isWebSocket }) else {
                throw LocalControlError.noMatches("WebSocket session not found")
            }
            let direction = try string(arguments, key: "direction") ?? "all"
            guard ["all", "send", "recv"].contains(direction) else { throw LocalControlError.usage("Invalid direction") }
            let after = try optionalIdentifier(arguments, key: "afterId")
            let frames = transaction.websocketFrames
            let start: Int
            if let after {
                guard let index = frames.firstIndex(where: { $0.id == after }) else {
                    throw LocalControlError.noMatches("afterId is no longer retained")
                }
                start = index + 1
            } else { start = 0 }
            let limit = try boundedLimit(arguments, maximum: 200)
            let matching = frames.dropFirst(start).lazy.filter { direction == "all" || $0.direction.rawValue == direction }
            let selected = Array(matching.prefix(limit))
            // Never return a partial binary frame as if it were complete.
            // Charge base64 expansion and reserve enough space for every row's
            // metadata so the complete JSON reply remains below one MiB.
            var remaining = 1024 * 1024 - 1024 - selected.count * 512
            var rows: [[String: Any]] = []
            for frame in selected {
                let bytes = frame.payload.count
                let encodedBytes = 4 * ((bytes + 2) / 3)
                let included = encodedBytes <= remaining
                if included { remaining -= encodedBytes }
                var row: [String: Any] = ["id": frame.id.uuidString, "direction": frame.direction.rawValue,
                    "opcode": Int(frame.opcode), "timestamp": ISO8601DateFormatter().string(from: frame.timestamp),
                    "size": bytes, "fin": frame.fin, "masked": frame.masked,
                    "compressed": frame.rsv1 == true, "payloadOmitted": !included]
                if included { row["payload"] = frame.payload.base64EncodedString() }
                rows.append(row)
            }
            var page: [String: Any] = ["sessionId": id.uuidString, "messages": rows,
                "hasMore": matching.dropFirst(selected.count).first != nil]
            if let last = selected.last { page["nextAfterId"] = last.id.uuidString }
            result = page
        case "compose": result = try compose(arguments, app: app, defaults: defaults)
        case "certificate_status":
            // Refresh asynchronously without blocking the main actor on a Keychain query.
            app.refreshCertificateStatus()
            result = ["trustedAtLastCheck": app.caInstalled,
                      "certificateExists": FileManager.default.fileExists(atPath: app.certificateAuthority.caCertPath.path),
                      "refreshRequested": true]
        case "setup_guide":
            let platform = try string(arguments, key: "platform") ?? "iOS"
            let supported = ["iOS", "Android"] + CertificatePlatformGuides.simulatorPlatforms + CertificatePlatformGuides.frameworks
            guard supported.contains(platform) else { throw LocalControlError.usage("Unsupported platform: " + platform) }
            let guide = CertificatePlatformGuides.guide(for: platform,
                certificatePath: app.certificateAuthority.caCertPath.path, port: Int(app.listenerPort))
            result = ["platform": platform, "steps": guide.steps, "commands": guide.commands,
                      "links": guide.links.map { ["title": $0.title, "url": $0.url.absoluteString] },
                      "listening": app.proxyRunning, "port": Int(app.listenerPort),
                      "certificateDownloadURL": "http://proxy.mirror/ssl"]
        case "search_docs":
            let query = (try string(arguments, key: "query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.utf8.count <= 256 else { throw LocalControlError.usage("query must contain 1–256 bytes") }
            result = documentation.filter { ($0["title"]! + " " + $0["text"]!).localizedCaseInsensitiveContains(query) }
        default: throw LocalControlError.usage("Unknown workbench operation")
        }
        return try AutomationControl.json(result)
    }

    private static func compose(_ arguments: [String: Any], app: AppState, defaults: UserDefaults) throws -> Any {
        let action = try string(arguments, key: "action") ?? "list"
        guard ["list", "create", "get", "update", "delete", "send", "result", "cancel"].contains(action) else {
            throw LocalControlError.usage("Unsupported Compose action")
        }
        if action == "result" || action == "cancel" {
            let id = try identifier(arguments)
            guard var job = jobs[id] else { throw LocalControlError.noMatches("Compose job not found") }
            if action == "cancel", job.state == "sending" {
                job.task?.cancel(); job.task = nil; job.state = "cancelled"
                job.snapshotState = "cancelled"; jobs[id] = job
            }
            var result: [String: Any] = ["jobId": id.uuidString, "state": job.state, "resultState": job.snapshotState]
            if let flow = job.flowID {
                let retained = app.store.transactions.contains { $0.id == flow }
                result["flowRetained"] = retained
                if retained { result["flowId"] = flow.uuidString }
            }
            if let snapshot = job.snapshot { result["result"] = try JSONSerialization.jsonObject(with: snapshot) }
            return result
        }
        var drafts = try loadDrafts(defaults: defaults)
        if action == "list" { return drafts.map { ["id": $0.id.uuidString, "name": $0.name, "method": $0.request.method, "url": $0.request.url] } }
        if action == "create" {
            let request = try parsedRequest(arguments)
            let draft = Draft(id: UUID(), name: try draftName(arguments), request: request)
            drafts.append(draft)
            try saveDrafts(drafts, defaults: defaults)
            return ["id": draft.id.uuidString, "name": draft.name]
        }
        let id = try identifier(arguments)
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { throw LocalControlError.noMatches("Compose draft not found") }
        switch action {
        case "get":
            return ["id": id.uuidString, "name": drafts[index].name,
                    "rawRequest": ComposeService.rawText(from: drafts[index].request)]
        case "update":
            guard arguments["rawRequest"] != nil || arguments["name"] != nil else {
                throw LocalControlError.usage("update requires name or rawRequest")
            }
            if arguments["rawRequest"] != nil { drafts[index].request = try parsedRequest(arguments) }
            if arguments["name"] != nil { drafts[index].name = try draftName(arguments) }
            try saveDrafts(drafts, defaults: defaults)
            return ["id": id.uuidString, "updated": true]
        case "delete":
            drafts.remove(at: index)
            try saveDrafts(drafts, defaults: defaults)
            return ["id": id.uuidString, "deleted": true]
        case "send":
            guard app.proxyRunning else { throw LocalControlError.failed("Start the proxy listener before sending a draft") }
            // Bound retained task handles and keep running jobs addressable.
            guard jobs.values.filter({ $0.state == "sending" }).count < maximumRunningJobs else {
                throw LocalControlError.failed("At most 20 Compose jobs may run at once")
            }
            if jobs.count >= maximumJobs {
                guard let oldest = jobs.filter({ $0.value.state != "sending" }).min(by: { $0.value.sequence < $1.value.sequence })?.key else {
                    throw LocalControlError.failed("Too many Compose jobs are running")
                }
                jobs.removeValue(forKey: oldest)
            }
            let jobID = UUID()
            jobSequence &+= 1
            jobs[jobID] = SendJob(state: "sending", sequence: jobSequence)
            let task = ComposeService.execute(drafts[index].request, runtime: app.runtimeContext,
                proxyPort: app.listenerPort) { transaction in
                guard var job = jobs[jobID], job.state == "sending" else { return }
                // Successful sends are already captured by the local proxy with
                // a separate identity. Keep the transport result in this job
                // instead of inserting a second copy into the traffic list.
                if transaction.state == .failed,
                   !app.store.transactions.contains(where: { $0.id == transaction.id }) { app.store.add(transaction) }
                job.task = nil; job.flowID = transaction.id; job.state = transaction.state.rawValue
                let payload = transaction.capturedPayloadSnapshot()
                let bodyBytes = payload.request.count + payload.response.count + payload.frames.reduce(0) { $0 + $1.payload.count }
                if bodyBytes <= maximumSnapshotBytes,
                   let data = try? AutomationControl.encode(SessionRecord(transaction)), data.count <= maximumSnapshotBytes {
                    job.snapshot = data; job.snapshotState = "available"
                } else { job.snapshotState = "exceeds_1_MiB" }
                jobs[jobID] = job
                trimSnapshots()
            }
            guard let task else {
                jobs.removeValue(forKey: jobID)
                throw LocalControlError.usage("Request cannot be sent")
            }
            // A transport may reject or complete synchronously. Do not attach
            // a completed task handle after its completion callback cleared it.
            if jobs[jobID]?.state == "sending" { jobs[jobID]?.task = task }
            return ["jobId": jobID.uuidString, "state": jobs[jobID]?.state ?? "sending"]
        default: throw LocalControlError.usage("Unsupported Compose action")
        }
    }

    private static func parsedRequest(_ arguments: [String: Any]) throws -> HTTPRequest {
        guard let text = arguments["rawRequest"] as? String, text.utf8.count <= 512 * 1024,
              let request = ComposeService.parse(text),
              let url = URL(string: request.url), let host = url.host, !host.isEmpty,
              ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
            throw LocalControlError.usage("rawRequest must be a valid HTTP request of at most 512 KiB")
        }
        try validateRequest(request)
        return request
    }

    private static func trimSnapshots() {
        var size = jobs.values.reduce(0) { $0 + ($1.snapshot?.count ?? 0) }
        for entry in jobs.sorted(by: { $0.value.sequence < $1.value.sequence }) where size > maximumRetainedSnapshotBytes {
            guard let data = entry.value.snapshot else { continue }
            size -= data.count; jobs[entry.key]?.snapshot = nil; jobs[entry.key]?.snapshotState = "evicted"
        }
    }

    private static func draftName(_ arguments: [String: Any]) throws -> String {
        let name = try string(arguments, key: "name") ?? "Request"
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256 else {
            throw LocalControlError.usage("name must contain 1–256 bytes")
        }
        return name
    }

    private static func loadDrafts(defaults: UserDefaults) throws -> [Draft] {
        guard let stored = defaults.object(forKey: draftsKey) else { return [] }
        guard let data = stored as? Data else { throw LocalControlError.failed("Compose draft archive is not encoded data") }
        guard data.count <= 4 * 1024 * 1024 else { throw LocalControlError.failed("Compose draft archive exceeds 4 MiB") }
        let drafts = try JSONDecoder().decode([Draft].self, from: data)
        guard drafts.count <= 100, Set(drafts.map(\.id)).count == drafts.count else {
            throw LocalControlError.failed("Compose draft archive has too many requests or duplicate IDs")
        }
        for draft in drafts {
            _ = try draftName(["name": draft.name])
            try validateRequest(draft.request)
        }
        return drafts
    }

    private static func saveDrafts(_ drafts: [Draft], defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(drafts)
        guard drafts.count <= 100, data.count <= 4 * 1024 * 1024 else { throw LocalControlError.usage("Compose drafts are limited to 100 requests and 4 MiB") }
        defaults.set(data, forKey: draftsKey)
    }

    private static func identifier(_ arguments: [String: Any]) throws -> UUID {
        guard let id = try optionalIdentifier(arguments, key: "id") else { throw LocalControlError.usage("id is required") }
        return id
    }

    private static func optionalIdentifier(_ arguments: [String: Any], key: String) throws -> UUID? {
        guard let text = try string(arguments, key: key) else { return nil }
        guard let id = UUID(uuidString: text) else { throw LocalControlError.usage("Invalid UUID: " + key) }
        return id
    }

    private static func boundedLimit(_ arguments: [String: Any], maximum: Int) throws -> Int {
        guard arguments["limit"] == nil || (arguments["limit"] as? NSNumber).map({
            CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue.rounded() == $0.doubleValue
        }) == true else { throw LocalControlError.usage("limit must be an integer") }
        let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 100
        guard (1...maximum).contains(limit) else { throw LocalControlError.usage("limit must be 1–\(maximum)") }
        return limit
    }

    private static func string(_ arguments: [String: Any], key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let text = value as? String else { throw LocalControlError.usage(key + " must be a string") }
        return text
    }

    private static func validateRequest(_ request: HTTPRequest) throws {
        func token(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
            }
        }
        guard let url = URLComponents(string: request.url), let host = url.host, !host.isEmpty,
              ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              url.port.map({ (1...65535).contains($0) }) ?? true,
              request.url.utf8.count <= 65536, !request.url.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              request.method.utf8.count <= 64, token(request.method), (0...86400).contains(request.timeoutSeconds),
              (request.body?.count ?? 0) <= 512 * 1024, request.headers.count <= 1000,
              request.headers.allSatisfy({ token($0.0) && $0.1.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) }) else {
            throw LocalControlError.usage("Invalid or oversized Compose request")
        }
    }

    private static let documentation: [[String: String]] = [
        ["title": "Setup / 设备接入", "text": "Use setup_guide for iOS, Android, Java, NodeJS, Python, Docker and simulator instructions. Set a device's Wi-Fi proxy to the Mac's LAN IP and listener port, then open http://proxy.mirror/ssl and explicitly enable certificate trust."],
        ["title": "TLS / SSL / 证书", "text": "Enable SSL Proxying for the target host to inspect HTTPS. Install and trust the local root CA. Pinned applications can reject interception; bypass the domain or application. certificate_status requests a fresh trust probe."],
        ["title": "Scripting / 脚本", "text": "Hooks: onRequest, onResponse, onWebSocket. CommonJS addons, fetch, @proxymirror/http and an Axios subset are available. Use script_help for the network budget and an example."],
        ["title": "Export / 导出", "text": "export_flows supports HAR, JSON, CSV, native session, OpenAPI 3.0 and Postman Collection 2.1. MCP redacts sensitive data by default. Private Proxyman files must first be exported as HAR."],
        ["title": "Compose / 重放", "text": "Use compose to create, list, get, update and delete persisted request drafts. send returns a jobId; poll result using that id for completion or cancel it. At most 20 jobs run concurrently; the last 100 jobs remain addressable. Results retain a complete snapshot up to 1 MiB each within an 8 MiB total budget. Larger or evicted snapshots explicitly report resultState; flowId is returned only while get_flow can resolve it. Sends use the local running proxy."],
        ["title": "WebSocket / 消息", "text": "websocket_sessions lists captured connections. websocket_messages supports send/recv filtering and an afterId cursor. Payloads are base64, are redacted by MCP, and are omitted when the 1 MiB reply budget is exhausted."],
    ]
}
