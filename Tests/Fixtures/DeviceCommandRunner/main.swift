import Foundation
import ProxyMirrorFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct DeviceCommandRunnerChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-device-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var count = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        func expectFailure(_ wanted: DeviceCommandRunner.Failure, _ work: () throws -> Void) {
            do { try work(); preconditionFailure("Expected \(wanted)") }
            catch { expect(error as? DeviceCommandRunner.Failure == wanted, "Failure: \(error)") }
        }
        func isRunning(_ pid: pid_t) -> Bool {
            guard kill(pid, 0) == 0 else { return false }
            let state = try? DeviceCommandRunner.run("/bin/ps", ["-o", "stat=", "-p", String(pid)], timeout: 2)
            return state.map { !$0.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z") } ?? false
        }

        let large = try DeviceCommandRunner.run("/bin/sh", ["-c", "head -c 262144 /dev/zero >&2; printf done"], timeout: 3)
        expect(large.stdout == "done", "stdout after large stderr")
        expect(large.stderr.utf8.count == 262144, "stderr beyond pipe capacity")
        let quoted = "a'$(echo should-not-run) π"
        let echoed = try DeviceCommandRunner.run("/bin/sh", ["-c", "printf '%s' \"$1\"", "fixture", quoted])
        expect(echoed.stdout == quoted, "arguments remain literal")

        let before = ProcessInfo.processInfo.systemUptime
        let pids = directory.appendingPathComponent("pids")
        expectFailure(.timedOut) {
            _ = try DeviceCommandRunner.run("/bin/sh", ["-c", """
                trap '' TERM
                echo $$ > "$1"
                /bin/sh -c 'trap "" TERM; echo $$ >> "$1"; exec sleep 60' fixture "$1" &
                wait
                """, "fixture", pids.path], timeout: 0.2)
        }
        expect(ProcessInfo.processInfo.systemUptime - before < 2, "deadline includes forced termination")
        let identifiers = try String(contentsOf: pids, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        expect(identifiers.count == 2, "timeout fixture launched parent and descendant")
        for pid in identifiers { expect(!isRunning(pid), "timed-out process group is stopped: \(pid)") }
        var status: Int32 = 0
        expect(waitpid(identifiers[0], &status, WNOHANG) == -1 && errno == ECHILD, "timed-out command is reaped")

        let cancelled = DeviceCommandRunner.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancelled.cancel() }
        let cancellationStart = ProcessInfo.processInfo.systemUptime
        expectFailure(.cancelled) {
            _ = try DeviceCommandRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 60"], timeout: 5, cancellation: cancelled)
        }
        expect(ProcessInfo.processInfo.systemUptime - cancellationStart < 2, "cancellation interrupts a running command")
        let marker = directory.appendingPathComponent("never-started")
        expectFailure(.cancelled) {
            _ = try DeviceCommandRunner.run("/bin/sh", ["-c", "touch \"$1\"", "fixture", marker.path], cancellation: cancelled)
        }
        expect(!FileManager.default.fileExists(atPath: marker.path), "pre-cancelled command never starts")
        expectFailure(.outputTooLarge) {
            _ = try DeviceCommandRunner.run("/bin/sh", ["-c", "head -c 8192 /dev/zero"], outputLimit: 1024)
        }
        do {
            _ = try DeviceCommandRunner.run("/bin/sh", ["-c", "printf fixture-error >&2; exit 7"])
            preconditionFailure("Expected command failure")
        } catch DeviceCommandRunner.Failure.unsuccessful(let status, let detail) {
            expect(status == 7 && detail == "fixture-error", "exit status and stderr survive")
        }

        let orphan = directory.appendingPathComponent("orphan")
        _ = try DeviceCommandRunner.run("/bin/sh", ["-c", "sleep 60 & echo $! > \"$1\"", "fixture", orphan.path])
        let child = pid_t(try String(contentsOf: orphan, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        expect(!isRunning(child), "descendant is stopped after a successful launcher exits")
        print("PASS: \(count) native production device-command checks (both outputs, timeout, cancellation, process-group cleanup, reaping, bounds, status, literal arguments)")
    }
}
