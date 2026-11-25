import AppKit
import Foundation

/// Each launch carries its own proxy configuration. Dedicated browser profiles
/// avoid changing an already-running browser or the user's existing preferences.
enum ProxyAutomation {
    enum Target: String, CaseIterable, Identifiable {
        case terminal, iTerm, ghostty
        case customTerminal, chrome, firefox, electron
        var localizedTitle: String {
            switch self {
            case .terminal: return "Apple Terminal"
            case .iTerm: return "iTerm2"
            case .ghostty: return "Ghostty"
            case .customTerminal: return Strings.Errors.automationOtherTerminal
            case .chrome: return "Google Chrome"
            case .firefox: return "Firefox"
            case .electron: return "Electron App"
            }
        }
        var id: String { rawValue }
        var needsApplication: Bool { self == .customTerminal || self == .electron }
    }

    struct LaunchPlan {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let files: [(URL, Data, Int)]
        let message: String
    }

    struct Failure: LocalizedError, OperationIssueProviding {
        let operationIssue: OperationIssue
        init(_ issue: OperationIssue) { operationIssue = issue }
        init(_ message: String) { operationIssue = .technical(message) }
        var message: String { operationIssue.diagnostic }
        var text: String { operationIssue.diagnostic }
        var errorDescription: String? { operationIssue.diagnostic }
        init(text: OperationIssue) { operationIssue = text }
        init(text: String) { operationIssue = .technical(text) }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func environment(port: UInt16, certificate: URL) -> [String: String] {
        let address = "http://127.0.0.1:\(port)"
        return ["HTTP_PROXY": address, "HTTPS_PROXY": address, "http_proxy": address, "https_proxy": address,
                "ALL_PROXY": "socks5h://127.0.0.1:\(port)", "all_proxy": "socks5h://127.0.0.1:\(port)",
                "NO_PROXY": "", "no_proxy": "", "NODE_USE_ENV_PROXY": "1", "NODE_EXTRA_CA_CERTS": certificate.path,
                "SSL_CERT_FILE": certificate.path, "REQUESTS_CA_BUNDLE": certificate.path, "CURL_CA_BUNDLE": certificate.path]
    }

