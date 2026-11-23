#!/usr/bin/env python3
"""Configure an already staged app Info.plist; this never creates or publishes releases."""
import argparse
import base64
import os
import plistlib
import sys
from urllib.parse import urlsplit


def update_configuration(feed, public_key):
    feed, public_key = feed.strip(), public_key.strip()
    if not feed and not public_key:
        return None
    if not feed or not public_key:
        raise ValueError("PM_APPCAST_URL 和 PM_UPDATE_PUBLIC_KEY 必须同时设置。")
    url = urlsplit(feed)
    if url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None or url.fragment:
        raise ValueError("PM_APPCAST_URL 必须是无用户名、密码或 fragment 的 HTTPS URL。")
    if url.port is not None and not 1 <= url.port <= 65535:
        raise ValueError("PM_APPCAST_URL 的端口无效。")
    try:
        key = base64.b64decode(public_key, validate=True)
    except ValueError as error:
        raise ValueError("PM_UPDATE_PUBLIC_KEY 必须是 Base64 Ed25519 公钥。") from error
    if len(key) != 32:
        raise ValueError("PM_UPDATE_PUBLIC_KEY 解码后必须正好为 32 字节。")
    return {
        "SUFeedURL": feed,
        "SUPublicEDKey": public_key,
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUScheduledCheckInterval": 86400,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", help="staged .app directory")
    args = parser.parse_args()
    configuration = update_configuration(os.environ.get("PM_APPCAST_URL", ""),
                                         os.environ.get("PM_UPDATE_PUBLIC_KEY", ""))
    if configuration is None:
        print("未配置签名更新源，保留手动 Releases 更新入口。")
        return
    path = os.path.join(args.app, "Contents", "Info.plist")
    with open(path, "rb") as source:
        information = plistlib.load(source)
    information.update(configuration)
    with open(path, "wb") as destination:
        plistlib.dump(information, destination, sort_keys=False)
    print("已配置签名 Sparkle 更新源；自动检查默认关闭。")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
