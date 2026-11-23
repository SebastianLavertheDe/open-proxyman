import Foundation

final class CoreAssertions {
    private(set) var count = 0
    private(set) var failures = 0
    func expect(_ value: Bool, _ message: String) {
        count += 1
        if !value { failures += 1; print("FAIL \(message)") }
    }
    func equal<T: Equatable>(_ value: T, _ expected: T, _ message: String) {
        expect(value == expected, "\(message) [actual=\(value), expected=\(expected)]")
    }
    func rejects<T, E: Error>(_ operation: @autoclosure () throws -> T, with type: E.Type, _ message: String) {
        do { _ = try operation(); expect(false, message) }
        catch { expect(error is E, message) }
    }
}
let checks = CoreAssertions()
do {
    try checkExternalInclusiveRouting(checks)
    try checkRuleMutations(checks)
} catch { checks.expect(false, error.localizedDescription) }
print("Automation contracts: \(checks.count - checks.failures)/\(checks.count) passed")
exit(checks.failures == 0 ? 0 : 1)
