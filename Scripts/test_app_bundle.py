"""Check a packaged ProxyMirror app without launching its UI or changing macOS settings."""

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys

from prepare_transparent_signing import (
    APP_GROUPS, APP_ID, APP_PROXY, INSTALL_EXTENSION, NETWORK_EXTENSION, TEAM_ID,
)
from test_localization_bundle import verify_resources


def verify_transparent_extension(app, info):
    extension_id = f"{info['CFBundleIdentifier']}.transparent-proxy"
    contents = app / "Contents" / "Library" / "SystemExtensions" / f"{extension_id}.systemextension" / "Contents"
    with (contents / "Info.plist").open("rb") as stream:
        extension_info = plistlib.load(stream)
    executable_name = "ProxyMirrorTransparentExtension"
    expected = {
        "CFBundleIdentifier": extension_id,
        "CFBundleExecutable": executable_name,
        "CFBundlePackageType": "SYSX",
        "CFBundleVersion": info["CFBundleVersion"],
        "CFBundleShortVersionString": info["CFBundleShortVersionString"],
        "LSMinimumSystemVersion": info["LSMinimumSystemVersion"],
    }
    for key, value in expected.items():
        if extension_info.get(key) != value:
            raise ValueError(f"Extension {key}: expected {value!r}, got {extension_info.get(key)!r}")
    if not info.get("NSSystemExtensionUsageDescription") or not extension_info.get("NSSystemExtensionUsageDescription"):
        raise ValueError("Missing system extension usage description")

    host_entitlements, extension_entitlements = [
        plistlib.loads(subprocess.check_output(
            ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", bundle]
        ))
        for bundle in (app, contents.parent)
    ]
    team_id = host_entitlements.get(TEAM_ID)
    if not team_id or extension_entitlements.get(TEAM_ID) != team_id:
        raise ValueError("App and extension require the same signing team")
    if host_entitlements.get(INSTALL_EXTENSION) is not True:
        raise ValueError("Host is missing system extension installation entitlement")
    group = f"{team_id}.{info['CFBundleIdentifier']}"
    for bundle_contents, bundle_id, entitlements in (
        (app / "Contents", info["CFBundleIdentifier"], host_entitlements),
        (contents, extension_id, extension_entitlements),
    ):
        requirement = (
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            f'and certificate leaf[subject.OU] = "{team_id}" and identifier "{bundle_id}"'
        )
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", "-R", f"={requirement}", bundle_contents.parent],
            check=True,
        )
        if not (bundle_contents / "embedded.provisionprofile").is_file():
            raise ValueError(f"{bundle_id} is missing its embedded provisioning profile")
        if not (entitlements.get(APP_ID) or "").endswith(f".{bundle_id}"):
            raise ValueError(f"{bundle_id} has an incorrect application identifier")
        if APP_PROXY not in entitlements.get(NETWORK_EXTENSION, []) or group not in entitlements.get(APP_GROUPS, []):
            raise ValueError(f"{bundle_id} is missing Network Extension or App Groups entitlements")
    network = extension_info.get("NetworkExtension", {})
    if network.get("NEMachServiceName") != f"{group}.transparent-proxy":
        raise ValueError("Unexpected NetworkExtension Mach service")
    if network.get("NEProviderClasses", {}).get("com.apple.networkextension.app-proxy") != (
        f"{executable_name}.TransparentProxyProvider"
    ):
        raise ValueError("Unexpected transparent proxy provider class")
    return contents / "MacOS" / executable_name


def verify_system_proxy_identity(binary, expected_identifier):
    signing = subprocess.check_output(["/usr/bin/codesign", "-dvvv", binary], stderr=subprocess.STDOUT, text=True)
    match = re.search(r"^CDHash=([0-9a-f]{40})$", signing, re.MULTILINE)
    if not match or not re.search(r"^CodeDirectory .*\bruntime\b", signing, re.MULTILINE):
        raise ValueError(f"{binary.name} requires a CodeDirectory hash and hardened runtime")
    requirement = f'identifier "{expected_identifier}" and cdhash H"{match[1]}"'
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", f"={requirement}", binary], check=True)



def verify_bundle(app, expect_transparent=False):
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {
        "CFBundleIdentifier": "com.sebastianLavertheDe.proxymirror",
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "ProxyMirror",
        "LSMinimumSystemVersion": "13.0",
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"{key}: expected {value!r}, got {info.get(key)!r}")

    verify_resources(app, expect_transparent)

    executable = contents / "MacOS" / info["CFBundleExecutable"]
    helpers = [contents / "MacOS" / name
               for name in ("ProxyMirrorScriptWorker", "ProxyMirrorSystemProxyHelper")]
    if expect_transparent:
        helpers.append(verify_transparent_extension(app, info))
    elif list((contents / "Library" / "SystemExtensions").glob("*.systemextension")):
        raise ValueError("Default app unexpectedly contains a system extension")
    architectures = []
    for binary in (executable, *helpers):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f"Missing executable: {binary}")
        archs = subprocess.check_output(["/usr/bin/lipo", "-archs", binary], text=True).split()
        architectures.append(set(archs))
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", binary], check=True)
    if any(archs != architectures[0] for archs in architectures) or platform.machine() not in architectures[0]:
        raise ValueError(f"App/helper architectures {architectures} on {platform.machine()}")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)

    verify_system_proxy_identity(app, info["CFBundleIdentifier"])
    verify_system_proxy_identity(helpers[1], "com.sebastianLavertheDe.proxymirror.system-proxy")
    if os.geteuid() != 0:
        for arguments in (["--install", str(os.geteuid()), "0" * 40], ["--uninstall"]):
            denial = subprocess.run([helpers[1], *arguments], capture_output=True, timeout=5)
            if denial.returncode != 1 or not denial.stderr.strip() or denial.stdout:
                raise ValueError("Unprivileged helper invocation did not fail closed")
            diagnostic = denial.stderr.decode("utf-8").strip()
            if not diagnostic.startswith("pm-error-v1:"):
                raise ValueError("The helper did not return a stable authorization error")
            error = json.loads(diagnostic.removeprefix("pm-error-v1:"))
            if error.get("domain") != "ProxyMirror.SystemProxy" or error.get("code") != "authorizationRequired":
                raise ValueError("The helper returned the wrong authorization error code")

    help_result = subprocess.run([executable, "--help"], check=True, capture_output=True,
                                 text=True, timeout=5)
    for command in ("status", "traffic", "export-har", "rules"):
        if command not in help_result.stdout:
            raise ValueError(f"Packaged CLI help is missing {command}")
    print(f"PASS  package metadata, pinned service identities, signatures, {' '.join(sorted(architectures[0]))}, CLI help")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--app", type=Path, default=root / "build_app/ProxyMirror.app")
    parser.add_argument("--expect-transparent", action="store_true")
    args = parser.parse_args()
    try:
        verify_bundle(args.app.resolve(strict=True), args.expect_transparent)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL  app bundle: {error}", file=sys.stderr)
        sys.exit(1)
