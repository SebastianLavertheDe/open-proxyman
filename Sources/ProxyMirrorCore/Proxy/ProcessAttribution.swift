import Foundation
import AppKit
import Darwin

// MARK: - 按进程归因：把 127.0.0.1 上的客户端连接映射到发起进程（lsof 端口快照）

struct ProcessAppInfo: Equatable {
    let pid: Int
    let name: String
    let bundleID: String?
    let bundleURL: URL?
    let isIOSSimulator: Bool

    init(pid: Int, name: String, bundleID: String?, bundleURL: URL?, isIOSSimulator: Bool = false) {
        self.pid = pid; self.name = name; self.bundleID = bundleID; self.bundleURL = bundleURL
        self.isIOSSimulator = isIOSSimulator
    }

    static func == (lhs: ProcessAppInfo, rhs: ProcessAppInfo) -> Bool {
        lhs.pid == rhs.pid && lhs.name == rhs.name && lhs.isIOSSimulator == rhs.isIOSSimulator
    }
}

/// 引擎线程调用 attribute(peerPort:)；后台 lsof 快照解析后回调。
/// 定时刷新快照以追踪长连接的新端口。
final class ProcessAttribution: @unchecked Sendable {
    static let shared = ProcessAttribution()

    private let lock = NSLock()
    private var cache: [UInt16: ProcessAppInfo] = [:]     // 客户端临时端口 → App
    private var pending: [UInt16: [(ProcessAppInfo?) -> Void]] = [:]
    private var snapshotScheduled = false
    private var timer: DispatchSourceTimer?
    private var enabled = true

    private let snapshotQueue = DispatchQueue(label: "proxymirror.process-attribution", qos: .utility)
    private let snapshot: (() -> [UInt16: ProcessAppInfo])?
    private let connectionQueue = DispatchQueue(label: "proxymirror.connection-attribution", qos: .userInitiated)
    private let connectionFallbackQueue = DispatchQueue(label: "proxymirror.connection-attribution-fallback", qos: .utility)
    private struct ConnectionEndpoint: Hashable {
        let peerPort: UInt16
        let listenPort: UInt16

        var lsofAddress: String { "127.0.0.1:\(peerPort)->127.0.0.1:\(listenPort)" }
    }
    private struct ConnectionLookup {
        let endpoint: ConnectionEndpoint
        let deadline: DispatchTime
        let completion: (ProcessAppInfo?) -> Void
    }
    private var pendingConnections: [ConnectionLookup] = []
    private var pendingConnectionFallbacks: [ConnectionLookup] = []
    private static let maxPendingConnections = 256

