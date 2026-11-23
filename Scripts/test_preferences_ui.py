#!/usr/bin/env python3
"""Capture real native preferences pages on macOS, without screen-recording permission.

The app uses an isolated support directory and skips proxy, MCP and update startup.
This captures NSView content without changing the personal App or its preferences.
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import uuid

from test_cli import prepare_bundle, write_preferences

PAGES = ("general", "appearance", "privacy", "mcp", "github", "tools", "network", "advanced", "workspace", "products")


def png_size(path):
    header = path.read_bytes()[:24]
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError(f"Not a PNG: {path}")
    return struct.unpack(">II", header[16:24])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("build_app/ProxyMirror.app"))
    parser.add_argument("--output", type=Path, default=Path("build_app/preferences-review"))
    parser.add_argument("--pages", nargs="+", choices=PAGES, default=list(PAGES))
    parser.add_argument("--appearance", choices=("dark", "light", "both"), default="dark")
    parser.add_argument("--language", choices=("zh-Hans", "en", "both"), default="both")
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native preferences capture requires macOS; run this after building on the host Mac.")
    source_app = args.app.resolve()
    if not (source_app / "Contents/MacOS/ProxyMirror").is_file():
        parser.error(f"Build the app first: {source_app}")
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    appearances = ("dark", "light") if args.appearance == "both" else (args.appearance,)
    languages = ("zh-Hans", "en") if args.language == "both" else (args.language,)
    manifest = []
    identifier = "com.proxymirror.tests.preferences." + uuid.uuid4().hex
    try:
        with tempfile.TemporaryDirectory(prefix="pm-preferences-app-") as app_folder:
            # 测试 App 和偏好域均隔离，首次新版存储初始化不会清理个人实例。
            binary = prepare_bundle(source_app, Path(app_folder) / "ProxyMirror.app", identifier)
            write_preferences(identifier, 9090)
            subprocess.run(["/usr/bin/defaults", "write", identifier, "proxy.autoStart", "-bool", "false"],
                           check=True, timeout=5)
            for language in languages:
                subprocess.run(["/usr/bin/defaults", "write", identifier, "ui.applicationLanguage", language],
                               check=True, timeout=5)
                for appearance in appearances:
                    for page in args.pages:
                        basename = f"{page}-{appearance}-{language}"
                        output = destination / f"{basename}.png"
                        output.unlink(missing_ok=True)
                        with tempfile.TemporaryDirectory(prefix="pm-preferences-preview-") as support:
                            env = {**os.environ, "PM_SUPPORT_DIR": support, "PM_SETTINGS_PAGE": page,
                                   "PM_SETTINGS_SNAPSHOT": str(output), "PM_SETTINGS_APPEARANCE": appearance,
                                   "PM_SETTINGS_LANGUAGE": language}
                            # 快照路径跳过捕获、MCP 与更新服务；只修改测试自己的偏好域。
                            with (destination / f"{basename}.log").open("w") as log:
                                process = subprocess.Popen([str(binary)], env=env, stdout=log,
                                                           stderr=subprocess.STDOUT)
                                try:
                                    code = process.wait(timeout=args.timeout)
                                except subprocess.TimeoutExpired:
                                    process.terminate()
                                    try:
                                        process.wait(timeout=5)
                                    except subprocess.TimeoutExpired:
                                        process.kill()
                                        process.wait(timeout=5)
                                    raise AssertionError(f"Capture timed out: {page}; see {basename}.log")
                            if code != 0 or not output.is_file():
                                raise AssertionError(f"Capture failed: {page} (exit {code}); see {basename}.log")
                        width, height = png_size(output)
                        if width < 970 or height < 750:
                            raise AssertionError(f"Unexpected native window size: {width}x{height}")
                        manifest.append({"page": page, "appearance": appearance, "language": language,
                                         "file": output.name, "width": width, "height": height})
                        print(f"PASS: {basename}: real native PNG {width}x{height}")
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", identifier], check=False, capture_output=True, timeout=5)
    (destination / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"Saved {len(manifest)} native captures to {destination}")


if __name__ == "__main__":
    main()
