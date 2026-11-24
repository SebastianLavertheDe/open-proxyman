import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Production HTTP composition independent of UI, capture models and CA policy.
package enum HTTPRequestTransport {
    package enum Failure: LocalizedError {
        case cancelled, timedOut, invalidRequestHeaders, responseHeadersTooLarge(Int)
        case redirectLimit(Int), invalidRedirect, noResponse, curlFailure(Int32, String)
        package var errorDescription: String? {
            switch self {
            case .cancelled: return "Request cancelled"
            case .timedOut: return "Request timed out"
            case .invalidRequestHeaders: return "Invalid request headers"
            case .responseHeadersTooLarge(let limit): return "Response headers exceed \(limit) bytes"
            case .redirectLimit(let limit): return "Too many redirects (maximum \(limit))"
            case .invalidRedirect: return "Invalid HTTP redirect destination"
            case .noResponse: return "No HTTP response received"
            case .curlFailure(let status, let detail): return detail.isEmpty ? "Send failed (curl \(status))" : detail
            }
        }
    }
    package struct Options {
        package var proxyPort: UInt16?
        package var captureLimit: Int
        package var reserve: (Int) -> Int
        package var trustedCA: (HTTPRequest) throws -> URL?
        package init(proxyPort: UInt16? = nil, captureLimit: Int = 20 * 1024 * 1024,
                     reserve: @escaping (Int) -> Int = { $0 },
                     trustedCA: @escaping (HTTPRequest) throws -> URL? = { _ in nil }) {
            self.proxyPort = proxyPort; self.captureLimit = captureLimit
            self.reserve = reserve; self.trustedCA = trustedCA
        }
    }
    package struct Output {
        package let head: HTTPResponseHead?
        package let body: Data
        package let receivedBytes: Int
        package let failure: Error?
        package let duration: TimeInterval
    }
    package final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?
        package init() {}
        package func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let process { Self.stop(process) }
        }
        fileprivate func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw Failure.cancelled }
            try process.run(); self.process = process
        }
        fileprivate static func stop(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    package static func send(_ parsed: HTTPRequest, options: Options = Options(), cancellation: Cancellation = Cancellation()) -> Output {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let proxyPort = options.proxyPort
        var responseHead: HTTPResponseHead?
        var failure: Error?
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("proxymirror-send-\(UUID().uuidString)")
        let requestBodyFile = directory.appendingPathComponent("request")
        let configFile = directory.appendingPathComponent("curl.conf")
        let errorFile = directory.appendingPathComponent("error")
        var process: Process?
        var captured = Data()
        var count = 0
        defer { try? files.removeItem(at: directory) }

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            let started = ProcessInfo.processInfo.systemUptime
            var current = parsed
            var redirects = 0
            while true {
                let remaining = parsed.timeoutSeconds == 0 ? 0
                    : Double(parsed.timeoutSeconds) - (ProcessInfo.processInfo.systemUptime - started)
                guard parsed.timeoutSeconds == 0 || remaining > 0 else { throw Failure.timedOut }
                var config = [
                    "silent", "show-error", "http1.1", "suppress-connect-headers",
                    // dump-header flushes header blocks before any body. curl's
                    // --include can buffer headers until the entity arrives.
                    "dump-header = \"-\"", "no-buffer", "connect-timeout = 20", "max-time = \(remaining)", "proto = \"=http,https\"",
                    "url = \(quoted(current.url))", "request = \(quoted(current.method))",
                    "stderr = \(quoted(errorFile.path))",
                ]
                // --head also emits headers on the body output. Keep only the
                // dump-header stream, otherwise the two copies interleave.
                if current.method == "HEAD" { config += ["head", "output = \"/dev/null\""] }
                if let proxyPort {
                    config += ["proxy = \"http://127.0.0.1:\(proxyPort)\"", "noproxy = \"\""]
                    if let certificate = try options.trustedCA(current) {
                        config.append("cacert = \(quoted(certificate.path))")
                    }
                } else {
                    config.append("noproxy = \"*\"")
                }

                let framing: Set<String> = ["host", "content-length", "transfer-encoding", "trailer",
                                            "connection", "proxy-connection", "proxy-authorization"]
                for (key, value) in current.headers where !framing.contains(key.lowercased()) {
                    guard !key.isEmpty, key.utf8.allSatisfy(HTTPFraming.isToken),
                          !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                        throw Failure.invalidRequestHeaders
                    }
                    let header = value.isEmpty ? "\(key);" : "\(key): \(value)"
                    config.append("header = \(quoted(header))")
                }
                if let body = current.body, current.method != "HEAD" {
                    try body.write(to: requestBodyFile)
                    config.append("data-binary = \(quoted("@" + requestBodyFile.path))")
                }
                try Data((config.joined(separator: "\n") + "\n").utf8).write(to: configFile)

                let hop = Process()
                process = hop
                hop.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                hop.arguments = ["-q", "--config", configFile.path]
                let output = Pipe()
                hop.standardOutput = output
                hop.standardError = FileHandle.nullDevice
                try cancellation.start(hop)
                let reader = output.fileHandleForReading
                try? output.fileHandleForWriting.close()
                defer { try? reader.close() }
                var truncated = false
                var pendingHead = Data()
                var head: HTTPResponseHead?
                var next: HTTPRequest?
                while let bytes = try readAvailable(reader) {
                    var body = bytes
                    if head == nil {
                        pendingHead.append(bytes)
                        while let divider = pendingHead.range(of: Data([13, 10, 13, 10])) {
                            guard divider.lowerBound <= 64 * 1024 else { throw Failure.responseHeadersTooLarge(64 * 1024) }
                            let candidate = try ResponseHeadParser.parse(String(decoding: pendingHead[..<divider.lowerBound], as: UTF8.self))
                            pendingHead.removeSubrange(..<divider.upperBound)
                            if candidate.status < 200 && candidate.status != 101 { continue }
                            head = candidate
                            if let location = candidate.headers.value(of: "Location") {
                                next = try redirectedRequest(current, status: candidate.status, location: location)
                                if next != nil && redirects >= 10 { throw Failure.redirectLimit(10) }
                            }
                            break
                        }
                        guard head != nil else {
                            guard pendingHead.count <= 64 * 1024 else { throw Failure.responseHeadersTooLarge(64 * 1024) }
                            continue
                        }
                        body = pendingHead
                        pendingHead = Data()
                    }
                    // Intermediate entities never consume the final response's
                    // capture budget. Header bytes and HEAD output are not bodies.
                    if next != nil {
                        // A redirect is determined by its headers. Do not wait
                        // for an unbounded intermediate entity before following.
                        Cancellation.stop(hop)
                        break
                    }
                    if current.method == "HEAD" { continue }
                    count += body.count
                    guard !truncated else { continue }
                    let wanted = min(body.count, options.captureLimit - captured.count)
                    let accepted = wanted == 0 ? 0 : options.reserve(wanted)
                    if accepted > 0 { captured.append(contentsOf: body.prefix(accepted)) }
                    truncated = accepted < body.count
                }
                hop.waitUntilExit()
                responseHead = head
                if let next {
                    current = next
                    redirects += 1
                    continue
                }
                if hop.terminationReason == .uncaughtSignal {
                    failure = Failure.cancelled
                } else if hop.terminationStatus == 28 {
                    failure = Failure.timedOut
                } else if hop.terminationStatus != 0 {
                    let detail = (try? String(contentsOf: errorFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    failure = Failure.curlFailure(hop.terminationStatus, detail)
                } else if head == nil { failure = Failure.noResponse }
                break
            }
        } catch {
            cancellation.cancel()
            if let process, process.isRunning { process.waitUntilExit() }
            failure = error
        }
        return Output(head: responseHead, body: captured, receivedBytes: count, failure: failure,
                      duration: ProcessInfo.processInfo.systemUptime - startedAt)
    }

    /// FileHandle.read(upToCount:) can fill the requested buffer before
    /// returning on some Foundation implementations. A pipe read must expose
    /// response headers immediately, even if the response body never arrives.
    private static func readAvailable(_ handle: FileHandle) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(handle.fileDescriptor, bytes.baseAddress!, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return count == 0 ? nil : Data(buffer.prefix(count))
        }
    }

    /// Each hop gets its own curl invocation, so changing the method also
    /// changes the entity/framing semantics instead of merely changing -X.
    package static func redirectedRequest(_ current: HTTPRequest, status: Int, location: String) throws -> HTTPRequest? {
        guard current.followRedirects, [301, 302, 303, 307, 308].contains(status), !location.isEmpty else { return nil }
        guard let base = URL(string: current.url),
              let destination = URL(string: location, relativeTo: base)?.absoluteURL,
              var target = URLComponents(url: destination, resolvingAgainstBaseURL: true),
              let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = target.host, !host.isEmpty, target.user == nil, target.password == nil,
              target.port.map({ (1...65535).contains($0) }) ?? true else {
            throw Failure.invalidRedirect
        }
        target.fragment = nil
        guard let url = target.url else { throw Failure.invalidRedirect }
        var next = current
        next.url = url.absoluteString
        if (status == 301 || status == 302) && current.method == "POST" || status == 303 && current.method != "HEAD" {
            next.method = "GET"
            next.body = nil
            let entityHeaders: Set<String> = ["content-length", "content-type", "content-encoding", "content-language",
                                               "content-location", "content-md5", "digest", "content-digest", "repr-digest", "expect"]
            next.headers.removeAll { entityHeaders.contains($0.0.lowercased()) }
        }
        func origin(_ url: URL) -> String {
            let scheme = url.scheme?.lowercased() ?? ""
            return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }
        if origin(base) != origin(url) {
            next.headers.removeAll { HTTPReplayHeaders.sensitiveNames.contains($0.0.lowercased()) }
        }
        return next
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }

}
