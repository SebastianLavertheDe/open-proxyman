#!/usr/bin/env python3
"""Compile the real numeric IP/CIDR policy with the production typed error API."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
from localization_model_test_support import localization_sources
ROOT=Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--swiftc',default='swiftc');args=parser.parse_args();compiler=shutil.which(args.swiftc) or args.swiftc
    with tempfile.TemporaryDirectory(prefix='pm-access-') as temporary:
        directory=Path(temporary);binary=directory/'checks'
        typed_sources=localization_sources(directory)
        fallback=str(ROOT/'Sources/ProxyMirrorCore/Localization/Generated/EnglishFallbacks.swift')
        if fallback not in typed_sources: typed_sources.append(fallback)
        source=['Sources/ProxyMirrorCore/System/NetworkAccessPolicy.swift','Sources/ProxyMirrorCore/System/LocalizedErrorPresentation.swift','Sources/ProxyMirrorCore/System/GeneratedOperationIssues.swift','Tests/ProxyMirrorCoreChecks/NetworkAccessChecks.swift','Tests/Fixtures/NetworkAccess/main.swift']
        sources=list(dict.fromkeys([*[str(ROOT/p) for p in source],*typed_sources]))
        subprocess.run([compiler,'-swift-version','5','-module-cache-path',str(directory/'modules'),*sources,'-o',str(binary)],check=True,timeout=120)
        subprocess.run([str(binary)],check=True,timeout=20)
if __name__=='__main__':main()
