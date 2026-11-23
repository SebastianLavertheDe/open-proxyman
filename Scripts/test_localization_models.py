#!/usr/bin/env python3
"""Compile real enum and error declarations to verify locale-independent storage IDs."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
from localization_model_test_support import localization_sources

ROOT = Path(__file__).resolve().parents[1]


def declaration(path, marker):
    source = (ROOT / path).read_text()
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    core = 'Sources/ProxyMirrorCore/'
    chunks = ['import Foundation']
    chunks += ['struct TrafficCondition {\n' + declaration(core + 'Model/TrafficConditions.swift', 'enum Field:') + '\n' + declaration(core + 'Model/TrafficConditions.swift', 'enum Comparison:') + '\n}']
    chunks += ['struct TrafficConditionGroup {\n' + declaration(core + 'Model/TrafficConditions.swift', 'enum Mode:') + '\n}']
    chunks += ['struct CustomTrafficColumn {\n' + declaration(core + 'Model/CustomTrafficColumn.swift', 'enum Source:') + '\n}']
    chunks += ['enum RewriteAction {\n' + declaration(core + 'Interception/RuleStores.swift', 'enum HeaderOp:') + '\n}']
    chunks += [declaration(core + 'Model/Transaction.swift', 'enum FilterChip:'), declaration(core + 'Model/Transaction.swift', 'enum BodyKind:')]
    chunks += ['enum RuleMutation {\n' + declaration(core + 'Model/RuleMutation.swift', 'struct Failure:') + '\n}']
    chunks += [declaration(core + 'Interception/RuleOrganization.swift', 'struct RuleFolder:'), declaration(core + 'Interception/RuleOrganization.swift', 'struct RuleOrganization:')]
    harness = '''import Foundation
@main struct Run {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        expect(TrafficCondition.Field.requestHeader.rawValue == "requestHeader", "field ID")
        expect(TrafficCondition.Comparison.contains.rawValue == "contains", "comparison ID")
        expect(TrafficConditionGroup.Mode.all.rawValue == "all", "AND ID")
        expect(CustomTrafficColumn.Source.requestJSON.rawValue == "requestJSON", "column source ID")
        expect(RewriteAction.HeaderOp.set.rawValue == "set", "header operation ID")
        expect(FilterChip.all.id == "all", "filter identity")
        expect(BodyKind.image.rawValue == "image", "body-kind identity")
        let coded = try JSONEncoder().encode(RewriteAction.HeaderOp.set)
        expect(String(decoding: coded, as: UTF8.self) == "\\"set\\"", "English wire encoding")
        expect(try JSONDecoder().decode(RewriteAction.HeaderOp.self, from: coded) == .set, "new format roundtrip")
        do { _ = try JSONDecoder().decode(RewriteAction.HeaderOp.self, from: Data("\\"设置\\"".utf8)); preconditionFailure("old Chinese encoding accepted") }
        catch { checks += 1 }
        let error = RuleMutation.Failure(.modelRuleNameInvalid)
        expect(error.operationIssue.code == "models.rule_name_invalid", "stable operation code")
        expect(error.localizedDescription == "Rule names must contain 1–512 bytes and no control characters.", "stable technical diagnostic")
        expect(LocalizedErrorPresentation.message(for: error) == Strings.Models.ruleNameInvalid, "deferred GUI presentation")
        let organization = RuleOrganization(folders: [RuleFolder(tool: "dns", name: "", parentID: nil, enabled: nil)])
        expect(organization.validationError == "Folders need a valid tool ID and name.", "validator diagnostic is stable")
        expect(organization.localizedValidationError == Strings.Models.folderNameInvalid, "validator GUI channel")
        print("PASS: \\(checks) actual enum/error/validation contract checks")
    }
}
'''.replace('expect(try JSONDecoder().decode(RewriteAction.HeaderOp.self, from: coded) == .set, "new format roundtrip")', 'let restored = try JSONDecoder().decode(RewriteAction.HeaderOp.self, from: coded)\n        expect(restored == .set, "new format roundtrip")')
    with tempfile.TemporaryDirectory(prefix='pm-localization-models-') as folder:
        directory = Path(folder)
        (directory / 'Declarations.swift').write_text('\n'.join(chunks))
        (directory / 'Run.swift').write_text(harness)
        executable = directory / 'checks'
        subprocess.run([compiler, '-swift-version', '5', str(directory / 'Declarations.swift'),
                        str(directory / 'Run.swift'), *localization_sources(directory), '-o', str(executable)],
                       check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    main()
