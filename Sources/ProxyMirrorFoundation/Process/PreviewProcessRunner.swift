import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
import ProxyMirrorProcessSupport
#endif

/// Disposable preview execution; cancellation reaches the process group, and a
/// slot is returned only after its leader is reaped and descendants are killed.
package enum PreviewProcessRunner {
    package enum Failure: Error { case timedOut, outputLimit, unsuccessful(Int32, Data) }
    private static let slots = DispatchSemaphore(value: 2)

    package static func run(executable: URL, input: Data, timeout: TimeInterval = 2,
                            outputLimit: Int = 2 * 1024 * 1024,
                            cancellation: WorkCancellation = WorkCancellation()) throws -> Data {
        try cancellation.check()
        // Waiting previews remain cancellable; rapid view changes never leave a
        // stale worker occupying a slot or reject the current preview as busy.
        while slots.wait(timeout: .now() + .milliseconds(10)) != .success { try cancellation.check() }
        defer { slots.signal() }
        try cancellation.check()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input")
        let inputFD = open(inputURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard inputFD >= 0 else { throw currentError() }
        let inputFile = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? inputFile.close() }
        try inputFile.write(contentsOf: input)
        try inputFile.seek(toOffset: 0)
        var pipes: [Int32] = [0, 0]
        guard pipe(&pipes) == 0 else { throw currentError() }
        defer { close(pipes[0]); close(pipes[1]) }
        for descriptor in pipes {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw currentError() }
        }
        guard fcntl(pipes[0], F_SETFL, O_NONBLOCK) == 0 else { throw currentError() }
        let errors = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard errors >= 0 else { throw currentError() }
        defer { close(errors) }
        let pid = try spawn(executable.path, input: inputFD, output: pipes[1], errors: errors)
        // Only the child owns the writer after spawn; parent reads EOF promptly.
        close(pipes[1]); pipes[1] = -1
        var reaped = false, status: Int32 = 0
        defer {
            if !reaped { terminate(pid, status: &status) }
            _ = kill(-pid, SIGKILL)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
            while true {
                let count = buffer.withUnsafeMutableBytes { read(pipes[0], $0.baseAddress!, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
                guard count >= 0 else { throw currentError() }
                if count == 0 { break }
                guard count <= outputLimit - output.count else { throw Failure.outputLimit }
                output.append(contentsOf: buffer.prefix(count))
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited < 0 && errno != EINTR { throw currentError() }
            var event = pollfd(fd: pipes[0], events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&event, 1, 10)
        }
        // Drain the last pipe bytes written just before exit. No descendants may
        // keep an otherwise finished preview alive.
        while true {
            let count = buffer.withUnsafeMutableBytes { read(pipes[0], $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            guard count <= outputLimit - output.count else { throw Failure.outputLimit }
            output.append(contentsOf: buffer.prefix(count))
        }
        guard status == 0 else {
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            throw Failure.unsuccessful(code, output)
        }
        return output
    }

    private static func spawn(_ executable: String, input: Int32, output: Int32, errors: Int32) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t(), attributes = posix_spawnattr_t()
        #endif
        try check(posix_spawn_file_actions_init(&actions)); defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes)); defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, errors, STDERR_FILENO))
        #if os(Linux)
        // Match CLOEXEC_DEFAULT on macOS. Concurrent work may temporarily own
        // descriptors without CLOEXEC; a child must not inherit another job's
        // writable executable or keep another worker's pipe alive.
        try check(pm_posix_spawn_file_actions_addclosefrom(&actions, 3))
        #endif
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t(); sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        try check(posix_spawnattr_setflags(&attributes, flags))
        let argv = [strdup(executable), nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        try argv.withUnsafeBufferPointer { argv in
            try env.withUnsafeBufferPointer { env in
                try check(posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, env.baseAddress!))
            }
        }
        return pid
    }

    private static func terminate(_ pid: pid_t, status: inout Int32) {
        _ = kill(-pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        _ = kill(-pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    private static func check(_ value: Int32) throws { if value != 0 { throw POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO) } }
    private static func currentError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