    static func plan(_ target: Target, port: UInt16, certificate: URL, application: URL? = nil,
                     support: URL = CertificateAuthority.applicationSupport) throws -> LaunchPlan {
        guard port > 0 else { throw Failure(text: OperationIssue.proxyAutomationStartTheProxyListenerFirst) }
        let environment = environment(port: port, certificate: certificate)
        let directory = support.appendingPathComponent("Automation", isDirectory: true)
        let launch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let script = launch.appendingPathComponent("ProxyMirror.command")
        let exports = environment.keys.sorted().map { "export \($0)=\(shellQuote(environment[$0]!))" }.joined(separator: "\n")
        let scriptText = "#!/bin/zsh\n\(exports)\nprintf '%s\\n' \(shellQuote("ProxyMirror → 127.0.0.1:\(port)"))\nexec /bin/zsh -il\n"
        let files = [(script, Data(scriptText.utf8), 0o700)]
        let terminalMessage = Strings.Errors.proxyAutomationOpenedATerminalWithProxyAndCaEnvironment
        switch target {
        case .terminal:
            return LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", "tell application \"Terminal\"\nactivate\ndo script \(appleScriptQuote("/bin/zsh " + shellQuote(script.path)))\nend tell"],
                environment: environment, files: files, message: terminalMessage)
        case .iTerm:
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil else {
                throw Failure(text: OperationIssue.proxyAutomationInstallIterm2First)
            }
            return LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", "tell application \"iTerm\"\nactivate\ncreate window with default profile command \(appleScriptQuote("/bin/zsh " + shellQuote(script.path)))\nend tell"],
                environment: environment, files: files, message: terminalMessage)
        case .ghostty, .customTerminal:
            let app = application ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
            guard let app, app.pathExtension == "app" else { throw Failure(text: OperationIssue.proxyAutomationSelectAnInstalledTerminalApp) }
            return LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-na", app.path, "--args", "-e", "/bin/zsh", script.path],
                environment: environment, files: files,
                message: terminalMessage + (target == .customTerminal ? " " + Strings.Errors.proxyAutomationTheSelectedTerminalMustSupportTheECommand : ""))
        case .chrome, .electron:
            let app = target == .chrome
                ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") : application
            guard let app, app.pathExtension == "app" else { throw Failure(text: OperationIssue.proxyAutomationSelectAnInstalledApp(target.localizedTitle)) }
            let profile = launch.appendingPathComponent("BrowserProfile", isDirectory: true)
            let arguments = ["-na", app.path, "--args", "--proxy-server=http://127.0.0.1:\(port)",
                             "--proxy-bypass-list=<-loopback>", "--user-data-dir=\(profile.path)"]
            return LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: arguments,
                environment: environment, files: [(profile.appendingPathComponent(".proxymirror"), Data(), 0o600)],
                message: Strings.Errors.proxyAutomationStartedAnIsolatedProfileUsingTheProxymirrorProxy)
        case .firefox:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.mozilla.firefox") else {
                throw Failure(text: OperationIssue.proxyAutomationInstallFirefoxFirst)
            }
            let profile = launch.appendingPathComponent("FirefoxProfile", isDirectory: true)
            let preferences = """
            user_pref("network.proxy.type", 1);
            user_pref("network.proxy.http", "127.0.0.1");
            user_pref("network.proxy.http_port", \(port));
            user_pref("network.proxy.ssl", "127.0.0.1");
            user_pref("network.proxy.ssl_port", \(port));
            user_pref("network.proxy.no_proxies_on", "");
            user_pref("network.proxy.allow_hijacking_localhost", true);
            user_pref("security.enterprise_roots.enabled", true);
            """
            return LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-na", app.path, "--args", "-no-remote", "-profile", profile.path, "about:blank"],
                environment: environment, files: [(profile.appendingPathComponent("user.js"), Data(preferences.utf8), 0o600)],
                message: Strings.Errors.proxyAutomationStartedAnIsolatedFirefoxProfileWithTheProxy)
        }
    }

    private static func prepareLaunch(_ target: Target, port: UInt16, certificate: URL,
                                      application: URL?) throws -> (Process, FileHandle, URL, String) {
        let plan = try plan(target, port: port, certificate: certificate, application: application)
        for (url, data, mode) in plan.files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, supplied in supplied }
        let logURL = CertificateAuthority.applicationSupport.appendingPathComponent("Automation/launch.log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        process.standardOutput = log
        process.standardError = log
        return (process, log, logURL, plan.message)
    }

    /// CLI/MCP cannot hold the app's synchronous control socket until a system
    /// permission dialog closes. Report dispatch, and retain exit diagnostics.
    @discardableResult
    static func launch(_ target: Target, port: UInt16, certificate: URL, application: URL? = nil) throws -> String {
        let (process, log, logURL, _) = try prepareLaunch(target, port: port, certificate: certificate, application: application)
        process.terminationHandler = { completed in
            try? log.close()
            if completed.terminationStatus != 0 {
                NSLog("[ProxyMirror] Automation launch failed (\(completed.terminationStatus)); see \(logURL.path)")
            }
        }
        do { try process.run() } catch { try? log.close(); throw error }
        return OperationIssue.proxyAutomationSubmittedTheLaunchRequestLaunchLog(target.rawValue, String(logURL.path)).diagnostic
    }

    /// The interactive dashboard can await the launcher and show permission or
    /// application errors without blocking the main thread.
    static func launchAndWait(_ target: Target, port: UInt16, certificate: URL, application: URL? = nil) async throws -> String {
        let (process, log, logURL, message) = try prepareLaunch(target, port: port, certificate: certificate, application: application)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            process.terminationHandler = { completed in
                try? log.close()
                if completed.terminationStatus == 0 {
                    continuation.resume(returning: message)
                } else {
                    let details = (try? Data(contentsOf: logURL)).map {
                        String(decoding: $0.suffix(2048), as: UTF8.self)
                    } ?? ""
                    continuation.resume(throwing: Failure(text: OperationIssue.proxyAutomationLaunchFailed(Int(completed.terminationStatus), String(details))))
                }
            }
            do { try process.run() } catch {
                try? log.close()
                continuation.resume(throwing: error)
            }
        }
    }
    /// Chromium only accepts proxy flags at process startup. Preserve the current profile when Chrome is closed.
    static func launchChromeCurrentProfile(port: UInt16) async throws -> String {
        guard port > 0 else { throw Failure(text: OperationIssue.proxyAutomationStartTheProxyListenerFirst) }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else {
            throw Failure(Strings.Guides.setupCloseChromeFirst)
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw Failure(Strings.Guides.setupChromeMissing)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", app.path, "--args", "--proxy-server=http://127.0.0.1:\(port)", "--proxy-bypass-list=<-loopback>"]
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completed in
                if completed.terminationStatus == 0 { continuation.resume(returning: Strings.Guides.setupBrowserStarted) }
                else { continuation.resume(throwing: Failure(Strings.Guides.setupBrowserFailed)) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

}
