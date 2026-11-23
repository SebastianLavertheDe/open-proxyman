"""Compile the checked-in typed accessors with a presentation-only test boundary.

Portable model suites do not test localization lookup or Foundation plural rules;
those are covered by test_localization.py against the real runtime and resources.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def localization_sources(directory):
    bridge = Path(directory) / 'LocalizationPresentationBoundary.swift'
    bridge.write_text('''import Foundation
// Domain-model tests keep rendering deterministic; compile the real generated API.
enum L10n {
    static func render(table: String, key: String, arguments: [CVarArg] = [],
                       englishFallback: String, language: String? = nil) -> String {
        if arguments.isEmpty { return englishFallback.replacingOccurrences(of: "%%", with: "%") }
        return String(format: englishFallback, locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }
}
''')
    return [str(ROOT / 'Sources/ProxyMirrorCore/Localization/Generated/Strings.swift'),
            str(ROOT / 'Sources/ProxyMirrorCore/Localization/Generated/EnglishFallbacks.swift'),
            str(ROOT / 'Sources/ProxyMirrorCore/System/LocalizedErrorPresentation.swift'),
            str(ROOT / 'Sources/ProxyMirrorCore/System/GeneratedModelOperationIssues.swift'),
            str(ROOT / 'Sources/ProxyMirrorCore/System/ModelOperationIssues.swift'), str(bridge)]
