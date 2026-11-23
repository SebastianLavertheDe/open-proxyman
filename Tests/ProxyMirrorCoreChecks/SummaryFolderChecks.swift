import Foundation
@testable import ProxyMirrorCore

func checkSummaryAndFolderDrafts(_ test: CoreAssertions) throws {
    let empty = FlowSummaryStatistics.calculate([])!
    test.equal(empty.total, 0, "Summary: an empty range has no flows")
    test.expect(empty.averageMilliseconds == nil && empty.p50Milliseconds == nil && empty.p95Milliseconds == nil && empty.p99Milliseconds == nil,
                "Summary: empty ranges have no invented average or percentiles")
    let samples: [FlowSummarySample] = [
        .init(host: "a.test", statusCode: 101, state: .completed, durationSeconds: 0),
        .init(host: "a.test", statusCode: 200, state: .completed, durationSeconds: 0.010),
        .init(host: "b.test", statusCode: 302, state: .completed, durationSeconds: 0.050),
        .init(host: "b.test", statusCode: 404, state: .completed, durationSeconds: 0.100),
        .init(host: "b.test", statusCode: 503, state: .completed, durationSeconds: 1),
        .init(host: "a.test", statusCode: 500, state: .failed, durationSeconds: 5),
        .init(host: "a.test", statusCode: 200, state: .inProgress, durationSeconds: 100),
        .init(host: "a.test", statusCode: 0, state: .completed, durationSeconds: .nan),
        .init(host: "a.test", statusCode: 600, state: .completed, durationSeconds: .infinity),
        .init(host: "a.test", statusCode: 201, state: .completed, durationSeconds: -1),
    ]
    let summary = FlowSummaryStatistics.calculate(samples)!
    test.equal(summary.total, 10, "Summary: all flows remain in the range total")
    test.equal(summary.buckets.values.reduce(0, +), 10, "Summary: mutually exclusive status buckets cover the entire range")
    test.equal(summary.buckets[.failed], 1, "Summary: a failed transport with HTTP 500 belongs only to the transport-failure bucket")
    test.equal(summary.buckets[.serverError], 1, "Summary: completed HTTP 5xx remains separate from transport failures")
    test.equal(summary.buckets[.unanswered], 3, "Summary: unfinished, missing and invalid statuses are not misclassified as HTTP success")
    test.equal(summary.httpErrors, 2, "Summary: HTTP errors count completed 4xx and 5xx")
    test.equal(summary.durationCount, 5, "Summary: durations exclude unfinished, failed, negative, NaN and infinite values")
    test.equal(summary.invalidCompletedDurations, 3, "Summary: invalid completed durations are reported")
    test.equal(summary.averageMilliseconds, 232, "Summary: averages use milliseconds")
    test.equal(summary.p50Milliseconds, 50, "Summary: P50 uses the nearest-rank definition")
    test.equal(summary.p95Milliseconds, 1000, "Summary: P95 includes the maximum in a small population")
    test.equal(summary.p99Milliseconds, 1000, "Summary: P99 includes the maximum in a small population")
    test.equal(summary.statusCounts.map(\.status), [101, 200, 201, 302, 404, 503], "Summary: exact completed HTTP statuses are sorted numerically")
    let edges: [Double] = [0, 0.009999, 0.010, 0.049999, 0.050, 0.099999, 0.100, 0.249999, 0.250, 0.499999, 0.500, 0.999999, 1, 4.999999, 5]
    let edgeSummary = FlowSummaryStatistics.calculate(edges.map { .init(host: "edge.test", statusCode: 200, state: .completed, durationSeconds: $0) })!
    test.equal(edgeSummary.durationBins.map(\.count), [2, 2, 2, 2, 2, 2, 2, 1], "Summary: histogram intervals are left-inclusive and right-exclusive in milliseconds")
    test.expect(FlowSummaryStatistics.calculate(samples, cancelled: { true }) == nil, "Summary: cancelled aggregation does not publish stale statistics")
    let huge = FlowSummaryStatistics.calculate([
        .init(host: "a.test", statusCode: 200, state: .completed, durationSeconds: 1, uploadedBytes: Int.max, downloadedBytes: -1),
        .init(host: "a.test", statusCode: 200, state: .completed, durationSeconds: 2, uploadedBytes: Int.max, downloadedBytes: 10),
    ])!
    test.equal(huge.uploadedBytes, Int64.max, "Summary: byte totals saturate instead of overflowing")
    test.equal(huge.downloadedBytes, 10, "Summary: invalid negative wire counts do not lower totals")

    let parent = RuleFolder(tool: "dns", name: "Parent", parentID: nil, enabled: false)
    let child = RuleFolder(tool: "dns", name: "Child", parentID: parent.id, enabled: true)
    let base = RuleOrganization(folders: [parent, child], assignments: ["dns:first": child.id.uuidString, "dns:removed": child.id.uuidString])
    let installed = RuleOrganizationStore.shared.snapshot()
    var draft = RuleFolderEditingDraft(base)
    draft.assign(ruleID: "first", tool: "dns", folderID: nil)
    let created = try draft.createFolder(tool: "dns", name: " New ", parentID: parent.id)
    draft.assign(ruleID: "second", tool: "dns", folderID: created.id)
    test.equal(base.assignments["dns:first"], child.id.uuidString, "Folders: editing does not change the original snapshot")
    test.equal(RuleOrganizationStore.shared.snapshot(), installed, "Folders: uncommitted membership and folder creation do not change the live store")
    test.equal(draft.path(created), "Parent / New", "Folders: the picker displays the complete nested path")
    var concurrent = base
    let elsewhere = RuleFolder(tool: "reverse", name: "Concurrent", parentID: nil, enabled: true)
    concurrent.folders.append(elsewhere); concurrent.disabledTools = ["blockList"]
    let merged = try draft.merging(into: concurrent, tool: "dns", keeping: ["first", "second"])
    test.expect(merged.folders.contains(where: { $0.id == elsewhere.id }) && merged.disabledTools == ["blockList"],
                "Folders: saving merges this editor's changes while preserving other tools' concurrent edits")
    test.expect(merged.assignments["dns:first"] == nil && merged.assignments["dns:removed"] == nil,
                "Folders: clearing membership and deleting rules remove their assignments")
    test.equal(merged.assignments["dns:second"], created.id.uuidString, "Folders: new folder and membership are committed together")
    test.expect(!merged.ruleIsEnabled(tool: "dns", ruleID: "second"), "Folders: the real execution predicate disables rules through an ancestor folder")
    test.expect(merged.ruleIsEnabled(tool: "dns", ruleID: "first"), "Folders: removing membership restores the rule's tool-level execution gate")
    var removedParent = concurrent
    removedParent.folders.removeAll { $0.id == parent.id || $0.id == child.id }
    removedParent.assignments = [:]
    test.rejects(try draft.merging(into: removedParent, tool: "dns", keeping: ["first", "second"]),
                 with: RuleOrganizationStore.OrganizationError.self, "Folders: a concurrently deleted parent rejects the whole draft instead of publishing an orphan")
}
