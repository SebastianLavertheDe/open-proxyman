import Foundation

package enum TrafficRetention {
    package struct Candidate: Sendable {
        package let id: UUID
        package let startedAt: Date
        package let sequence: Int
        package let completed: Bool

        package init(id: UUID, startedAt: Date, sequence: Int, completed: Bool) {
            self.id = id
            self.startedAt = startedAt
            self.sequence = sequence
            self.completed = completed
        }
    }

    package static func oldestCompleted(_ candidates: [Candidate], count: Int) -> Set<UUID> {
        guard count > 0 else { return [] }
        return Set(candidates.filter(\.completed).sorted {
            $0.startedAt == $1.startedAt ? $0.sequence < $1.sequence : $0.startedAt < $1.startedAt
        }.prefix(count).map(\.id))
    }
}

package enum SimulatorTrafficPolicy {
    package static func isExecutablePath(_ path: String) -> Bool {
        let path = path.lowercased()
        return path.contains("/coresimulator/devices/")
            || (path.contains("/ios") && path.contains(".simruntime/contents/resources/runtimeroot/"))
            || path.contains("/coresimulator/volumes/ios_")
    }

    package static func isBackgroundTraffic(host: String, isSimulator: Bool) -> Bool {
        guard isSimulator else { return false }
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domains = ["mesu.apple.com", "gdmf.apple.com", "configuration.apple.com", "xp.apple.com",
                       "push.apple.com", "gateway.icloud.com", "pancake.apple.com", "captive.apple.com",
                       "time.apple.com", "time-ios.apple.com", "apple-dns.net"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
