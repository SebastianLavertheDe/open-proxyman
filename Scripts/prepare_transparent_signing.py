"""Validate Developer ID profiles and prepare the optional system extension for signing."""

import argparse
from datetime import datetime
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import sys


APP_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"
NETWORK_EXTENSION = "com.apple.developer.networking.networkextension"
APP_PROXY = "app-proxy-provider-systemextension"
INSTALL_EXTENSION = "com.apple.developer.system-extension.install"
APP_GROUPS = "com.apple.security.application-groups"


def developer_id_identity(requested, keychain=None):
    command = ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]
    if keychain is not None:
        command.append(str(keychain))
    identities = subprocess.check_output(command, text=True)
    matches = []
    for fingerprint, name, team in re.findall(
        r'^\s*\d+\) ([0-9A-F]{40}) "(Developer ID Application: .+ \(([A-Z0-9]{10})\))"$',
        identities,
        re.MULTILINE,
    ):
        if requested == name or requested.upper() == fingerprint:
            matches.append((fingerprint, team))
    if len(matches) != 1:
        raise ValueError("PM_DEVELOPER_ID 必须匹配唯一有效的 Developer ID Application 签名身份")
    return matches[0]


def read_plist(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def write_plist(path, values):
    with path.open("wb") as stream:
        plistlib.dump(values, stream)


def prepare_profile(path, contents, bundle_id, team_id, fingerprint, host):
    # Decode the same bytes that go into the bundle.
    embedded = contents / "embedded.provisionprofile"
    embedded.write_bytes(path.read_bytes())
    result = subprocess.check_output(["/usr/bin/security", "cms", "-D", "-i", embedded])
    profile = plistlib.loads(result)
    allowed = profile.get("Entitlements", {})
    if profile.get("ProvisionsAllDevices") is not True:
        raise ValueError(f"{path} 不是可在任意 Mac 使用的 Developer ID 描述文件")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime) or expiration <= datetime.utcnow():
        raise ValueError(f"{path} 的描述文件已过期或缺少有效期")
    application_id = allowed.get(APP_ID)
    prefix, _, identifier = (application_id or "").partition(".")
    if identifier != bundle_id or prefix not in profile.get("ApplicationIdentifierPrefix", ()):
        raise ValueError(f"{path} 必须使用明确的 App ID {bundle_id}")
    if team_id not in profile.get("TeamIdentifier", ()) or allowed.get(TEAM_ID) != team_id:
        raise ValueError(f"{path} 的 Team ID 与 Developer ID 签名证书不一致")
    certificates = profile.get("DeveloperCertificates", ())
    if fingerprint not in {hashlib.sha1(cert).hexdigest().upper() for cert in certificates}:
        raise ValueError(f"{path} 未授权所选的 Developer ID 签名证书")
    if APP_PROXY not in allowed.get(NETWORK_EXTENSION, ()):
        raise ValueError(f"{path} 缺少 Network Extension 权限 {APP_PROXY}")
    entitlements = {
        APP_ID: application_id,
        TEAM_ID: team_id,
        NETWORK_EXTENSION: [APP_PROXY],
    }
    if host:
        if allowed.get(INSTALL_EXTENSION) is not True:
            raise ValueError(f"{path} 缺少 System Extension 安装权限")
        entitlements[INSTALL_EXTENSION] = True
    return entitlements


def prepare(args):
    fingerprint, team_id = developer_id_identity(args.identity)
    host_contents = args.app / "Contents"
    host_info_path = host_contents / "Info.plist"
    host_info = read_plist(host_info_path)
    host_id = host_info["CFBundleIdentifier"]
    extension_id = f"{host_id}.transparent-proxy"
    extension_contents = (
        host_contents / "Library" / "SystemExtensions" / f"{extension_id}.systemextension" / "Contents"
    )
    (extension_contents / "MacOS").mkdir(parents=True)
    host_entitlements = prepare_profile(
        args.app_profile, host_contents, host_id, team_id, fingerprint, host=True
    )
    extension_entitlements = prepare_profile(
        args.extension_profile, extension_contents, extension_id, team_id, fingerprint, host=False
    )

    extension_template = (
        Path(__file__).resolve().parents[1] / "Resources" / "TransparentExtension" / "Info.plist"
    )
    extension_info = read_plist(extension_template)
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"):
        extension_info[key] = host_info[key]
    extension_info["CFBundleIdentifier"] = extension_id
    host_info["NSSystemExtensionUsageDescription"] = extension_info["NSSystemExtensionUsageDescription"]
    # NetworkExtension requires a Mach service name inside an app group. On macOS,
    # a team-prefixed app group can be used without a separate provisioning entry.
    group = f"{team_id}.{host_id}"
    extension_info["NetworkExtension"]["NEMachServiceName"] = f"{group}.transparent-proxy"
    host_entitlements[APP_GROUPS] = [group]
    extension_entitlements.update({
        APP_GROUPS: [group],
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
    })
    write_plist(host_info_path, host_info)
    write_plist(extension_contents / "Info.plist", extension_info)
    write_plist(args.app.parent / "app.entitlements", host_entitlements)
    write_plist(args.app.parent / "extension.entitlements", extension_entitlements)
    print(fingerprint)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("identity")
    parser.add_argument("app_profile", type=Path)
    parser.add_argument("extension_profile", type=Path)
    try:
        prepare(parser.parse_args())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"透明代理签名准备失败：{error}", file=sys.stderr)
        sys.exit(1)
