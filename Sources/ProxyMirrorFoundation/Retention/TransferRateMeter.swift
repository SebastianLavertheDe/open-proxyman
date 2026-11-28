import Foundation

package struct TransferRateMeter {
    package private(set) var upload: Int64 = 0
    package private(set) var download: Int64 = 0
    private var previous: (time: TimeInterval, up: Int64, down: Int64)?

    package init() {}

    package mutating func sample(up: Int64, down: Int64, now: TimeInterval) {
        defer { previous = (now, up, down) }
        guard let previous, now > previous.time else { return }
        func rate(_ current: Int64, _ old: Int64) -> Int64 {
            guard current >= old else { return 0 }
            let bytes = (Double(current) - Double(old)) / (now - previous.time)
            guard bytes.isFinite, bytes < Double(Int64.max) else { return Int64.max }
            return Int64(max(0, bytes))
        }
        upload = rate(up, previous.up)
        download = rate(down, previous.down)
    }
}
