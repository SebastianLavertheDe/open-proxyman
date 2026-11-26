import Darwin
import Foundation
import Security

@objc(ProxyMirrorSystemProxyServiceProtocol)
package protocol SystemProxyServiceProtocol {
    func enable(_ port: Int, hosts: [String]?, captureLocalRequests: Bool, reply: @escaping (String?) -> Void)
    func updateBypass(_ hosts: [String]?, captureLocalRequests: Bool, reply: @escaping (String?) -> Void)
    func restore(reply: @escaping (String?) -> Void)
    func disableOwned(reply: @escaping (String?) -> Void)
}

package enum SystemProxyService {
    package static func interface() -> NSXPCInterface {
        let result = NSXPCInterface(with: SystemProxyServiceProtocol.self)
        let arrays = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        result.setClasses(arrays, for: #selector(SystemProxyServiceProtocol.enable(_:hosts:captureLocalRequests:reply:)),
                          argumentIndex: 1, ofReply: false)
        result.setClasses(arrays, for: #selector(SystemProxyServiceProtocol.updateBypass(_:captureLocalRequests:reply:)),
                          argumentIndex: 0, ofReply: false)
        return result
    }

    package static let name = "com.sebastianLavertheDe.proxymirror.system-proxy"
    package static let appIdentifier = "com.sebastianLavertheDe.proxymirror"
    package static let helperName = "ProxyMirrorSystemProxyHelper"
    package static let version = "1.2.0"
    package static let executable = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(name)")
    package static let plist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(name).plist")
    package static let journal = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(name).recovery.plist")
    package static let lockPath = "/private/var/run/\(name).lock"

    package static func isValidHash(_ hash: String) -> Bool {
        hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    package static func codeHash(at url: URL, identifier: String) throws -> String {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], info[kSecCodeInfoIdentifier as String] as? String == identifier,
              let digest = info[kSecCodeInfoUnique as String] as? Data, digest.count == 20 else {
            throw SystemProxyError(.signatureInvalid)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    package static func requirement(identifier: String, hash: String) -> String {
        // Callers supply a constant identifier and a validated CodeDirectory hash.
        "identifier \"\(identifier)\" and cdhash H\"\(hash)\""
    }

    package static func daemonArguments(uid: uid_t, appHash: String) -> [String] {
        [executable.path, "--serve", String(uid), appHash]
    }

    package static func installedArguments() -> [String]? {
        guard let data = try? Data(contentsOf: plist),
              let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        return values["ProgramArguments"] as? [String]
    }

    package static func acquireLock() throws -> Int32 {
        let fd = Darwin.open(lockPath, O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SystemProxyError(.lockUnavailable) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw SystemProxyError(.busy)
        }
        return fd
    }
}
