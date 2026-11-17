import Darwin
import Foundation
import NIOCore
import NIOSSL

/// NSS key log for TLS sessions terminated by this proxy. The destination is opt-in and owner-only.
final class TLSKeyLog: @unchecked Sendable {
    static let shared = TLSKeyLog()
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "ProxyMirror.TLSKeyLog", qos: .utility)
    private let maxPendingLines = 512
    private var accepting = false
    private var generation: UInt64 = 0
    private var pending = 0
    private var dropped = 0
    // Only accessed on writer.
    private var descriptor: Int32 = -1

    static let callback: NIOSSLKeyLogCallback = { line in shared.append(line) }

    func start(at url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, fchmod(fd, 0o600) == 0 else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        lock.lock()
        generation &+= 1
        accepting = true
        writer.async {
            if self.descriptor >= 0 { Darwin.close(self.descriptor) }
            self.descriptor = fd
        }
        lock.unlock()
    }

    func stop() {
        let finished = DispatchSemaphore(value: 0)
        lock.lock()
        accepting = false
        let lost = dropped
        dropped = 0
        writer.async {
            if self.descriptor >= 0 { Darwin.close(self.descriptor) }
            self.descriptor = -1
            if lost > 0 { NSLog("[ProxyMirror] TLS key log dropped %d lines", lost) }
            finished.signal()
        }
        lock.unlock()
        finished.wait()
    }

    private func append(_ line: ByteBuffer) {
        guard line.readableBytes > 0, line.readableBytes <= 1024 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        guard pending < maxPendingLines else { dropped += 1; return }
        pending += 1
        let generation = self.generation
        let lost = dropped
        dropped = 0
        let bytes = Array(line.readableBytesView)
        writer.async {
            if lost > 0 { NSLog("[ProxyMirror] TLS key log dropped %d lines", lost) }
            self.write(bytes, generation: generation)
            self.lock.lock()
            self.pending -= 1
            self.lock.unlock()
        }
    }

    private func write(_ line: [UInt8], generation: UInt64) {
        guard descriptor >= 0 else { return }
        var bytes = line
        if bytes.last != 10 { bytes.append(10) }
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if result > 0 {
                    offset += result
                } else if result == 0 || errno != EINTR {
                    Darwin.close(descriptor)
                    descriptor = -1
                    lock.lock()
                    if self.generation == generation { accepting = false }
                    lock.unlock()
                    NSLog("[ProxyMirror] TLS key log write failed")
                    break
                }
            }
        }
    }
}
