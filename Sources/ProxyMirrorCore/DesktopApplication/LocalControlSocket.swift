import Darwin
import Foundation

enum LocalControlSocket {
    static let requestLimit = 24 * 1024 * 1024
    static let responseLimit = 64 * 1024 * 1024

    private static var directory: URL {
        CertificateAuthority.applicationSupport.appendingPathComponent(".control", isDirectory: true)
    }
    private static var endpoint: String { directory.appendingPathComponent("socket").path }

    static func request(_ data: Data) throws -> Data {
        let fd = try makeSocket()
        defer { Darwin.close(fd) }
        try configure(fd)
        try withAddress { address, length in
            guard Darwin.connect(fd, address, length) == 0 else {
                if errno == ENOENT || errno == ECONNREFUSED {
                    throw LocalControlError.offline
                }
                throw socketError("无法连接本机控制接口")
            }
        }
        try verifyPeer(fd)
        try write(data, to: fd)
        guard Darwin.shutdown(fd, SHUT_WR) == 0 else { throw socketError("发送命令失败") }
        return try read(from: fd, limit: responseLimit)
    }

    static func start(handler: @escaping (Data) -> Data) throws -> DispatchSourceRead {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw socketError("无法创建本机控制目录")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw LocalControlError.failed("本机控制目录必须由当前用户独占访问。")
        }

        let lock = Darwin.open(directory.appendingPathComponent("lock").path,
                               O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw socketError("无法打开本机控制锁") }
        var keepLock = false
        defer { if !keepLock { Darwin.close(lock) } }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw LocalControlError.failed("另一个 ProxyMirror 实例已启动本机控制接口。")
        }

        let fd = try makeSocket()
        var active = false
        var bound = false
        defer {
            if !active {
                Darwin.close(fd)
                if bound { _ = unlink(endpoint) }
            }
        }
        if unlink(endpoint) != 0, errno != ENOENT { throw socketError("无法清理本机控制端点") }
        try withAddress { address, length in
            guard Darwin.bind(fd, address, length) == 0 else { throw socketError("无法绑定本机控制接口") }
        }
        bound = true
        guard chmod(endpoint, 0o600) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0, listen(fd, 8) == 0 else {
            throw socketError("无法启动本机控制接口")
        }

        let queue = DispatchQueue(label: "com.proxymirror.local-control")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            let reply: Data
            do {
                guard fcntl(client, F_SETFL, 0) == 0, fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw socketError("无法配置本机控制连接")
                }
                try configure(client)
                try verifyPeer(client)
                let data = try read(from: client, limit: requestLimit)
                reply = handler(data)
            } catch {
                reply = LocalControlError.failed(error.localizedDescription).encoded
            }
            try? write(reply, to: client)
        }
        let path = endpoint
        source.setCancelHandler {
            Darwin.close(fd)
            _ = unlink(path)
            Darwin.close(lock)
        }
        keepLock = true
        active = true
        source.resume()
        return source
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("无法创建本机控制连接") }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let error = socketError("无法配置本机控制连接")
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private static func configure(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var noSignal: Int32 = 1
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLength) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLength) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw socketError("无法设置本机控制连接选项")
        }
    }

    private static func verifyPeer(_ fd: Int32) throws {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(fd, &user, &group) == 0, user == geteuid() else {
            throw LocalControlError.failed("本机控制接口只接受同一用户的连接。")
        }
    }

    private static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(endpoint.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalControlError.failed("本机控制接口路径过长。请使用较短的应用数据目录。")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(2 + bytes.count + 1)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let length = socklen_t(address.sun_len)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw socketError("发送本机控制数据失败") }
                offset += count
            }
        }
    }

    private static func read(from fd: Int32, limit: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw socketError("读取本机控制数据失败") }
            if count == 0 { return result }
            guard count <= limit - result.count else { throw LocalControlError.failed("本机控制数据超出限制。") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func socketError(_ message: String) -> LocalControlError {
        let reason = String(cString: strerror(errno))
        return .failed("\(message)（\(reason)）。")
    }
}
