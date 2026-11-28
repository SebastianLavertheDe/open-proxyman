import Foundation
import ProxyMirrorFoundation

@main
struct WorkbenchChecks {
    @MainActor
    static func main() async throws {
        let app = AppState.shared
        defer { app.defaults.removePersistentDomain(forName: app.defaultsName) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(message) } catch { checks += 1 }
        }
        func run(_ action: String, _ values: [String: Any] = [:]) throws -> [String: Any] {
            let input = values.merging(["operation": "compose", "action": action]) { _, value in value }
            let data = try AutomationWorkbench.execute(input, app: app, defaults: app.defaults)
            return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let raw = "POST https://example.test/send?token=query-secret HTTP/1.1\nContent-Type: application/json\nAuthorization: Bearer header-secret\n\n{\"password\":\"body-secret\",\"name\":\"visible\"}"
        let created = try run("create", ["name": "fixture", "rawRequest": raw])
        let draftID = created["id"] as! String
        expect((try run("get", ["id": draftID]))["rawRequest"] as? String == raw, "Draft round trip")
        let persisted = app.defaults.data(forKey: "automation.composeDrafts.v1")!
        rejects("Invalid update must fail") { _ = try run("update", ["id": draftID, "rawRequest": "invalid"]) }
        expect(app.defaults.data(forKey: "automation.composeDrafts.v1") == persisted, "Invalid mutation preserves archive")
        rejects("Wrong name type must fail") { _ = try run("update", ["id": draftID, "name": 42]) }
        rejects("Missing update must fail") { _ = try run("update", ["id": draftID]) }
        rejects("Wrong ID type must fail") { _ = try run("get", ["id": 1]) }
        rejects("Out of range port must fail") { _ = try run("create", ["rawRequest": "GET http://example.test:99999/ HTTP/1.1\n\n"]) }

        let sent = try run("send", ["id": draftID])
        expect(sent["state"] as? String == "completed", "Synchronous completion is represented truthfully")
        let result = try run("result", ["id": sent["jobId"]!])
        expect(result["flowId"] == nil && app.store.transactions.isEmpty, "Successful sends do not duplicate proxy captures or return unresolvable IDs")
        expect(result["result"] is [String: Any], "Completed job retains a complete snapshot")
        app.store.transactions = []
        let evicted = try run("result", ["id": sent["jobId"]!])
        expect(evicted["flowId"] == nil && evicted["flowRetained"] as? Bool == false, "Evicted flow never returns a stale flowId")
        expect(evicted["result"] is [String: Any], "Result survives store eviction within snapshot budget")

        ComposeService.resultState = .failed
        let failed = try run("send", ["id": draftID])
        let failedResult = try run("result", ["id": failed["jobId"]!])
        expect(failedResult["flowId"] as? String == app.store.transactions.last?.id.uuidString, "Failed sends retain the existing resolvable capture behavior")
        ComposeService.resultState = .completed
        ComposeService.dispatchCompletion = true
        let asynchronous = try run("send", ["id": draftID])
        expect(asynchronous["state"] as? String == "sending", "Asynchronous send initially remains addressable")
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        expect((try run("result", ["id": asynchronous["jobId"]!]))["state"] as? String == "completed", "Main-actor callback publishes completion")
        ComposeService.dispatchCompletion = false

        ComposeService.deferred = true
        var active: [String] = []
        for _ in 0..<20 { active.append(try run("send", ["id": draftID])["jobId"] as! String) }
        rejects("Twenty running jobs must bound work") { _ = try run("send", ["id": draftID]) }
        _ = try run("cancel", ["id": active[0]])
        expect(ComposeService.pending.first?.0.cancelled == true, "Cancel reaches the transport")
        _ = try run("send", ["id": draftID])
        ComposeService.finishPending()
        expect((try run("result", ["id": active[0]]))["state"] as? String == "cancelled", "Late callback does not resurrect a cancelled job")
        ComposeService.deferred = false

        var oldest: String?
        for index in 0..<101 {
            let id = try run("send", ["id": draftID])["jobId"] as! String
            if index == 0 { oldest = id }
        }
        rejects("Completed job retention must remain bounded") { _ = try run("result", ["id": oldest!]) }

        ComposeService.responseBytes = Data(repeating: 65, count: 600 * 1024)
        var snapshotJobs: [String] = []
        for _ in 0..<12 { snapshotJobs.append(try run("send", ["id": draftID])["jobId"] as! String) }
        expect((try run("result", ["id": snapshotJobs[0]]))["resultState"] as? String == "evicted", "Snapshot total is bounded at eight MiB")
        expect((try run("result", ["id": snapshotJobs.last!]))["result"] is [String: Any], "Newest snapshot remains available")
        ComposeService.responseBytes = Data(repeating: 65, count: 2 * 1024 * 1024)
        let large = try run("send", ["id": draftID])
        expect((try run("result", ["id": large["jobId"]!]))["resultState"] as? String == "exceeds_1_MiB", "Oversized result omission is explicit")
        ComposeService.responseBytes = Data("{\"token\":\"result-secret\"}".utf8)

        let ws = Transaction(); ws.isWebSocket = true
        func frame(_ payload: Data, direction: WSFrame.Direction = .upstream) -> WSFrame {
            WSFrame(direction: direction, opcode: 1, fin: true, masked: false, payload: payload)
        }
        ws.websocketFrames = [frame(Data(repeating: 65, count: 1024 * 1024)),
                              frame(Data("{\"token\":\"ws-secret\"}".utf8), direction: .downstream),
                              frame(Data("hello".utf8))]
        app.store.add(ws)
        let framesData = try AutomationWorkbench.execute(["operation": "websocket_messages", "id": ws.id.uuidString, "limit": 2], app: app)
        let frames = try JSONSerialization.jsonObject(with: framesData) as! [String: Any]
        let rows = frames["messages"] as! [[String: Any]]
        expect(framesData.count < 1024 * 1024, "Whole WebSocket reply respects budget after base64 expansion")
        expect(rows[0]["payloadOmitted"] as? Bool == true && rows[0]["payload"] == nil, "Oversized frame is never partially returned")
        expect(frames["hasMore"] as? Bool == true && frames["nextAfterId"] as? String == ws.websocketFrames[1].id.uuidString, "WebSocket cursor advances over omitted frames")
        rejects("Boolean limits must fail") { _ = try AutomationWorkbench.execute(["operation": "websocket_sessions", "limit": true], app: app) }
        rejects("Noninteger limits must fail") { _ = try AutomationWorkbench.execute(["operation": "websocket_sessions", "limit": 1.5], app: app) }
        rejects("Unknown frame cursor must fail") { _ = try AutomationWorkbench.execute(["operation": "websocket_messages", "id": ws.id.uuidString, "afterId": UUID().uuidString], app: app) }

        func mcp(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
            let input = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
            let output = MCPProtocol.reply(to: input)!
            return (try JSONSerialization.jsonObject(with: output) as! [String: Any])["result"] as! [String: Any]
        }
        let privateFrames = try mcp("websocket_messages", ["id": ws.id.uuidString, "direction": "recv"])
        let privateRows = ((privateFrames["structuredContent"] as! [String: Any])["messages"] as! [[String: Any]])
        let decoded = String(decoding: Data(base64Encoded: privateRows[0]["payload"] as! String)!, as: UTF8.self)
        expect(!decoded.contains("ws-secret") && decoded.contains("<redacted>"), "MCP redacts frame contents through the actual privacy envelope")
        let privateDraft = try mcp("compose", ["action": "get", "id": draftID])
        let draftText = (privateDraft["structuredContent"] as! [String: Any])["rawRequest"] as! String
        expect(!["query-secret", "header-secret", "body-secret"].contains(where: draftText.contains), "MCP draft reads do not leak credentials")
        let privateJob = try run("send", ["id": draftID])
        let privateResult = try mcp("compose", ["action": "result", "id": privateJob["jobId"]!])
        let privateRecord = (privateResult["structuredContent"] as! [String: Any])["result"] as! [String: Any]
        let privateBody = String(decoding: Data(base64Encoded: privateRecord["responseBody"] as! String)!, as: UTF8.self)
        expect(!privateBody.contains("result-secret"), "MCP redacts completed Compose response snapshots")
        let originalRecord = (try run("result", ["id": privateJob["jobId"]!]))["result"] as! [String: Any]
        let originalBody = String(decoding: Data(base64Encoded: originalRecord["responseBody"] as! String)!, as: UTF8.self)
        expect(originalBody.contains("result-secret"), "MCP privacy does not alter the retained Compose result")
        let rejected = try mcp("websocket_sessions", ["limit": true])
        expect(rejected["isError"] as? Bool == true, "JSON-RPC schema rejects boolean integer")
        app.settings.mcpEnabled = false
        expect((try mcp("certificate_status", [:]))["isError"] as? Bool == true, "Disabled MCP refuses workbench operations")
        app.settings.mcpEnabled = true

        let savedArchive = app.defaults.data(forKey: "automation.composeDrafts.v1")!
        let objects = try JSONSerialization.jsonObject(with: savedArchive) as! [[String: Any]]
        app.defaults.set(try JSONSerialization.data(withJSONObject: [objects[0], objects[0]]), forKey: "automation.composeDrafts.v1")
        rejects("Duplicate persisted IDs must fail") { _ = try run("list") }
        app.defaults.set(savedArchive, forKey: "automation.composeDrafts.v1")
        _ = try run("delete", ["id": draftID])
        expect(app.defaults.data(forKey: "automation.composeDrafts.v1") != savedArchive, "Delete persists")
        for _ in 0..<100 { _ = try run("create", ["rawRequest": "GET https://example.test/ HTTP/1.1\n\n"]) }
        let fullArchive = app.defaults.data(forKey: "automation.composeDrafts.v1")
        rejects("Persistent drafts have a hard count limit") { _ = try run("create", ["rawRequest": raw]) }
        expect(app.defaults.data(forKey: "automation.composeDrafts.v1") == fullArchive, "Overflow does not change persisted drafts")
        print("PASS automation workbench: \(checks) production parsing, persistence, jobs, WebSocket and MCP/privacy checks")
    }
}
