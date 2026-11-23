import Foundation
import Darwin

/// Uses Charles' documented local `convert` command for its native formats.
/// XML and JSON exports continue to be read directly without Charles.
enum CharlesSessionConverter {
    static func convertToHAR(_ source: URL) throws -> Data {
        let candidates = [UserDefaults.standard.string(forKey: "import.charlesExecutable"),
            "/Applications/Charles.app/Contents/MacOS/Charles",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Charles.app/Contents/MacOS/Charles").path].compactMap { $0 }
        guard let executable = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CharlesImport.ImportError(OperationIssue.charlesSessionConverterThisIsANativeCharlesBinarySessionInstall)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMirror-Charles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input." + source.pathExtension)
        let output = directory.appendingPathComponent("converted.har")
        let logURL = directory.appendingPathComponent("convert.log")
        try FileManager.default.copyItem(at: source, to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        try PrivateAppFile.write(Data(), to: logURL)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["convert", input.path, output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log; process.standardError = log
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(60), execute: timeout)
        defer { timeout.cancel() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CharlesImport.ImportError(OperationIssue.charlesSessionConverterCharlesConversionFailedOrExceeded60SecondsOpen) }
        let file = try FileHandle(forReadingFrom: output)
        defer { try? file.close() }
        let limit = 128 * 1024 * 1024
        var data = Data()
        while let chunk = try file.read(upToCount: 65536), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else { throw CharlesImport.ImportError(OperationIssue.charlesSessionConverterTheConvertedHarExceeds128MibSplitThe) }
            data.append(chunk)
        }
        return data
    }
}
