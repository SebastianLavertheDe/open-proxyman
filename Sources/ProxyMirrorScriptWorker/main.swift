import Foundation
import JavaScriptCore

private let inputLimit = 2 * 1024 * 1024
private let outputLimit = 1024 * 1024

private func output(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object), data.count <= outputLimit {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

private func run() throws {
    let input = try FileHandle.standardInput.read(upToCount: inputLimit + 1) ?? Data()
    guard input.count <= inputLimit,
          let options = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let source = options["source"] as? String,
          source.utf8.count <= 16 * 1024,
          let packet = options["message"] as? [String: Any],
          let serialized = String(data: try JSONSerialization.data(withJSONObject: packet), encoding: .utf8),
          let context = JSContext() else {
        output(["error": "脚本或报文参数无效"])
        return
    }

    var exception: String?
    context.exceptionHandler = { _, error in
        exception = String((error?.toString() ?? "JavaScript 异常").prefix(1000))
    }
    // The only value bridged into JavaScript is a string containing the input JSON.
    context.setObject(serialized, forKeyedSubscript: "__pmInput" as NSString)
    let code = """
    (() => {
        "use strict";
        const message = JSON.parse(__pmInput);
        const logs = [];
        const asText = (value) => {
            if (typeof value === "string") return value.slice(0, 400);
            try { return (JSON.stringify(value) ?? String(value)).slice(0, 400); }
            catch { return "[无法显示的值]"; }
        };
        const writeLog = (...values) => {
            if (logs.length < 12) logs.push(values.slice(0, 8).map(asText).join(" ").slice(0, 1000));
        };
        const console = Object.freeze({ log: writeLog, info: writeLog, warn: writeLog, error: writeLog });
        const result = (function(message, console) {
            \(source)
        })(message, console);
        return JSON.stringify({ message: result === undefined ? message : result, logs });
    })()
    """

    let result = context.evaluateScript(code)
    if let exception { output(["error": exception]); return }
    guard let text = result?.toString(), let data = text.data(using: .utf8),
          data.count <= outputLimit, !text.isEmpty else {
        output(["error": "脚本输出超过 1 MiB 或无法序列化"])
        return
    }
    try FileHandle.standardOutput.write(contentsOf: data)
}

do {
    try run()
} catch {
    output(["error": String(error.localizedDescription.prefix(1000))])
}
