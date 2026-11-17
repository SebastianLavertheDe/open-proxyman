import Foundation
import ProxyMirrorCoreChecks
import XCTest

final class ProxyMirrorPerformanceTests: XCTestCase {
    @MainActor
    func testAppendEightMiB() {
        let workload = BodyAppendWorkload(chunks: 512)
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            workload.prepare()
            startMeasuring()
            workload.append()
            stopMeasuring()
            XCTAssertTrue(workload.isCorrect)
        }
    }

    @MainActor
    func testFilterAndSortFiveThousandRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workload = TrafficTableWorkload(directory: directory)
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            for iteration in 0..<100 {
                workload.filterAndSort(iteration: iteration)
            }
            stopMeasuring()
            XCTAssertTrue(workload.isCorrect(iteration: 99))
        }
    }
}
