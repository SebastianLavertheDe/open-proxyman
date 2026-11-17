import Darwin
import Foundation
import ProxyMirrorCoreChecks
@testable import ProxyMirrorCore

private struct BenchmarkError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

private struct Measurement: Encodable {
    let scenario: String
    let samplesMs: [Double]
    let medianMs: Double
    let p95Ms: Double

    init(scenario: String, samplesMs: [Double]) {
        self.scenario = scenario
        self.samplesMs = samplesMs
        let sorted = samplesMs.sorted()
        medianMs = sorted[(sorted.count - 1) / 2]
        p95Ms = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
    }
}

private func elapsed(_ operation: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    operation()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

@MainActor
func runCoreBenchmarks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-bench-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let table = TrafficTableWorkload(directory: directory)
    var timings: [Double] = []
    for round in 0...5 {
        for iteration in 0..<100 {
            let time = elapsed { table.filterAndSort(iteration: iteration) }
            guard table.isCorrect(iteration: iteration) else {
                throw BenchmarkError("Filtering or sorting returned unexpected rows")
            }
            if round > 0 { timings.append(time) }
        }
    }
    var measurements = [Measurement(scenario: "filter-sort-5000", samplesMs: timings)]

    for chunks in [128, 256, 512] {
        let body = BodyAppendWorkload(chunks: chunks)
        var samples: [Double] = []
        for round in 0...5 {
            body.prepare()
            let time = elapsed { body.append() }
            guard body.isCorrect else { throw BenchmarkError("Captured body does not match the input") }
            if round > 0 { samples.append(time) }
        }
        measurements.append(Measurement(scenario: "capture-append-\(chunks)x16KiB", samplesMs: samples))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(measurements), as: UTF8.self))
}

private final class BenchmarkSink: TrafficSink {
    private let lock = NSLock()
    private var count = 0
    var captured: Int { lock.withLock { count } }

    func transactionCreated(_ transaction: Transaction) {
        lock.withLock { count += 1 }
    }

    func transactionUpdated(_ transaction: Transaction) {}
}

@MainActor
func runProxyBenchmark(recording: Bool) throws {
    guard let path = ProcessInfo.processInfo.environment["PM_SUPPORT_DIR"], path.hasPrefix("/"),
          !FileManager.default.fileExists(atPath: path) else {
        throw BenchmarkError("Proxy benchmarks require a fresh absolute PM_SUPPORT_DIR")
    }
    let engine = ProxyEngine()
    let sink = BenchmarkSink()
    engine.sink = sink
    engine.recordingEnabled = recording
    try engine.start(port: 0)
    defer {
        engine.stop()
        try? engine.group.syncShutdownGracefully()
    }

    var finished = false
    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    input.setEventHandler {
        _ = FileHandle.standardInput.availableData
        finished = true
    }
    input.resume()
    defer { input.cancel() }

    print(engine.port)
    fflush(stdout)
    while !finished {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    print(sink.captured)
    fflush(stdout)
}
