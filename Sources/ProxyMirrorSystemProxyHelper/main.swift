import Darwin
import Dispatch
import Foundation
import ProxyMirrorSystemProxy

private final class Service: NSObject, NSXPCListenerDelegate {
    private struct Lease {
        var owner: UUID?
        let settings: SystemProxySettings
        let lock: Int32
    }

    private let uid: uid_t
    private let queue = DispatchQueue(label: "ProxyMirror.SystemProxyService")
    private var lease: Lease?
    private var recoveryScheduled = false

    init(uid: uid_t) { self.uid = uid }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The listener also verifies the code signature of each incoming connection.
        guard connection.effectiveUserIdentifier == uid else { return false }
        let peer = Peer(service: self)
        connection.exportedInterface = SystemProxyService.interface()
        connection.exportedObject = peer
        connection.invalidationHandler = { [weak self] in self?.disconnected(peer) }
        connection.resume()
        return true
    }

    func enable(_ port: Int, bypassHosts: [String]? = nil, for peer: Peer, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                guard let port = UInt16(exactly: port), port >= 1024 else {
                    throw SystemProxyError("系统代理端口无效。")
                }
                guard !peer.closed, self.lease == nil else {
                    throw SystemProxyError("另一个 ProxyMirror 实例正在接管或恢复系统代理。")
                }
                let lock = try SystemProxyService.acquireLock()
                // Never take a new snapshot over a previous, un-restored takeover.
                let pending: SystemProxySettings?
                do {
                    pending = try SystemProxySettings.pendingRestore(at: SystemProxyService.journal)
                } catch {
                    Darwin.close(lock)
                    throw error
                }
                if let pending {
                    do {
                        try pending.restore()
                    } catch {
                        self.lease = Lease(owner: nil, settings: pending, lock: lock)
                        self.scheduleRecovery()
                        throw error
                    }
                }
                if let bypassHosts, let issue = SystemProxyBypassList.validationError(bypassHosts) {
                    Darwin.close(lock)
                    throw SystemProxyError(issue)
                }
                try self.enable(port, bypassHosts: bypassHosts, owner: peer.id, holding: lock)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    private func enable(_ port: UInt16, bypassHosts: [String]?, owner: UUID, holding lock: Int32) throws {
        let settings = SystemProxySettings(port: port, journal: SystemProxyService.journal, bypassHosts: bypassHosts)
        lease = Lease(owner: owner, settings: settings, lock: lock)
        do {
            try settings.enable()
        } catch {
            lease?.owner = nil
            if restoreLease() != nil { scheduleRecovery() }
            throw error
        }
    }

    func restore(for peer: Peer, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let lease = self.lease else { reply(nil); return }
            guard lease.owner == peer.id else { reply("当前连接没有接管系统代理。"); return }
            reply(self.restoreLease())
        }
    }

    func updateBypass(_ hosts: [String]?, for peer: Peer, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let lease = self.lease, lease.owner == peer.id, !peer.closed else {
                reply("当前连接没有接管系统代理。"); return
            }
            do { try lease.settings.updateBypass(hosts); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }

    private func disconnected(_ peer: Peer) {
        queue.async {
            peer.closed = true
            guard self.lease?.owner == peer.id else { return }
            self.lease?.owner = nil
            self.recoverIfNeeded()
        }
    }

    // Serialized with takeover and normal restoration.
    private func restoreLease() -> String? {
        guard let lease else { return nil }
        do {
            try lease.settings.restore()
            Darwin.close(lease.lock)
            self.lease = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func recoverOnLaunch() {
        queue.async { self.recoverIfNeeded() }
    }

    private func recoverIfNeeded() {
        guard lease?.owner == nil else { return }
        if lease == nil, FileManager.default.fileExists(atPath: SystemProxyService.journal.path) {
            do {
                let lock = try SystemProxyService.acquireLock()
                do {
                    if let pending = try SystemProxySettings.pendingRestore(at: SystemProxyService.journal) {
                        lease = Lease(owner: nil, settings: pending, lock: lock)
                    } else {
                        Darwin.close(lock)
                    }
                } catch {
                    Darwin.close(lock)
                    throw error
                }
            } catch {
                NSLog("[ProxyMirror] 系统代理恢复等待重试：%@", error.localizedDescription)
                scheduleRecovery()
                return
            }
        }
        if let message = restoreLease() {
            NSLog("[ProxyMirror] 系统代理恢复等待重试：%@", message)
            scheduleRecovery()
        }
    }

    private func scheduleRecovery() {
        guard !recoveryScheduled else { return }
        recoveryScheduled = true
        queue.asyncAfter(deadline: .now() + .seconds(2)) {
            self.recoveryScheduled = false
            self.recoverIfNeeded()
        }
    }

    func terminate() {
        queue.async {
            for attempt in 0..<3 {
                if self.restoreLease() == nil { exit(EXIT_SUCCESS) }
                if attempt < 2 { sleep(1) }
            }
            // Leave the journal so launchd or the next installer can recover the settings.
            exit(EXIT_FAILURE)
        }
    }
}

private final class Peer: NSObject, SystemProxyServiceProtocol {
    let id = UUID()
    var closed = false // Accessed only on the service queue.
    private let service: Service

    init(service: Service) { self.service = service }

    func enable(_ port: Int, reply: @escaping (String?) -> Void) {
        service.enable(port, for: self, reply: reply)
    }

    func enableWithBypass(_ port: Int, hosts: [String], reply: @escaping (String?) -> Void) {
        service.enable(port, bypassHosts: hosts, for: self, reply: reply)
    }

    func updateBypass(_ hosts: [String]?, reply: @escaping (String?) -> Void) {
        service.updateBypass(hosts, for: self, reply: reply)
    }

    func restore(reply: @escaping (String?) -> Void) {
        service.restore(for: self, reply: reply)
    }
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard geteuid() == 0 else { throw SystemProxyError("系统代理服务需要管理员授权。") }
    // The one-time installer may start with only its effective UID elevated.
    guard getuid() == 0 || setuid(0) == 0 else {
        throw SystemProxyError("无法启动已授权的系统代理安装程序。")
    }
    umask(0o077)
    if arguments.count == 2, arguments[1] == "--uninstall" {
        try Installer.uninstall()
        return
    }
    guard arguments.count == 4, let uid = uid_t(arguments[2]), uid > 0,
          SystemProxyService.isValidHash(arguments[3]) else {
        throw SystemProxyError("系统代理服务参数无效。")
    }
    let hash = arguments[3]
    switch arguments[1] {
    case "--install":
        try Installer.install(from: URL(fileURLWithPath: arguments[0]), uid: uid, appHash: hash)
    case "--serve":
        let service = Service(uid: uid)
        let listener = NSXPCListener(machServiceName: SystemProxyService.name)
        listener.setConnectionCodeSigningRequirement(
            SystemProxyService.requirement(identifier: SystemProxyService.appIdentifier, hash: hash))
        listener.delegate = service
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler { service.terminate() }
        termination.resume()
        service.recoverOnLaunch()
        listener.resume()
        withExtendedLifetime((listener, termination)) { dispatchMain() }
    default:
        throw SystemProxyError("系统代理服务参数无效。")
    }
}

do {
    try run()
} catch {
    let message = "[ProxyMirror] 系统代理服务：\(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
