import Foundation
import JavaScriptCore
import CryptoKit
import Darwin

private let inputLimit = 2 * 1024 * 1024
private let outputLimit = 2 * 1024 * 1024
private let outputLock = NSLock()
private var wroteOutput = false

private func writeOnce(_ data: Data) {
    outputLock.lock(); defer { outputLock.unlock() }
    guard !wroteOutput else { return }
    wroteOutput = true
    try? FileHandle.standardOutput.write(contentsOf: data)
}

private func output(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object), data.count <= outputLimit { writeOnce(data) }
}

private func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func run() throws {
    var input = Data()
    while input.count <= inputLimit,
          let chunk = try FileHandle.standardInput.read(upToCount: min(65536, inputLimit + 1 - input.count)), !chunk.isEmpty {
        input.append(chunk)
    }
    guard input.count <= inputLimit,
          let options = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let source = options["source"] as? String, source.utf8.count <= 256 * 1024,
          options["message"] is [String: Any] || options["operation"] as? String == "preview"
            || options["operation"] as? String == "beautify",
          let serialized = String(data: try JSONSerialization.data(withJSONObject: options), encoding: .utf8),
          let context = JSContext() else {
        output(["error": "脚本或报文参数无效"])
        return
    }
    var modules = options["modules"] as? [String: String] ?? [:]
    modules["lodash"] = builtInLodash
    modules["moment"] = builtInMoment
    modules["js-beautify"] = builtInBeautify
    let moduleData = try JSONSerialization.data(withJSONObject: modules)
    context.setObject(serialized, forKeyedSubscript: "__pmOptions" as NSString)
    context.setObject(String(decoding: moduleData, as: UTF8.self), forKeyedSubscript: "__pmModules" as NSString)
    var exception: String?
    context.exceptionHandler = { _, error in exception = String((error?.toString() ?? "JavaScript 异常").prefix(4000)) }
    let digest: @convention(block) (String, String, String) -> String = { algorithm, value, encoding in
        let data = Data(value.utf8)
        let bytes: Data
        switch algorithm.lowercased().replacingOccurrences(of: "-", with: "") {
        case "sha256": bytes = Data(SHA256.hash(data: data))
        case "sha384": bytes = Data(SHA384.hash(data: data))
        case "sha512": bytes = Data(SHA512.hash(data: data))
        case "sha1": bytes = Data(Insecure.SHA1.hash(data: data))
        case "md5": bytes = Data(Insecure.MD5.hash(data: data))
        default:
            JSContext.current()?.exception = JSValue(newErrorFromMessage: "不支持的摘要算法", in: JSContext.current())
            return ""
        }
        if encoding == "base64" { return bytes.base64EncodedString() }
        guard encoding == "hex" else {
            JSContext.current()?.exception = JSValue(newErrorFromMessage: "digest 仅支持 hex/base64", in: JSContext.current())
            return ""
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    let random: @convention(block) (Int) -> String = { count in
        guard (0...4096).contains(count) else {
            JSContext.current()?.exception = JSValue(newErrorFromMessage: "randomBytes 长度范围为 0...4096", in: JSContext.current())
            return ""
        }
        return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
    context.setObject(digest, forKeyedSubscript: "__pmDigest" as NSString)
    context.setObject(random, forKeyedSubscript: "__pmRandom" as NSString)
    let networkEnabled = options["networkEnabled"] as? Bool == true && options["operation"] == nil
    let limits = ScriptNetworkBridge.Limits(options["network"] as? [String: Any] ?? [:])
    let network: ScriptNetworkBridge? = networkEnabled ? ScriptNetworkBridge(limits: limits) { [weak context] result in
        let data: Data
        if let encoded = try? JSONSerialization.data(withJSONObject: result), encoded.count <= 3 * 1024 * 1024 { data = encoded }
        else {
            data = (try? JSONSerialization.data(withJSONObject: ["id": result["id"] as? String ?? "", "error": "网络响应编码超过上限", "name": "TypeError"])) ?? Data()
        }
        let serialized = String(decoding: data, as: UTF8.self)
        DispatchQueue.main.async { [weak context] in
            context?.objectForKeyedSubscript("__pmNetworkComplete")?.call(withArguments: [serialized])
        }
    } : nil
    defer { network?.cancelAll() }
    let fetchNative: @convention(block) (String) -> Void = { network?.start($0) }
    let abortNative: @convention(block) (String) -> Void = { network?.cancel($0) }
    context.setObject(fetchNative, forKeyedSubscript: "__pmFetchNative" as NSString)
    context.setObject(abortNative, forKeyedSubscript: "__pmAbortNative" as NSString)
    // CPU time excludes time waiting for network I/O. A separate queue can kill a
    // JavaScript infinite loop even while the worker's main thread is occupied.
    let cpuStart = cpuSeconds()
    let cpuWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ProxyMirror.script.cpu"))
    cpuWatchdog.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
    cpuWatchdog.setEventHandler {
        if cpuSeconds() - cpuStart > 0.4 {
            network?.cancelAll()
            output(["error": "脚本 CPU 执行超过 400 ms"])
            _exit(124)
        }
    }
    cpuWatchdog.resume()
    defer { cpuWatchdog.cancel() }
    let started = Date()
    let deadline = started.addingTimeInterval(networkEnabled ? Double(limits.wallTimeMilliseconds) / 1000 : 0.35)
    context.evaluateScript(scriptingRuntime)
    while exception == nil, context.objectForKeyedSubscript("__pmResult")?.isUndefined != false, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
    if let exception { output(["error": exception]); return }
    guard let text = context.objectForKeyedSubscript("__pmResult")?.toString(),
          let data = text.data(using: .utf8), data.count <= outputLimit, text != "undefined", !text.isEmpty else {
        output(["error": networkEnabled ? "脚本网络等待超过 wall time 或 Promise 未完成，或输出超过 2 MiB" : "异步脚本未及时完成，或输出超过 2 MiB"])
        return
    }
    writeOnce(data)
}

do { try run() }
catch { output(["error": String(error.localizedDescription.prefix(1000))]) }
