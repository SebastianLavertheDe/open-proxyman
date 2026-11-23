#!/usr/bin/env python3
"""Run the actual one-time storage reset against disposable directories and defaults."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc) or args.swiftc
    source = (ROOT / 'Tests/ProxyMirrorCoreChecks/LocalizationStorageChecks.swift').read_text()
    source = source.split('@MainActor\nfunc checkLocalizationModelStorage', 1)[0]
    source = source.replace('@testable import ProxyMirrorCore\n', '')
    assertions = (ROOT / 'Tests/ProxyMirrorCoreChecks/CoreChecks.swift').read_text()
    assertions = 'import Foundation\nstruct CoreAssertions {' + assertions.split('struct CoreAssertions {', 1)[1]
    assertions = assertions.split('func makeCheckDirectory', 1)[0]
    support = '''
func makeCheckDirectory() throws -> URL {
    let result = FileManager.default.temporaryDirectory.appendingPathComponent("pm-storage-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    return result
}
'''
    entry = '''import Foundation
@main struct Run {
    static func main() throws {
        var checks = 0
        var failures = 0
        let test = CoreAssertions { passed, message, _, _ in
            checks += 1
            if !passed { failures += 1; print("FAIL: " + message) }
        }
        try checkLocalizationStorage(test)
        guard failures == 0 else { exit(1) }
        print("PASS: \\(checks) real storage reset checks in isolated directories/preferences")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix='pm-localization-storage-') as folder:
        work = Path(folder)
        (work / 'Checks.swift').write_text(source)
        (work / 'Assertions.swift').write_text(assertions + support)
        (work / 'Run.swift').write_text(entry)
        executable = work / 'checks'
        subprocess.run([compiler, '-swift-version', '5',
                        str(ROOT / 'Sources/ProxyMirrorCore/System/LocalizationStorage.swift'),
                        str(work / 'Checks.swift'), str(work / 'Assertions.swift'), str(work / 'Run.swift'),
                        '-o', str(executable)], check=True, timeout=90)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    main()
