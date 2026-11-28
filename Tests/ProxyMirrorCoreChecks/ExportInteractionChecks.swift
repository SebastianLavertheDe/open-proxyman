import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkExportInteractions(_ test: CoreAssertions) throws {
    try checkAPIExports(test)
    try checkImportedTrafficMetrics(test)
    try checkDiffSnapshots(test)
    try checkCapturedFailurePersistence(test)
    checkMCPPreferencesRuntime(test)
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tx = Transaction()
    tx.method = "GET"
    tx.host = "example.test"
    tx.requestBody = Data("hello".utf8)
    tx.requestBodyComplete = true
    tx.requestHeaders = HTTPHeaders([("X-Empty", "")])
    let command = ExportService.curlCommand(tx)
    // Exercise the generated shell command through a replacement curl, without making network requests.
    let curl = directory.appendingPathComponent("curl")
    try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: curl, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ["PATH": directory.path + ":/usr/bin:/bin"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let args = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    process.waitUntilExit()
    test.equal(process.terminationStatus, 0, "Copied cURL command is valid shell")
    test.expect(zip(args, args.dropFirst()).contains { $0 == "-X" && $1 == "GET" },
                "Copied GET with a body retains explicit method")
    test.expect(args.contains("X-Empty;"), "Copied cURL transmits an explicitly empty header")
    test.expect(args.contains("hello"), "Copied cURL preserves body")
    let tunnel = Transaction()
    tunnel.isTunnel = true
    tunnel.host = "::1"
    tunnel.port = 8443
    test.expect(ExportService.curlCommand(tunnel).contains("'https://[::1]:8443'"),
                "Copied tunnel cURL uses a valid bracketed IPv6 authority")
    let settings = AppSettings.shared
    let previousProxy = settings.appendProxyToCommands
    let previousPreserve = settings.preserveOriginalHeaders
    defer { settings.appendProxyToCommands = previousProxy; settings.preserveOriginalHeaders = previousPreserve }
    settings.appendProxyToCommands = false
    test.expect(!ExportService.curlCommand(tunnel).contains("--proxy"), "CONNECT copies respect the proxy preference")
    settings.appendProxyToCommands = true
    test.expect(ExportService.curlCommand(tunnel).contains("--proxy"), "CONNECT copies can include the proxy")
    tx.requestHeaders.append("Content-Length", "5")
    tx.requestHeaders.append("Accept-Encoding", "gzip")
    tx.requestHeaders.append("Content-Encoding", "identity")
    settings.preserveOriginalHeaders = false
    test.expect(!ExportService.curlCommand(tx).contains("Content-Length: 5"), "Default cURL copies omit captured framing")
    settings.preserveOriginalHeaders = true
    for header in ["Content-Length: 5", "Accept-Encoding: gzip", "Content-Encoding: identity"] {
        test.expect(ExportService.curlCommand(tx).contains(header), "cURL can preserve \(header)")
        test.expect(ExportService.httpieCommand(tx).contains(header), "HTTPie can preserve \(header)")
    }

    let csv = directory.appendingPathComponent("traffic.csv")
    try ExportService.writeCSV([tx], to: csv)
    test.expect(try String(contentsOf: csv).contains("http://example.test/"), "CSV export writes selected request")
    let har = directory.appendingPathComponent("traffic.har")
    try ExportService.writeHAR([SessionRecord(tx)], to: har)
    let reopened = try SessionFile.importHAR(Data(contentsOf: har))
    test.equal(reopened.first?.requestBody, tx.requestBody, "HAR export preserves request body")
    let invalid = directory.appendingPathComponent("missing/subdirectory/export")
    do {
        try ExportService.writeCSV([tx], to: invalid)
        test.expect(false, "CSV write failure must propagate")
    } catch { test.expect(true, "CSV write failure propagates") }
    do {
        try ExportService.writeHAR([SessionRecord(tx)], to: invalid)
        test.expect(false, "HAR write failure must propagate")
    } catch { test.expect(true, "HAR write failure propagates") }
}
