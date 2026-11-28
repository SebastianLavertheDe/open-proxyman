import Foundation
import ProxyMirrorFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let prefix = "fd-check-"
if executable.lastPathComponent.hasPrefix(prefix),
   let descriptor = Int32(executable.lastPathComponent.dropFirst(prefix.count)) {
    errno = 0
    let closed = fcntl(descriptor, F_GETFD) == -1 && errno == EBADF
    print(closed ? "closed" : "inherited")
    exit(closed ? 0 : 1)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-process-fd-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let marker = open(directory.appendingPathComponent("parent-only").path, O_RDWR | O_CREAT | O_EXCL, mode_t(0o600))
precondition(marker >= 0)
defer { close(marker) }
// F_DUPFD deliberately clears CLOEXEC. The runner must close this descriptor
// even if another concurrent library temporarily created it without CLOEXEC.
let descriptor = fcntl(marker, F_DUPFD, 128)
precondition(descriptor >= 128 && fcntl(descriptor, F_GETFD) & FD_CLOEXEC == 0)
defer { close(descriptor) }
let probe = directory.appendingPathComponent(prefix + String(descriptor))
try FileManager.default.createSymbolicLink(at: probe, withDestinationURL: executable)
let preview = try PreviewProcessRunner.run(executable: probe, input: Data())
precondition(String(decoding: preview, as: UTF8.self) == "closed\n", "Preview child inherited a parent descriptor")
let device = try DeviceCommandRunner.run(probe.path, [])
precondition(device.stdout == "closed\n", "Device child inherited a parent descriptor")
precondition(fcntl(descriptor, F_GETFD) >= 0, "Closing child descriptors must not close parent descriptors")
print("Process support: 3 checks passed (actual preview and device runners)")
