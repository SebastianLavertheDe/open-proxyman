import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkCapturedFailurePersistence(_ test: CoreAssertions) throws {
    let tx = Transaction()
    tx.host = "failure.example.test"
    tx.state = .failed
    let issue = OperationIssue.networkUpstreamConnectionFailed("curl: (7) original 原文 100% %@")
    tx.recordFailure(NetworkFailure(issue))
    test.equal(tx.failure?.code, issue.code, "Captured own network failure retains its stable code")
    test.equal(tx.failure?.arguments, ["curl: (7) original 原文 100% %@"], "Captured failure retains raw parameters")
    test.equal(tx.errorText, issue.diagnostic, "Machine error text remains a stable diagnostic")
    test.equal(tx.localizedErrorText, issue.localizedPresentation, "GUI resolves a known failure in the selected language")

    let bytes = try JSONEncoder().encode(SessionRecord(tx))
    let reopened = try JSONDecoder().decode(SessionRecord.self, from: bytes).transaction()
    test.equal(reopened.failure, tx.failure, "Native session preserves typed failure identity")
    test.equal(reopened.errorText, issue.diagnostic, "Native session preserves stable diagnostics")
    test.equal(reopened.localizedErrorText, issue.localizedPresentation, "Reopened session renders in the current language")

    var legacy = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    legacy.removeValue(forKey: "failure")
    let old = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: legacy)).transaction()
    test.equal(old.failure, nil, "Older sessions without typed failure remain readable")
    test.equal(old.errorText, issue.diagnostic, "Older raw diagnostics are preserved verbatim")

    let har = ExportService.buildHAR([tx])
    let harBytes = try JSONSerialization.data(withJSONObject: har)
    let log = har["log"] as! [String: Any]
    let response = (log["entries"] as! [[String: Any]])[0]["response"] as! [String: Any]
    test.equal(response["_error"] as? String, issue.diagnostic, "HAR _error retains its existing stable diagnostic contract")
    let fromHAR = try SessionFile.importHAR(harBytes).first!
    test.equal(fromHAR.failure, tx.failure, "HAR extension preserves typed failure for later GUI rendering")
    test.equal(fromHAR.localizedErrorText, issue.localizedPresentation, "HAR reopen uses the selected language")

    let foreign = "curl: (35) external script 原文 100% %@"
    tx.errorText = foreign
    test.equal(tx.failure, nil, "Assigning foreign diagnostics clears prior own-error identity")
    let foreignCopy = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(SessionRecord(tx))).transaction()
    test.equal(foreignCopy.localizedErrorText, foreign, "Foreign diagnostics are never translated or reformatted")
}
