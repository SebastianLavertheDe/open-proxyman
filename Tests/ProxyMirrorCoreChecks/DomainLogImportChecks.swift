import Foundation
@testable import ProxyMirrorCore

func checkDomainLogImport(_ test: CoreAssertions) throws {
    let earlier = Transaction(startedAt: Date(timeIntervalSince1970: 100))
    earlier.host = "a.example.test"; earlier.seq = 1
    earlier.requestBody = Data([0, 255, 128]); earlier.comment = "preserve annotations"
    let later = Transaction(startedAt: Date(timeIntervalSince1970: 200))
    later.host = "b.example.test"; later.seq = 2
    func group(_ domain: String, _ rows: [Transaction]) throws -> [String: Any] {
        let session = SessionFile(transactions: rows, pinnedDomains: [domain], selected: Set(rows.map(\.id)))
        return ["domain": domain, "session": try JSONSerialization.jsonObject(with: session.exportData())]
    }
    var bundle: [String: Any] = ["format": "proxymirror-domain-logs", "version": 1,
        "sessions": try [group(later.host, [later]), group(earlier.host, [earlier])]]
    let restored = try SessionFile.decode(JSONSerialization.data(withJSONObject: bundle))
    test.equal(restored.records.map(\.id), [earlier.id, later.id], "域名日志包可直接重新打开并恢复时间顺序")
    test.equal(restored.records.first?.requestBody, earlier.requestBody, "域名日志包保留原始二进制正文")
    test.equal(restored.records.first?.comment, earlier.comment, "域名日志包保留请求注释")
    test.equal(Set(restored.selected), Set([earlier.id, later.id]), "域名日志包合并各组选择状态")
    test.equal(Set(restored.pinnedDomains), Set([earlier.host, later.host]), "域名日志包合并各组置顶域名")
    bundle["sessions"] = try [group(earlier.host, [earlier]), group(later.host, [earlier])]
    test.rejects(try SessionFile.decode(JSONSerialization.data(withJSONObject: bundle)), with: SessionFile.SessionError.self,
                 "域名日志包拒绝跨分组重复请求 ID")
    bundle["sessions"] = []; bundle["version"] = 2
    test.rejects(try SessionFile.decode(JSONSerialization.data(withJSONObject: bundle)), with: SessionFile.SessionError.self,
                 "域名日志包拒绝未知版本")
}
