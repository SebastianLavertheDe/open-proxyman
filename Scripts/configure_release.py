#!/usr/bin/env python3
"""Apply optional, validated release metadata before signing the app."""
import os
from pathlib import Path
import plistlib
import re
import sys

from prepare_transparent_signing import developer_id_identity


def signing_identity(environment, keychain):
    """Resolve only the imported keychain and bind signing to the notary team."""
    fingerprint, team = developer_id_identity(environment.get("PM_DEVELOPER_ID", ""), keychain)
    if team != environment.get("PM_NOTARY_TEAM_ID"):
        raise ValueError("Developer ID Application team must match PM_NOTARY_TEAM_ID")
    return fingerprint


def configure(app, environment):
    version = environment.get("PM_RELEASE_VERSION")
    build = environment.get("PM_BUILD_NUMBER")
    if version is None and build is None:
        return
    if not version or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("PM_RELEASE_VERSION must be a numeric major.minor.patch version")
    if not build or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("PM_BUILD_NUMBER must be a positive, increasing integer")
    path = Path(app) / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = build
    path.write_bytes(plistlib.dumps(info, sort_keys=False))


if __name__ == "__main__":
    try:
        configure(sys.argv[1], os.environ)
    except (ValueError, IndexError) as error:
        raise SystemExit(str(error))
