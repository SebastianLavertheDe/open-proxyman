import Darwin
import Foundation

enum BodyQuery {
    enum Language: String, CaseIterable, Identifiable {
        case jsonPath = "JSONPath"
        case jq

        var id: String { rawValue }
    }

    struct Result: Sendable {
        let text: String
        let matches: Int?
        let truncated: Bool
    }

    private static let outputLimit = 512 * 1024
    private static let diagnosticLimit = 4096

    static func run(_ expression: String, language: Language, data: Data) async throws -> Result {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { throw QueryError(Strings.Detail.enterAQueryExpression) }
        guard expression.utf8.count <= 8192 else { throw QueryError(Strings.Detail.theQueryExpressionIsTooLong) }
        guard data.count <= JSONPath.maxInputBytes else { throw QueryError(Strings.Detail.queriesSupportBodiesUpTo1Mib) }
        try Task.checkCancellation()
        switch language {
        case .jsonPath:
            return try jsonPath(expression, data: data)
        case .jq:
            return try await jq(expression, data: data)
        }
    }

    private static func jsonPath(_ expression: String, data: Data) throws -> Result {
        let values = try JSONPath.select(expression, from: data)
        var output = Data("[".utf8)
        for (index, value) in values.enumerated() {
            try Task.checkCancellation()
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            output.append(contentsOf: (index == 0 ? "\n  " : ",\n  ").utf8)
            let available = max(0, outputLimit - output.count)
            output.append(bytes.prefix(available))
            if bytes.count > available || output.count >= outputLimit {
                return Result(text: String(decoding: output.prefix(outputLimit), as: UTF8.self),
                              matches: values.count, truncated: true)
            }
        }
        output.append(contentsOf: (values.isEmpty ? "]" : "\n]").utf8)
        return Result(text: String(decoding: output.prefix(outputLimit), as: UTF8.self),
                      matches: values.count, truncated: output.count > outputLimit)
    }

    private static func jq(_ expression: String, data: Data) async throws -> Result {
        let paths = ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/opt/local/bin/jq", "/usr/bin/jq"]
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw QueryError(Strings.Detail.jqWasNotFoundInstallJqWithHomebrewOrMacportsOr)
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("ProxyMirror-query-\(UUID().uuidString)",
                                                                          isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.json")
        let filter = directory.appendingPathComponent("filter.jq")
        try data.write(to: input)
        try Data(expression.utf8).write(to: filter)

        let stdin = try FileHandle(forReadingFrom: input)
        defer { try? stdin.close() }
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--monochrome-output", "--unbuffered", "-L", directory.path, "-f", filter.path]
        process.currentDirectoryURL = directory
        process.environment = ["HOME": directory.path, "LANG": "C", "PATH": "/usr/bin:/bin"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        try setNonblocking(stdout.fileHandleForReading.fileDescriptor)
        try setNonblocking(stderr.fileHandleForReading.fileDescriptor)
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let deadline = DispatchTime.now() + .seconds(5)
        var output = Data()
        var diagnostics = Data()
        while true {
            try Task.checkCancellation()
            if try readAvailable(stdout, into: &output, upTo: outputLimit) {
                return Result(text: String(decoding: output, as: UTF8.self), matches: nil, truncated: true)
            }
            if try readAvailable(stderr, into: &diagnostics, upTo: diagnosticLimit) {
                throw QueryError(String(decoding: diagnostics, as: UTF8.self))
            }
            if !process.isRunning {
                // Drain any data written between the previous read and process exit.
                let truncated = try readAvailable(stdout, into: &output, upTo: outputLimit)
                _ = try readAvailable(stderr, into: &diagnostics, upTo: diagnosticLimit)
                guard process.terminationStatus == 0 else {
                    let message = String(decoding: diagnostics, as: UTF8.self)
                        .replacingOccurrences(of: filter.path, with: Strings.Detail.expression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw QueryError(message.isEmpty ? Strings.Detail.jqExitedWithStatus(Int(process.terminationStatus)) : message)
                }
                return Result(text: String(decoding: output, as: UTF8.self), matches: nil, truncated: truncated)
            }
            guard DispatchTime.now() < deadline else { throw QueryError(Strings.Detail.theJqQueryTimedOutNarrowTheQueryScope) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func setNonblocking(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw QueryError(Strings.Detail.unableToReadJqOutput)
        }
    }

    private static func readAvailable(_ pipe: Pipe, into result: inout Data, upTo limit: Int) throws -> Bool {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let available = limit - result.count
                result.append(contentsOf: buffer.prefix(min(count, available)))
                if count > available { return true }
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else if errno != EINTR {
                throw QueryError(Strings.Detail.failedToReadJqOutput)
            }
        }
    }
}
