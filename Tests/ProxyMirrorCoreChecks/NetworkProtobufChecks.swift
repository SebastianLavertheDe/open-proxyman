import Foundation
@testable import ProxyMirrorCore

func checkNetworkProtobufTools(_ test: CoreAssertions, descriptor: Data) throws {
    // Preserve old JSON: absent rules must keep the original global host condition.
    let legacyJSON = Data(#"{"enabled":true,"milliseconds":70,"host":"*.example.test","disconnectPercent":0}"#.utf8)
    let legacy = try JSONDecoder().decode(LatencyConditions.self, from: legacyJSON)
    test.expect(legacy.rules == nil && legacy.sample(for: "api.example.test").requestDelay == 70,
                "Network conditions: legacy global JSON retains host matching")
    test.equal(legacy.sample(for: "other.test").requestDelay, 0,
               "Network conditions: legacy host mismatch leaves requests unchanged")
    var wildcard = NetworkConditionRule(legacy: LatencyConditions(enabled: true, milliseconds: 180), name: "Wildcard")
    wildcard.host = "*.example.test"
    var specific = NetworkConditionRule(legacy: LatencyConditions(enabled: true, milliseconds: 10), name: "Specific")
    specific.host = "api.example.test"
    var conditions = LatencyConditions(enabled: true, rules: [specific, wildcard])
    test.equal(conditions.sample(for: "api.example.test").requestDelay, 10,
               "Network conditions: first enabled matching host rule wins")
    test.equal(conditions.sample(for: "cdn.example.test").requestDelay, 180,
               "Network conditions: later wildcard matches other hosts")
    test.equal(conditions.sample(for: "other.test").requestDelay, 0,
               "Network conditions: unmatched hosts are unaffected")
    conditions.rules?[0].enabled = false
    test.equal(conditions.sample(for: "api.example.test").requestDelay, 180,
               "Network conditions: disabled rules allow later matches")
    conditions.enabled = false
    test.equal(conditions.sample(for: "api.example.test").requestDelay, 0,
               "Network conditions: master switch disables every rule")
    test.expect(LatencyConditions.Preset.allCases.count >= 10,
                "Network conditions: at least ten presets are available")
    test.expect(LatencyConditions.Preset.totalLoss.settings(for: "").sample(for: "test").disconnect,
                "Network conditions: total loss disconnects each matching request")
    conditions.rules = [specific, specific]
    test.expect(conditions.validationError != nil, "Network conditions: duplicate IDs are rejected")
    let roundTrip = try JSONDecoder().decode(LatencyConditions.self, from: JSONEncoder().encode(legacy))
    test.equal(roundTrip, legacy, "Network conditions: legacy backup round-trip is lossless")

    // The same UUID merge contract used by classic rule tools also applies to weak-network lists.
    let existingNetwork = LatencyConditions(enabled: true, rules: [specific, wildcard])
    var updatedWildcard = wildcard
    updatedWildcard.milliseconds = 220
    var addedNetwork = NetworkConditionRule(legacy: LatencyConditions(enabled: true, milliseconds: 30), name: "Added")
    addedNetwork.host = "new.example.test"
    let importedNetwork = LatencyConditions(enabled: true, rules: [addedNetwork, updatedWildcard])
    let currentNetworkBackup = RuleBackup(latency: existingNetwork)
    let importedNetworkBackup = RuleBackup(latency: importedNetwork)
    let mergedNetwork = importedNetworkBackup.resolve(with: currentNetworkBackup, merge: true).latency
    test.equal(mergedNetwork?.rules, [specific, updatedWildcard, addedNetwork],
               "Network backup: UUID merge updates in place, retains existing rules, and appends new rules")
    test.equal(importedNetworkBackup.resolve(with: currentNetworkBackup, merge: false).latency?.rules,
               [addedNetwork, updatedWildcard], "Network backup: replacement retains imported order and removes omitted rules")
    let networkMergeChange = importedNetworkBackup.changes(from: currentNetworkBackup, mode: .merge).first { $0.section == .latency }
    test.expect(networkMergeChange?.added == 1 && networkMergeChange?.updated == 1 && networkMergeChange?.removed == 0
        && networkMergeChange?.reordered == false, "Network backup: merge preview reports actual rule additions and updates")
    let networkReplaceChange = importedNetworkBackup.changes(from: currentNetworkBackup, mode: .replace).first { $0.section == .latency }
    test.expect(networkReplaceChange?.added == 1 && networkReplaceChange?.updated == 1 && networkReplaceChange?.removed == 1,
                "Network backup: replacement preview reports actual omitted-rule removals")
    let reorderedNetwork = RuleBackup(latency: LatencyConditions(enabled: true, rules: [wildcard, specific]))
    test.expect(reorderedNetwork.changes(from: currentNetworkBackup, mode: .replace).first?.reordered == true,
                "Network backup: replacement preview detects reordered matching priority")
    test.expect(reorderedNetwork.changes(from: currentNetworkBackup, mode: .merge).first?.reordered == false,
                "Network backup: merge retains current matching priority")
    let emptyNetwork = LatencyConditions(enabled: true, rules: [])
    test.equal(emptyNetwork.resolving(with: existingNetwork, merge: true).rules, existingNetwork.rules,
               "Network backup: merging an empty rule list preserves existing rules")
    test.equal(emptyNetwork.resolving(with: existingNetwork, merge: false).rules, [],
               "Network backup: replacing with an empty rule list clears rules")
    test.equal(legacy.resolving(with: existingNetwork, merge: true), legacy,
               "Network backup: legacy singleton imports keep their historical replacement behavior")
    test.equal(importedNetwork.resolving(with: legacy, merge: true), importedNetwork,
               "Network backup: a list replaces a legacy singleton without inventing rule IDs")
    let switchedNetwork = RuleBackup(latency: LatencyConditions(enabled: false, rules: existingNetwork.rules))
    let switchChange = switchedNetwork.changes(from: currentNetworkBackup, mode: .merge).first
    test.expect(switchChange?.configurationChanged == true && switchChange?.unchanged == 2 && switchChange?.updated == 0,
                "Network backup: master-switch changes are reported separately from per-rule updates")

    let root = RuleFolder(tool: "rewrite", name: "Root", enabled: false)
    let child = RuleFolder(tool: "rewrite", name: "Child", parentID: root.id)
    let assignment = "rewrite:" + UUID().uuidString
    let organization = RuleOrganization(folders: [root, child], assignments: [assignment: child.id.uuidString])
    test.expect(organization.validationError == nil && organization.disabledRuleKeys.contains(assignment),
                "Rule folders: disabling an ancestor disables its assigned descendants")
    var cycle = organization
    cycle.folders[0].parentID = child.id
    test.expect(cycle.validationError != nil, "Rule folders: cycles are rejected")
    var crossTool = organization
    crossTool.folders[1].tool = "dns"
    test.expect(crossTool.validationError != nil, "Rule folders: cross-tool parents are rejected")
    var dangling = organization
    dangling.assignments[assignment] = UUID().uuidString
    test.expect(dangling.validationError != nil, "Rule folders: dangling rule assignments are rejected")
    let unrelated = RuleFolder(tool: "dns", name: "Keep")
    let current = RuleOrganization(folders: [unrelated], disabledTools: ["dns"])
    let scoped = RuleOrganization(folders: [root, child], assignments: organization.assignments,
                                  disabledTools: [], includedTools: ["rewrite"])
    let resolved = scoped.resolving(with: current, merge: false)
    test.expect(resolved.folders.contains(unrelated) && resolved.disabledTools.contains("dns"),
                "Rule folders: replacing one tool retains other tools' metadata")

    // Explicit metadata scope replaces the imported tool's global switch even during merge,
    // while preserving old folders/assignments needed by rules retained through UUID merge.
    let oldAssignment = "rewrite:" + UUID().uuidString
    let oldRoot = RuleFolder(tool: "rewrite", name: "Existing")
    let oldOrganization = RuleOrganization(folders: [oldRoot, unrelated], assignments: [oldAssignment: oldRoot.id.uuidString],
                                            disabledTools: ["rewrite", "dns"])
    let scopedMerged = scoped.resolving(with: oldOrganization, merge: true)
    test.expect(!scopedMerged.disabledTools.contains("rewrite") && scopedMerged.disabledTools.contains("dns"),
                "Rule folders: explicitly scoped merge can re-enable its tool without changing another tool's switch")
    test.expect(scopedMerged.folders.contains(oldRoot) && scopedMerged.assignments[oldAssignment] == oldRoot.id.uuidString
        && scopedMerged.validationError == nil, "Rule folders: merged metadata retains references of pre-existing rules")
    let scopedDisabled = RuleOrganization(disabledTools: ["rewrite"], includedTools: ["rewrite"])
        .resolving(with: scopedMerged, merge: true)
    test.expect(scopedDisabled.disabledTools.contains("rewrite") && scopedDisabled.folders.contains(oldRoot),
                "Rule folders: explicitly scoped merge can disable its tool while retaining folders and rule references")

    let schemaID = UUID()
    let schemaRecord = ProtobufSchemaRecord(id: schemaID, name: "Echo", filename: schemaID.uuidString + ".desc", descriptorData: descriptor)
    var mapping = ProtobufMappingRule()
    mapping.schemaID = schemaID
    mapping.requestMessage = "fixture.grpc.EchoRequest"
    mapping.responseMessage = "fixture.grpc.EchoReply"
    let configuration = ProtobufConfiguration(schemas: [schemaRecord], rules: [mapping])
    test.expect(configuration.validationError == nil, "Protobuf rules: descriptor bytes and request/response message mappings validate")
    var invalidConfiguration = configuration
    invalidConfiguration.rules[0].responseMessage = "fixture.grpc.DoesNotExist"
    test.expect(invalidConfiguration.validationError != nil, "Protobuf rules: message names must exist in the selected descriptor")
    let portable = RuleBackup(organization: organization,
                              reverse: [ReverseProxyRule(name: "Local test", listenPort: 18080, remoteHost: "example.test")],
                              external: ExternalProxyConfig(), h2c: H2CUpstreamConfig(), protobuf: configuration)
    let (restored, unmapped) = try RuleBackup.read(portable.exportData())
    test.expect(unmapped.isEmpty && restored.protobuf == configuration && restored.organization == organization,
                "Tool backup: schemas include descriptor bytes and rule-folder state without external files")
    test.equal(restored.reverse?.first?.listenPort, 18080, "Tool backup: reverse proxy listeners round-trip")
    test.equal(restored.subset(.protobuf).protobuf, configuration, "Tool backup: Protobuf-only export retains embedded descriptors")
    let changes = portable.changes(from: RuleBackup(), mode: .replace)
    test.expect(changes.contains(where: { $0.section == .organization }) && changes.contains(where: { $0.section == .protobuf }),
                "Tool backup: preview includes metadata and Protobuf changes")
    let suite = "pm-network-protobuf-checks-" + UUID().uuidString
    if let defaults = UserDefaults(suiteName: suite) {
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.showInvisibles = true
        settings.wordWrap = false
        settings.http2Enabled = false
        let preferences = RuleBackup.Preferences(settings)
        settings.showInvisibles = false; settings.wordWrap = true; settings.http2Enabled = true
        preferences.apply(to: settings)
        test.expect(settings.showInvisibles && !settings.wordWrap && !settings.http2Enabled,
                    "Tool backup: display and HTTP/2 preferences restore through optional extras")
    }

    let protobuf = Data([10, 2, 111, 107])
    test.equal(try ProtobufPayload.messages(protobuf, encoding: .single), [protobuf],
               "Protobuf converter: single payload preserves bytes")
    let delimited = Data([4]) + protobuf + Data([0, 4]) + protobuf
    test.equal(try ProtobufPayload.messages(delimited, encoding: .delimited), [protobuf, Data(), protobuf],
               "Protobuf converter: varint-delimited messages include empty payloads")
    test.equal(try ProtobufPayload.messages(delimited.base64EncodedData(), encoding: .delimited, payloadType: .base64),
               [protobuf, Data(), protobuf], "Protobuf converter: Base64 is decoded before framing")
    test.rejects(try ProtobufPayload.messages(Data([0x80]), encoding: .delimited),
                 with: GRPCInspectionError.self, "Protobuf converter: truncated length prefixes are rejected")
    test.rejects(try ProtobufPayload.messages(Data([8, 1]), encoding: .delimited),
                 with: GRPCInspectionError.self, "Protobuf converter: truncated payloads are rejected")
    test.rejects(try ProtobufPayload.messages(Data(repeating: 0xff, count: 10), encoding: .delimited),
                 with: GRPCInspectionError.self, "Protobuf converter: overflowing varints are rejected")
    test.rejects(try ProtobufPayload.messages(Data(repeating: 0, count: 257), encoding: .delimited),
                 with: GRPCInspectionError.self, "Protobuf converter: message count budget is enforced")
    test.rejects(try ProtobufPayload.messages(Data("???".utf8), encoding: .single, payloadType: .base64),
                 with: GRPCInspectionError.self, "Protobuf converter: invalid Base64 is rejected")
}
