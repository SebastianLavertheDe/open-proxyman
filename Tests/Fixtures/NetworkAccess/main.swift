import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let cases = networkAccessPolicyCases()
for (passed, message) in cases where !passed {
    try? FileHandle.standardError.write(contentsOf: Data(("FAIL " + message + "\n").utf8))
}
let failures = cases.filter { !$0.0 }.count
print("Network access policy: \(cases.count - failures)/\(cases.count) passed")
exit(failures == 0 ? 0 : 1)
