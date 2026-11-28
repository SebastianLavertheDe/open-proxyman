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
        package let trailers: HTTPHeaders
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
        fileprivate func check() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw Failure.cancelled }
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
        var responseTrailers = HTTPHeaders()
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
                responseHead = nil
                responseTrailers = HTTPHeaders()
                // curl sends trailers through its header callback as well. A
                // private FIFO keeps every header byte out of the entity pipe,
                // while allowing redirects before an intermediate body arrives.
                let headerURL = directory.appendingPathComponent("headers-\(redirects)")
                guard mkfifo(headerURL.path, mode_t(0o600)) == 0 else { throw currentError() }
                let headerFD = open(headerURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
                guard headerFD >= 0 else { throw currentError() }
                defer { close(headerFD); _ = unlink(headerURL.path) }
                let remaining = parsed.timeoutSeconds == 0 ? 0
                    : Double(parsed.timeoutSeconds) - (ProcessInfo.processInfo.systemUptime - started)
                guard parsed.timeoutSeconds == 0 || remaining > 0 else { throw Failure.timedOut }
                var config = [
                    "silent", "show-error", "http1.1", "suppress-connect-headers",
                    "dump-header = \(quoted(headerURL.path))", "no-buffer", "connect-timeout = 20", "max-time = \(remaining)", "proto = \"=http,https\"",
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
                guard fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw currentError() }
                var truncated = false
                var pendingHead = Data()
                var head: HTTPResponseHead?
                var next: HTTPRequest?
                var bodyEnded = false
                var earlyBody: Data?
                func capture(_ body: Data) {
                    guard current.method != "HEAD" else { return }
                    count += body.count
                    guard !truncated else { return }
                    let wanted = min(body.count, max(0, options.captureLimit - captured.count))
                    let accepted = wanted == 0 ? 0 : min(wanted, max(0, options.reserve(wanted)))
                    if accepted > 0 { captured.append(contentsOf: body.prefix(accepted)) }
                    truncated = accepted < body.count
                }
                while true {
                    try cancellation.check()
                    guard parsed.timeoutSeconds == 0 || ProcessInfo.processInfo.systemUptime - started < Double(parsed.timeoutSeconds) else {
                        throw Failure.timedOut
                    }
                    var received = false
                    if case .bytes(let bytes) = try readAvailable(headerFD) {
                        received = true
                        pendingHead.append(bytes)
                        while head == nil, let divider = pendingHead.range(of: Data([13, 10, 13, 10])) {
                            guard divider.lowerBound <= 64 * 1024 else { throw Failure.responseHeadersTooLarge(64 * 1024) }
                            let candidate = try ResponseHeadParser.parse(String(decoding: pendingHead[..<divider.lowerBound], as: UTF8.self))
                            pendingHead.removeSubrange(..<divider.upperBound)
                            if candidate.status < 200 && candidate.status != 101 { continue }
                            head = candidate
                            responseHead = candidate
                            if let location = candidate.headers.value(of: "Location") {
                                next = try redirectedRequest(current, status: candidate.status, location: location)
                                if next != nil && redirects >= 10 { throw Failure.redirectLimit(10) }
                            }
                            break
                        }
                        // After the final head this buffer contains trailers
                        // only, with an independent bound from the body budget.
                        guard pendingHead.count <= 64 * 1024 else { throw Failure.responseHeadersTooLarge(64 * 1024) }
                    }
                    // Intermediate entities never consume the final response's
                    // capture budget. Header bytes and HEAD output are not bodies.
                    if next != nil {
                        // A redirect is determined by its headers. Do not wait
                        // for an unbounded intermediate entity before following.
                        Cancellation.stop(hop)
                        break
                    }
                    if head != nil, let body = earlyBody {
                        capture(body)
                        earlyBody = nil
                    }
                    // The two descriptors can become readable between our
                    // reads. Hold at most one body chunk until its final head
                    // decides whether this hop should be followed or captured.
                    if head != nil || earlyBody == nil {
                        switch try readAvailable(reader.fileDescriptor) {
                        case .bytes(let body):
                            received = true
                            if head == nil { earlyBody = body } else { capture(body) }
                        case .end: bodyEnded = true
                        case .unavailable: break
                        }
                    }
                    // Drain both channels after exit before parsing trailers.
                    if !hop.isRunning && !received { break }
                    if !received {
                        var events = [pollfd(fd: headerFD, events: Int16(POLLIN), revents: 0)]
                        if !bodyEnded && (head != nil || earlyBody == nil) {
                            events.append(pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0))
                        }
                        let status = events.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 10) }
                        if status < 0 && errno != EINTR { throw currentError() }
                    }
                }
                hop.waitUntilExit()
                responseHead = head
                if let next {
                    current = next
                    redirects += 1
                    continue
                }
                if head != nil, !pendingHead.isEmpty {
                    let lines = String(decoding: pendingHead, as: UTF8.self).components(separatedBy: "\r\n")
                    responseTrailers = try HTTPFraming.parseHeaders(lines[...])
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
        return Output(head: responseHead, trailers: responseTrailers, body: captured, receivedBytes: count, failure: failure,
                      duration: ProcessInfo.processInfo.systemUptime - startedAt)
    }

    private enum ReadResult { case bytes(Data), unavailable, end }

    /// Nonblocking reads keep both curl streams flowing and let cancellation or
    /// a redirect interrupt a peer that has sent headers but no entity bytes.
    private static func readAvailable(_ descriptor: Int32) throws -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return .unavailable }
            guard count >= 0 else { throw currentError() }
            return count == 0 ? .end : .bytes(Data(buffer.prefix(count)))
        }
    }

    private static func currentError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

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
