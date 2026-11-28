#!/usr/bin/env python3
"""Compile production proxy validation with real resources and generated accessors."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Sources/ProxyMirrorCore"


def declaration(source, marker):
    start = source.index(marker)
    return source[start:source.index("\n}", start) + 2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    models = (CORE / "Interception/RuleStores.swift").read_text()
    connector = (CORE / "Proxy/ExternalProxyConnector.swift").read_text()
    pac = (CORE / "Proxy/PACResolver.swift").read_text()
    start = connector.index("    var validationError:")
    validation = "extension ExternalProxyConfig {\n" + connector[start:connector.index("\n}", start) + 2]
    pac_start = pac.index("    var proxyPACURL:")
    pac_property = pac[pac_start:pac.index("\n    }", pac_start) + 6]
    declarations = "\n".join([
        "import Foundation\n#if canImport(Darwin)\nimport Darwin\n#else\nimport Glibc\n#endif",
        declaration(models, "struct ExternalProxyConfig:"),
        validation, declaration(connector, "struct ExternalProxyHost"),
        "extension ExternalProxyConfig {\n" + pac_property + "\n}",
    ])
    harness = r'''
import Foundation
@main struct Run {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            precondition(value(), description)
            count += 1
        }
        var config = ExternalProxyConfig()
        check(config.validationError == nil, "default configuration is valid")
        config.port = 0
        check(config.validationIssue?.code == "external_proxy.external_port_range", "stable validation code")
        check(config.validationError == "The port must be between 1 and 65535.", "stable English diagnostic")
        check(config.localizedValidationError == Strings.Integration.externalPortRange, "localized GUI channel")
        config = ExternalProxyConfig(); config.includedTargets = Array(repeating: "example.com", count: 257)
        check(config.validationIssue?.code == "external_proxy.external_target_limit", "target list limit")
        config.includedTargets = ["invalid target"]
        check(config.validationError == "Invalid included target: invalid target", "dynamic diagnostic")
        check(config.localizedValidationError == Strings.Integration.externalInvalidTarget("invalid target"), "dynamic GUI text")
        config = ExternalProxyConfig(); config.enabled = true; config.routingMode = .inclusive
        check(config.validationIssue?.code == "external_proxy.external_inclusive_required", "inclusive target required")
        config = ExternalProxyConfig(); config.bypassHosts = ["invalid host"]
        check(config.validationIssue?.code == "external_proxy.external_invalid_bypass", "bypass input validation")
        config = ExternalProxyConfig(); config.mode = .pac; config.pacURL = "file://remote/proxy.pac"
        check(config.validationIssue?.code == "external_proxy.external_pac_required", "real PAC URL validation")
        config.pacURL = "file:///tmp/proxy.pac"
        check(config.validationError == nil, "valid local PAC URL")
        config = ExternalProxyConfig(); config.host = "invalid host"
        check(config.validationIssue?.code == "external_proxy.external_host_required", "host validation")
        config = ExternalProxyConfig(); config.useAuth = true
        check(config.validationIssue?.code == "external_proxy.external_credentials_required", "credentials required")
        config.mode = .socks5; config.username = String(repeating: "a", count: 256); config.password = "not-a-secret"
        check(config.validationIssue?.code == "external_proxy.external_socks_credentials_size", "SOCKS5 credential limit")
        config.mode = .http; config.username = "invalid:name"
        check(config.validationIssue?.code == "external_proxy.external_basic_credentials", "Basic username validation")
        config.username = "invalid\nname"
        check(config.validationIssue?.code == "external_proxy.external_control_characters", "credential control characters")
        print("PASS: \(count) real external-proxy diagnostic/presentation checks [\(L10n.effectiveLanguage)]")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="pm-external-validation-") as temporary:
        directory = Path(temporary)
        (directory / "Declarations.swift").write_text(declarations)
        (directory / "Run.swift").write_text(harness)
        sources = [*sorted((CORE / "Localization").glob("*.swift")),
                   *sorted((CORE / "Localization/Generated").glob("*.swift")),
                   CORE / "UI/PresentationLocalization.swift",
                   CORE / "System/LocalizedErrorPresentation.swift",
                   CORE / "Proxy/ExternalProxyTarget.swift"]
        binary = directory / "checks"
        subprocess.run([args.swiftc, "-swift-version", "5", *map(str, sources),
                        str(directory / "Declarations.swift"), str(directory / "Run.swift"),
                        "-o", str(binary)], check=True, timeout=180)
        resource = directory / "Resources.bundle"
        resource.mkdir()
        (resource / "Info.plist").write_bytes(plistlib.dumps({"CFBundleDevelopmentRegion": "en"}))
        for language in ("en", "zh-Hans", "es-419", "ja", "pt-BR"):
            target = resource / f"{language}.lproj"
            target.mkdir()
            for path in (CORE / "Resources" / f"{language}.lproj").glob("*.strings"):
                shutil.copy2(path, target / path.name)
        for language in ("en", "zh-Hans"):
            environment = dict(os.environ, PM_SETTINGS_LANGUAGE=language,
                               PM_LOCALIZATION_RESOURCE_DIR=str(resource))
            subprocess.run([str(binary)], env=environment, check=True, timeout=20)


if __name__ == "__main__":
    main()
