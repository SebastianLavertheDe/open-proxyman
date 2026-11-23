import Foundation
import JavaScriptCore
import CryptoKit

private let inputLimit = 2 * 1024 * 1024
private let outputLimit = 2 * 1024 * 1024

private func output(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object), data.count <= outputLimit {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
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
    context.evaluateScript(scriptingRuntime)
    let deadline = Date().addingTimeInterval(0.35)
    while exception == nil, context.objectForKeyedSubscript("__pmResult")?.isUndefined != false, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
    if let exception { output(["error": exception]); return }
    guard let text = context.objectForKeyedSubscript("__pmResult")?.toString(),
          let data = text.data(using: .utf8), data.count <= outputLimit, text != "undefined", !text.isEmpty else {
        output(["error": "异步脚本未及时完成，或输出超过 2 MiB"])
        return
    }
    try FileHandle.standardOutput.write(contentsOf: data)
}

do { try run() }
catch { output(["error": String(error.localizedDescription.prefix(1000))]) }
