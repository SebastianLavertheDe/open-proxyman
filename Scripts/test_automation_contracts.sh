#!/bin/sh
# Compile the real Foundation-only rule/routing implementation and shared unit
# checks. Extraction omits NIO imports. Minimal stubs cover the unused UI
# Transaction adapter, the separately tested global gate, and PAC URL discovery;
# PAC evaluation, network forwarding, and persistence use test_mcp.py on macOS.
set -eu
automation_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
automation_temp=$(mktemp -d "${TMPDIR:-/tmp}/pm-contracts.XXXXXX")
trap 'rm -rf "$automation_temp"' EXIT HUP INT TERM
python3 - "$automation_root" "$automation_temp" <<'PY'
from pathlib import Path
import sys
import re
root, temporary = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / 'Scripts'))
from localization_model_test_support import localization_sources
localization_sources(temporary)
models = (root / 'Sources/ProxyMirrorCore/Interception/RuleStores.swift').read_text()
models = models[models.index('enum RewriteAction:'):models.index('// MARK: - JSON 持久化')]
phase = (root / 'Sources/ProxyMirrorCore/Interception/ScriptingService.swift').read_text()
phase = phase[phase.index('enum ScriptingPhase:'):phase.index('struct ScriptingTarget:')]
connector = (root / 'Sources/ProxyMirrorCore/Proxy/ExternalProxyConnector.swift').read_text()
connector = connector[connector.index('extension ExternalProxyConfig {'):connector.index('enum ExternalProxyConnector {')]
imports = '''import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
'''
stubs = '''
final class RuleOrganizationStore {
    static let shared = RuleOrganizationStore()
    func isEnabled(_ tool: String) -> Bool { true }
}
extension ExternalProxyConfig {
    var proxyPACURL: URL? { pacURL.flatMap(URL.init(string:)) }
}
final class Transaction {
    var method = "GET", scheme = "https", host = "", path = "/", query = "", fullURL = ""
    var isTunnel = false
    var graphqlOperationName: String?
}
'''
engine = (root / 'Sources/ProxyMirrorCore/Proxy/ProxyEngine.swift').read_text()
host_match = re.search(r'    static func hostMatches\(host: String, pattern: String\) -> Bool \{.*?\n    \}', engine, re.S)
assert host_match, 'host matching source marker changed'
conn = 'enum ConnState {\n' + host_match.group() + '\n}\n'
(temporary / 'Models.swift').write_text(imports + phase + models + connector + stubs + conn)
for name in ['ExternalInclusiveChecks.swift', 'RuleMutationChecks.swift']:
    text = (root / 'Tests/ProxyMirrorCoreChecks' / name).read_text()
    (temporary / name).write_text(text.replace('@testable import ProxyMirrorCore\n', ''))
PY
"${PM_SWIFTC:-swiftc}" -swift-version 5 "$automation_temp/Models.swift" \
  "$automation_root/Sources/ProxyMirrorCore/Interception/URLRule.swift" \
  "$automation_root/Sources/ProxyMirrorCore/Proxy/ExternalProxyTarget.swift" \
  "$automation_root/Sources/ProxyMirrorCore/Model/RuleMutation.swift" \
  "$automation_temp/ExternalInclusiveChecks.swift" "$automation_temp/RuleMutationChecks.swift" \
  "$automation_root/Tests/Fixtures/AutomationContracts/main.swift" \
  "$automation_root/Sources/ProxyMirrorCore/Localization/Generated/Strings.swift" \
  "$automation_root/Sources/ProxyMirrorCore/Localization/Generated/EnglishFallbacks.swift" \
  "$automation_root/Sources/ProxyMirrorCore/System/LocalizedErrorPresentation.swift" \
  "$automation_root/Sources/ProxyMirrorCore/System/GeneratedOperationIssues.swift" \
  "$automation_root/Sources/ProxyMirrorCore/System/GeneratedModelOperationIssues.swift" \
  "$automation_temp/LocalizationPresentationBoundary.swift" \
  -o "$automation_temp/contracts"
"$automation_temp/contracts"