    init(snapshot: (() -> [UInt16: ProcessAppInfo])? = nil) {
        self.snapshot = snapshot
    }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        lock.unlock()
        if on { startPolling() }
    }

    /// 引擎线程：查询客户端端口归属；已知则立即回调，未知则入队并异步解析
    func attribute(peerPort: UInt16, completion: @escaping (ProcessAppInfo?) -> Void) {
        lock.lock()
        guard enabled else { lock.unlock(); completion(nil); return }
        if let hit = cache[peerPort] {
            lock.unlock()
            completion(hit)
            return
        }
        pending[peerPort, default: []].append(completion)
        let schedule = !snapshotScheduled
        snapshotScheduled = true
        lock.unlock()
        if schedule { scheduleSnapshot() }
    }

    /// 同步查询（已在缓存时）
    func lookup(_ port: UInt16) -> ProcessAppInfo? {
        lock.lock(); defer { lock.unlock() }
        return cache[port]
    }

    func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    /// TLS policy needs the owner of this live socket, even if display attribution has cached the port.
    func attributeConnection(peerPort: Int, listenPort: Int, deadline: DispatchTime,
                             completion: @escaping (ProcessAppInfo?) -> Void) {
        guard let peer = UInt16(exactly: peerPort), let listener = UInt16(exactly: listenPort) else {
            completion(nil)
            return
        }
        let endpoint = ConnectionEndpoint(peerPort: peer, listenPort: listener)
        lock.lock()
        guard pendingConnections.count < Self.maxPendingConnections else { lock.unlock(); completion(nil); return }
        let schedule = pendingConnections.isEmpty
        pendingConnections.append(ConnectionLookup(endpoint: endpoint, deadline: deadline, completion: completion))
        lock.unlock()
        if schedule {
            // Give a burst of CONNECTs one fresh socket scan without delaying the normal TLS path.
            connectionQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { self.resolveConnections() }
        }
    }

    private func resolveConnections() {
        lock.lock()
        let requests = pendingConnections
        pendingConnections.removeAll(keepingCapacity: true)
        lock.unlock()

        let active = requests.filter { $0.deadline > .now() }
        let endpoints = Set(active.map(\.endpoint))
        let owners = active.map(\.deadline).max().map {
            Self.socketOwners(of: endpoints, deadline: $0)
        } ?? [:]
        var applications: [pid_t: ProcessAppInfo] = [:]
        var unresolved: [ConnectionLookup] = []
        for request in requests {
            guard request.deadline > .now() else { request.completion(nil); continue }
            guard let pid = owners[request.endpoint] else { unresolved.append(request); continue }
            // A descriptor inherited by different processes has no unique owner for TLS policy.
            guard pid > 0 else { request.completion(nil); continue }
            let info = applications[pid] ?? Self.application(for: pid)
            applications[pid] = info
            request.completion(request.deadline > .now() ? info : nil)
        }
        guard !unresolved.isEmpty else { return }

        lock.lock()
        let schedule = pendingConnectionFallbacks.isEmpty
        let available = Self.maxPendingConnections - pendingConnectionFallbacks.count
        pendingConnectionFallbacks.append(contentsOf: unresolved.prefix(available))
        lock.unlock()
        for request in unresolved.dropFirst(available) { request.completion(nil) }
        if schedule { connectionFallbackQueue.async { self.resolveConnectionFallbacks() } }
    }

    private static func socketOwners(of endpoints: Set<ConnectionEndpoint>, deadline: DispatchTime)
        -> [ConnectionEndpoint: pid_t] {
        let uid = geteuid()
        let kind = uid == 0 ? UInt32(PROC_ALL_PIDS) : UInt32(PROC_UID_ONLY)
        let pidSize = MemoryLayout<pid_t>.stride
        let capacity = proc_listpids(kind, uid, nil, 0)
        guard capacity > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / pidSize)
        let pidBytes = pids.withUnsafeMutableBytes {
            proc_listpids(kind, uid, $0.baseAddress, Int32($0.count))
        }
        guard pidBytes > 0 else { return [:] }

        var owners: [ConnectionEndpoint: pid_t] = [:]
        let loopback = in_addr_t(INADDR_LOOPBACK).bigEndian
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for pid in pids.prefix(Int(pidBytes) / pidSize) where pid > 0 {
            guard deadline > .now() else { break }
            let capacity = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard capacity > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(capacity) / fdSize + 1)
            let fdBytes = descriptors.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard fdBytes > 0 else { continue }
            for descriptor in descriptors.prefix(Int(fdBytes) / fdSize) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
                guard deadline > .now() else { return [:] }
                var socket = socket_fdinfo()
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize,
                      socket.psi.soi_kind == SOCKINFO_TCP else { continue }
                let tcp = socket.psi.soi_proto.pri_tcp
                let ip = tcp.tcpsi_ini
                // Mapped IPv6 sockets also use the IPv4 control block once connected to this listener.
                guard tcp.tcpsi_state == TSI_S_ESTABLISHED, ip.insi_vflag & UInt8(INI_IPV4) != 0,
                      ip.insi_laddr.ina_46.i46a_addr4.s_addr == loopback,
                      ip.insi_faddr.ina_46.i46a_addr4.s_addr == loopback,
                      let local = UInt16(exactly: ip.insi_lport), let remote = UInt16(exactly: ip.insi_fport) else { continue }
                let endpoint = ConnectionEndpoint(peerPort: UInt16(bigEndian: local), listenPort: UInt16(bigEndian: remote))
                guard endpoints.contains(endpoint) else { continue }
                if let previous = owners[endpoint], previous != pid { owners[endpoint] = 0 }
                else { owners[endpoint] = pid }
            }
        }
        return owners
    }

    private static func application(for pid: pid_t) -> ProcessAppInfo {
        var name = [CChar](repeating: 0, count: 64)
        let found = proc_name(pid, &name, UInt32(name.count)) > 0
        return withBundle(ProcessAppInfo(pid: Int(pid), name: found ? String(cString: name) : "未知进程",
                                         bundleID: nil, bundleURL: nil))
    }

    private func resolveConnectionFallbacks() {
        lock.lock()
        let requests = pendingConnectionFallbacks
        pendingConnectionFallbacks.removeAll(keepingCapacity: true)
        lock.unlock()
        let active = requests.filter { $0.deadline > .now() }
        let table: [String: ProcessAppInfo] = active.map(\.deadline).max().map { deadline in
            Self.lsofOwners(of: Set(active.map { $0.endpoint.lsofAddress }), deadline: deadline)
        } ?? [:]
        for request in requests {
            request.completion(request.deadline > .now() ? table[request.endpoint.lsofAddress] : nil)
        }
    }

    private static func lsofOwners(of endpoints: Set<String>, deadline: DispatchTime) -> [String: ProcessAppInfo] {
        let arguments = ["-b", "-w", "-nP", "-a", "-iTCP", "-sTCP:ESTABLISHED", "-Fpcn"]
        guard let data = lsof(arguments, deadline: deadline) else { return [:] }
        var pid: Int?
        var name = ""
        var owners: [String: ProcessAppInfo] = [:]
        var applications: [Int: ProcessAppInfo] = [:]
        var ambiguous: Set<String> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int(value); name = ""
            case "c": name = value
            case "n" where endpoints.contains(value):
                guard let pid, !ambiguous.contains(value) else { continue }
                if let previous = owners[value], previous.pid != pid {
                    owners.removeValue(forKey: value)
                    ambiguous.insert(value)
                    continue
                }
                let info = applications[pid] ?? withBundle(ProcessAppInfo(pid: pid, name: name, bundleID: nil, bundleURL: nil))
                applications[pid] = info
                owners[value] = info
            default: break
            }
        }
        return owners
    }

    private static func withBundle(_ info: ProcessAppInfo) -> ProcessAppInfo {
        var path = [CChar](repeating: 0, count: 4096)
        guard info.pid > 0, proc_pidpath(Int32(info.pid), &path, UInt32(path.count)) > 0 else { return info }
        let executablePath = String(cString: path)
        let simulator = isSimulatorExecutablePath(executablePath)
        var directory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        var application: Bundle?
        // Network helpers inside a .app belong to the outer application selected by the user.
        while directory.path != "/" {
            if directory.pathExtension.lowercased() == "app", let bundle = Bundle(url: directory),
               bundle.bundleIdentifier != nil {
                application = bundle
            }
            directory.deleteLastPathComponent()
        }
        guard let application, let bundleID = application.bundleIdentifier else {
            return ProcessAppInfo(pid: info.pid, name: info.name, bundleID: info.bundleID,
                                  bundleURL: info.bundleURL, isIOSSimulator: simulator)
        }
        let name = application.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? application.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? application.bundleURL.deletingPathExtension().lastPathComponent
        return ProcessAppInfo(pid: info.pid, name: name, bundleID: bundleID,
                              bundleURL: application.bundleURL, isIOSSimulator: simulator)
    }

    static func isSimulatorExecutablePath(_ path: String) -> Bool {
        let path = path.lowercased()
        return path.contains("/coresimulator/devices/")
            || (path.contains("/ios") && path.contains(".simruntime/contents/resources/runtimeroot/"))
            || path.contains("/coresimulator/volumes/ios_")
    }

    // MARK: 定时快照

    func startPolling() {
        lock.lock()
        if timer != nil { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: snapshotQueue)
        t.schedule(deadline: .now() + 1, repeating: 2.5)
        t.setEventHandler { [weak self] in self?.refreshSnapshot() }
        t.resume()
        timer = t
        lock.unlock()
    }

    func stopPolling() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    private func refreshSnapshot() {
        // 缓存过大时整体清理（端口不复用旧映射价值低）
        lock.lock()
        if cache.count > 4096 { cache.removeAll() }
        lock.unlock()
    }

    private func scheduleSnapshot() {
        snapshotQueue.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
            self?.resolvePending()
        }
    }

    private func resolvePending() {
        lock.lock()
        let ports = Array(pending.keys)
        lock.unlock()
        let table = snapshot?() ?? runLSOF()
        var byPID: [Int: ProcessAppInfo] = [:]
        var results: [UInt16: ProcessAppInfo] = [:]
        for port in ports {
            guard let info = table[port] else { continue }
            let resolved = byPID[info.pid] ?? Self.withBundle(info)
            byPID[info.pid] = resolved
            results[port] = resolved
        }
        var resolved: [([(ProcessAppInfo?) -> Void], ProcessAppInfo?)] = []
        lock.lock()
        for port in ports {
            let result = results[port] ?? ProcessAppInfo(pid: -1, name: "未知进程", bundleID: nil, bundleURL: nil)
            if enabled { cache[port] = result }
            resolved.append((pending.removeValue(forKey: port) ?? [], enabled ? result : nil))
        }
        let schedule = !pending.isEmpty
        snapshotScheduled = schedule
        lock.unlock()
        let callbacks = resolved
        DispatchQueue.main.async {
            for (completions, info) in callbacks { for completion in completions { completion(info) } }
        }
        if schedule { scheduleSnapshot() }
    }

    /// 执行 lsof 并解析 ESTABLISHED TCP 表：端口 → 进程
    func runLSOF() -> [UInt16: ProcessAppInfo] {
        Self.lsof(["-nP", "-iTCP", "-sTCP:ESTABLISHED"]).map(Self.parse) ?? [:]
    }

    private static func lsof(_ arguments: [String], deadline: DispatchTime? = nil) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let timeout = deadline.map { deadline in
                let work = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: work)
                return work
            }
            defer { timeout?.cancel() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 || task.terminationStatus == 1 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// 解析 lsof 输出：
    /// Safari   1234 user  22u  IPv4 0x...  0t0  TCP 127.0.0.1:54321->127.0.0.1:9090 (ESTABLISHED)
    static func parse(_ data: Data) -> [UInt16: ProcessAppInfo] {
        var result: [UInt16: ProcessAppInfo] = [:]
        guard let text = String(data: data, encoding: .utf8) else { return result }
        var listenPorts = Set(InterceptionConfig.shared.reverse.value.filter(\.enabled).map(\.listenPort))
        listenPorts.insert(AppSettings.shared.port)
        var seenPIDs: [Int: ProcessAppInfo] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("COMMAND") || line.isEmpty { continue }
            let cols = line.split(separator: " ").map(String.init)
            guard cols.count >= 9 else { continue }
            let name = cols[0]
            guard let pid = Int(cols[1]) else { continue }
            // 找 TCP 地址列
            guard let addrCol = cols.first(where: { $0.contains("->") || ($0.contains(":") && $0.hasPrefix("[")) || $0.contains("*:") }) else { continue }

            // 目标是本代理端口（9090 等）的连接，取其源端口记录归属
            let parts = addrCol.components(separatedBy: "->")
            guard parts.count == 2 else { continue }
            func hostPort(_ s: String) -> (String, UInt16)? {
                var str = s
                var portPart: String
                if str.hasPrefix("[") {
                    // [::1]:54321
                    guard let rb = str.firstIndex(of: "]") else { return nil }
                    let host = String(str[str.index(after: str.startIndex)..<rb])
                    let after = str.index(after: rb)
                    guard let colon = str.lastIndex(of: ":"), colon > after else { return nil }
                    let portPart = String(str[str.index(after: colon)...])
                    guard let port = UInt16(portPart) else { return nil }
                    return (host, port)
                } else if let colon = str.lastIndex(of: ":") {
                    let host = String(str[str.startIndex..<colon])
                    let portPart = String(str[str.index(after: colon)...])
                    guard let port = UInt16(portPart) else { return nil }
                    return (host, port)
                }
                return nil
            }
            guard let (_, remotePort) = hostPort(parts[1]),
                  let (srcHost, srcPort) = hostPort(parts[0]) else { continue }
            // 只关心连到本机代理的连接（remote 是 127.0.0.1:9090）
            guard srcHost == "127.0.0.1" || srcHost == "::1" || srcHost == "localhost" else { continue }
            if listenPorts.contains(remotePort), !listenPorts.contains(srcPort) {
                let info = seenPIDs[pid] ?? ProcessAppInfo(pid: pid, name: name, bundleID: nil, bundleURL: nil)
                seenPIDs[pid] = info
                result[srcPort] = info
            }
        }
        return result
    }

}

@MainActor
enum ClientApplicationIcons {
    private final class Entry {
        let image: NSImage?

        init(_ image: NSImage?) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()

    static func clearCache() { cache.removeAllObjects() }

    static func image(bundleID: String?, bundleURL: URL?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let key = (bundleURL?.path ?? bundleID) as NSString
        if let entry = cache.object(forKey: key) { return entry.image }

        let workspace = NSWorkspace.shared
        let url = bundleURL ?? workspace.urlForApplication(withBundleIdentifier: bundleID)
        let image = url.map { workspace.icon(forFile: $0.path) }
        cache.setObject(Entry(image), forKey: key)
        return image
    }
}
