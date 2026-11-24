import Foundation
@testable import ProxyMirrorCore

@MainActor
func checkImportedTrafficMetrics(_ test: CoreAssertions) throws {
    func har(_ request: Int, _ response: Int, time: Double = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["log": ["entries": [[
            "time": time,
            "request": ["method": "GET", "url": "https://metrics.example.test/", "bodySize": request] as [String: Any],
            "response": ["status": 200, "bodySize": response,
                         "content": ["text": "ok", "mimeType": "text/plain"]] as [String: Any],
        ]]]])
    }
    test.rejects(try SessionFile.importHAR(har(Int.max, Int.max)), with: SessionFile.SessionError.self,
                 "HAR rejects an overflowing aggregate without creating a displayable transaction")
    test.rejects(try SessionFile.importHAR(har(-2, 0)), with: SessionFile.SessionError.self,
                 "HAR rejects negative counters other than its unknown-length sentinel")
    test.rejects(try SessionFile.importHAR(har(0, 0, time: Double.greatestFiniteMagnitude)), with: SessionFile.SessionError.self,
                 "HAR rejects durations that cannot be safely converted for display")
    let ordinary = try SessionFile.importHAR(har(-1, 0)).first!
    test.equal(ordinary.requestBytes, 0, "Unknown HAR request length uses the captured bytes")
    test.equal(ordinary.responseBytes, 2, "Underreported HAR response length cannot hide captured bytes")

    let tx = Transaction()
    tx.host = "metrics.example.test"
    let session = SessionFile(transactions: [tx], pinnedDomains: [], selected: [])
    var document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
    var records = document["records"] as! [[String: Any]]
    records[0]["requestBytes"] = Int.max; records[0]["responseBytes"] = Int.max
    document["records"] = records
    let invalid = try JSONSerialization.data(withJSONObject: document)
    test.rejects(try SessionFile.decode(invalid), with: SessionFile.SessionError.self,
                 "Native sessions reject the same invalid counter aggregate")

    tx.requestBytes = Int.max; tx.responseBytes = Int.max
    test.equal(tx.totalSize, Int.max, "Defensive transaction totals saturate for explicitly constructed records")
    let directory = try makeCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let csv = directory.appendingPathComponent("metrics.csv")
    try ExportService.writeCSV([tx], to: csv)
    test.expect(try String(contentsOf: csv).contains(String(Int.max)), "CSV writes a bounded total instead of trapping")
}
