#!/usr/bin/env python3
"""Validate shipped language resources and run an isolated, read-only macOS probe."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

LANGUAGES = ("en", "zh-Hans")
CORE_BUNDLE = "ProxyMirror_ProxyMirrorCore.bundle"
ROOT = Path(__file__).resolve().parents[1]
TOKEN = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;', re.S)


def read_strings(path):
    data = path.read_bytes()
    if data.startswith(b"bplist") or data.lstrip().startswith(b"<?xml"):
        result = plistlib.loads(data)
        if not isinstance(result, dict):
            raise ValueError(f"Invalid string table: {path}")
        return result
    text = data.decode("utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig")
    values, offset = {}, 0
    while offset < len(text):
        match = TOKEN.match(text, offset)
        if not match:
            raise ValueError(f"Invalid strings syntax in {path} at offset {offset}")
        offset = match.end()
        if match.group(1) is not None:
            key, value = (json.loads(item.replace("\\U", "\\u")) for item in match.groups())
            if key in values:
                raise ValueError(f"Duplicate key {key} in {path}")
            values[key] = value
    if any(not isinstance(k, str) or not isinstance(v, str) or not v for k, v in values.items()):
        raise ValueError(f"Invalid or empty translation in {path}")
    return values


def verify_metadata(resources, required, canonical_resources):
    translations = {}
    for language in LANGUAGES:
        table = read_strings(resources / f"{language}.lproj/InfoPlist.strings")
        missing = set(required) - table.keys()
        if missing:
            raise ValueError(f"Missing {language} InfoPlist translations: {sorted(missing)}")
        canonical = read_strings(canonical_resources / f"{language}.lproj/InfoPlist.strings")
        if table != canonical:
            raise ValueError(f"Packaged {language} InfoPlist translations differ from source")
        translations[language] = table
    if translations["en"].keys() != translations["zh-Hans"].keys():
        raise ValueError("InfoPlist language keys differ")


def verify_resources(app, expect_transparent=False):
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if set(info.get("CFBundleLocalizations", [])) != set(LANGUAGES):
        raise ValueError("The app must declare exactly en and zh-Hans")
    if info.get("CFBundleDevelopmentRegion") != "en":
        raise ValueError("The app development language must match the English fallback")
    resources = contents / "Resources"
    verify_metadata(resources, ("CFBundleDisplayName", "NSAppleEventsUsageDescription"), ROOT / "Resources")
    core = resources / CORE_BUNDLE
    if not core.is_dir() or core.is_symlink():
        raise ValueError("The app must contain its own Core language resource bundle")
    localized = core / "Contents/Resources" if (core / "Contents/Resources").is_dir() else core
    tables = {}
    for language in LANGUAGES:
        folder = localized / f"{language}.lproj"
        if not folder.is_dir():
            raise ValueError(f"Missing Core language directory: {language}")
        files = {item.name: item for item in folder.iterdir()
                 if item.suffix in (".strings", ".stringsdict")}
        if not files:
            raise ValueError(f"Empty Core language directory: {language}")
        tables[language] = files
    if tables["en"].keys() != tables["zh-Hans"].keys():
        raise ValueError("Packaged Core language tables differ")
    # 两边同时漏掉整张表也必须失败，不能只互相比较复制结果。
    for language in LANGUAGES:
        canonical = {item.name: item for item in
                     (ROOT / "Sources/ProxyMirrorCore/Resources" / f"{language}.lproj").iterdir()
                     if item.suffix in (".strings", ".stringsdict")}
        if tables[language].keys() != canonical.keys():
            raise ValueError(f"Packaged {language} tables differ from the source resource manifest")
        for name, packaged in tables[language].items():
            if packaged.suffix == ".strings":
                if read_strings(packaged) != read_strings(canonical[name]):
                    raise ValueError(f"Packaged {language} translations differ: {name}")
            elif plistlib.loads(packaged.read_bytes()) != plistlib.loads(canonical[name].read_bytes()):
                raise ValueError(f"Packaged {language} plural rules differ: {name}")
    for name, path in tables["en"].items():
        other = tables["zh-Hans"][name]
        if path.suffix == ".strings":
            if read_strings(path).keys() != read_strings(other).keys():
                raise ValueError(f"Packaged language keys differ: {name}")
        else:
            english, chinese = plistlib.loads(path.read_bytes()), plistlib.loads(other.read_bytes())
            if english.keys() != chinese.keys():
                raise ValueError(f"Packaged plural keys differ: {name}")
    if expect_transparent:
        extension = contents / "Library/SystemExtensions" / (info["CFBundleIdentifier"] + ".transparent-proxy.systemextension")
        extension_info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
        if set(extension_info.get("CFBundleLocalizations", [])) != set(LANGUAGES):
            raise ValueError("The extension must declare both languages")
        verify_metadata(extension / "Contents/Resources",
                        ("CFBundleDisplayName", "NSSystemExtensionUsageDescription"),
                        ROOT / "Resources/TransparentExtension")
    return len(tables["en"])


def verify_selection_count(item, language):
    count = item["count"]
    # Foundation can apply locale grouping even to the same native plural rule.
    numbers = {str(count), f"{count:,}"}
    expected = {(f"{number} request{'s' if count != 1 else ''} selected"
                 if language == "en" else f"已选择 {number} 条请求") for number in numbers}
    if item["text"] not in expected:
        raise ValueError(f"Incorrect native plural result: {item!r}, expected one of {sorted(expected)!r}")


def verify_runtime(app):
    if sys.platform != "darwin":
        raise RuntimeError("The packaged App runtime probe requires macOS")
    with tempfile.TemporaryDirectory(prefix="pm-localization-app-") as temp:
        base = Path(temp)
        moved = base / "Moved ProxyMirror.app"
        shutil.copytree(app, moved)
        info = plistlib.loads((moved / "Contents/Info.plist").read_bytes())
        binary = moved / "Contents/MacOS" / info["CFBundleExecutable"]
        env = dict(os.environ, PM_SUPPORT_DIR=str(base / "isolated-support"))
        records = []
        for language in LANGUAGES:
            env["PM_SETTINGS_LANGUAGE"] = language
            result = subprocess.run([str(binary), "--check-localization"], cwd=base, env=env,
                                    capture_output=True, text=True, timeout=15, check=True)
            record = json.loads(result.stdout)
            if record.get("version") != 1:
                raise ValueError("Unknown localization probe format")
            expected = "Application Language" if language == "en" else "应用语言"
            if record["language"] != language or record["label"] != expected:
                raise ValueError(f"Incorrect packaged language selection: {record}")
            resource = Path(record["resourceBundle"]).resolve()
            if moved.resolve() not in resource.parents:
                raise ValueError("The moved app read resources outside its own bundle")
            if [item["count"] for item in record["counts"]] != [0, 1, 2, 101, 1000]:
                raise ValueError("The native probe did not exercise the complete plural matrix")
            for item in record["counts"]:
                verify_selection_count(item, language)
            records.append(record)
        # 移除复制品的资源，证明不会借用原 App 或构建目录。
        shutil.rmtree(moved / "Contents/Resources" / CORE_BUNDLE)
        result = subprocess.run([str(binary), "--check-localization"], cwd=base, env=env,
                                capture_output=True, text=True, timeout=15)
        if result.returncode != 78 or not result.stderr.strip() or result.stdout:
            raise ValueError("A damaged copied app did not fail with a resource diagnosis")
        return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--expect-transparent", action="store_true")
    parser.add_argument("--runtime", action="store_true")
    args = parser.parse_args()
    count = verify_resources(args.app, args.expect_transparent)
    if args.runtime:
        verify_runtime(args.app)
    print(f"PASS: packaged bilingual resources ({count} tables)" + (" and relocated native runtime" if args.runtime else ""))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
