import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs a device tool in its own process group. Private output files avoid pipe
/// deadlocks; cancellation and deadlines terminate and reap the launched command.
package enum DeviceCommandRunner {
    package final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        package init() {}
        package func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        package var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    package struct Output { package let stdout: String; package let stderr: String }

    package enum Failure: LocalizedError, Equatable {
        case timedOut, cancelled, outputTooLarge, unsuccessful(Int32, String)
        package var errorDescription: String? {
            switch self {
            case .timedOut: return "The device command exceeded its time limit."
            case .cancelled: return "The device command was cancelled."
            case .outputTooLarge: return "The device command output exceeded its size limit."
            case .unsuccessful(let status, let detail):
                return "The device command failed (status \(status)). \(detail)"
            }
        }
    }

    package static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30,
                    cancellation: Cancellation? = nil, outputLimit: Int = 4 * 1024 * 1024) throws -> Output {
        guard !cancellationIsRequested(cancellation) else { throw Failure.cancelled }
        guard timeout.isFinite, timeout > 0 else { throw Failure.timedOut }
        guard outputLimit >= 0 else { throw Failure.outputTooLarge }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyMirror-Device-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = try outputFile(directory.appendingPathComponent("stdout"))
        defer { try? stdout.close() }
        let stderr = try outputFile(directory.appendingPathComponent("stderr"))
        defer { try? stderr.close() }
        let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw currentError() }
        defer { close(input) }

        let pid = try spawn(executable, arguments, input: input,
                            stdout: stdout.fileDescriptor, stderr: stderr.fileDescriptor)
        // Do not leave descendants holding output handles or running after their
        // launcher exits; this group belongs exclusively to this invocation.
        var reaped = false
        var status: Int32 = 0
        defer {
            kill(-pid, SIGKILL)
            if !reaped { while waitpid(pid, &status, 0) == -1, errno == EINTR {} }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var failure: Failure?
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited == -1 {
                if errno == EINTR { continue }
                throw currentError()
            }
            if cancellationIsRequested(cancellation) { failure = .cancelled }
            else if ProcessInfo.processInfo.systemUptime - started >= timeout { failure = .timedOut }
            else if try fileSize(stdout) > outputLimit || fileSize(stderr) > outputLimit { failure = .outputTooLarge }
            if failure != nil {
                terminate(pid, status: &status)
                reaped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let failure { throw failure }
        let output = try read(stdout, limit: outputLimit)
        let errors = try read(stderr, limit: outputLimit)
        // A zero wait status is a normal exit(0); signal termination is nonzero.
        guard status == 0 else {
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            throw Failure.unsuccessful(code, String((errors + output).prefix(8192)))
        }
        return Output(stdout: output, stderr: errors)
    }

    private static func cancellationIsRequested(_ cancellation: Cancellation?) -> Bool {
        cancellation?.isCancelled == true
    }

    private static func outputFile(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw currentError() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func fileSize(_ file: FileHandle) throws -> Int {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { throw currentError() }
        return Int(info.st_size)
    }

    private static func read(_ file: FileHandle, limit: Int) throws -> String {
        try file.seek(toOffset: 0)
        let bytes = try file.read(upToCount: max(0, limit) + 1) ?? Data()
        guard bytes.count <= limit else { throw Failure.outputTooLarge }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func spawn(_ executable: String, _ arguments: [String],
                              input: Int32, stdout: Int32, stderr: Int32) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
        #if os(Linux)
        try check(posix_spawn_file_actions_addclosefrom_np(&actions, 3))
        #endif
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        try check(posix_spawnattr_setflags(&attributes, flags))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        try argv.withUnsafeBufferPointer { argv in
            try environment.withUnsafeBufferPointer { environment in
                try check(posix_spawn(&pid, executable, &actions, &attributes,
                                      argv.baseAddress!, environment.baseAddress!))
            }
        }
        return pid
    }

    private static func terminate(_ pid: pid_t, status: inout Int32) {
        kill(-pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        kill(-pid, SIGKILL)
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    private static func check(_ status: Int32) throws {
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    }
    private static func currentError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
