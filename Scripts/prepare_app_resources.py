#!/usr/bin/env python3
"""Prepare the copied SwiftPM resources and plaintext licenses before signing."""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans")


def normalize_localizations(bundle):
    resources = bundle / "Contents/Resources" if (bundle / "Contents/Resources").is_dir() else bundle
    for language in LANGUAGES:
        canonical = f"{language}.lproj"
        matches = [path for path in resources.iterdir()
                   if path.name.casefold() == canonical.casefold() and path.is_dir()]
        if len(matches) != 1:
            raise ValueError(f"Expected one {canonical} directory in {resources}, found {len(matches)}")
        source = matches[0]
        if source.name == canonical:
            continue
        # Two renames also work on the default case-insensitive macOS filesystem.
        temporary = resources / f".{canonical}.renaming"
        if temporary.exists():
            raise ValueError(f"Unexpected localization staging directory: {temporary}")
        source.rename(temporary)
        try:
            temporary.rename(resources / canonical)
        except OSError:
            temporary.rename(source)
            raise


def write_licenses(destination):
    destination.mkdir(parents=True, exist_ok=True)
    for source, name in (
        (ROOT / "ThirdParty/ScriptingLibraries.md", "ScriptingLibraries-LICENSE"),
        (ROOT / "Sources/ProxyMirrorZstd/LICENSE", "Zstandard-LICENSE"),
    ):
        # Read through the filesystem's text interface rather than copying the
        # document and its encryption metadata into the signed resource envelope.
        text = source.read_text(encoding="utf-8")
        if not text.strip():
            raise ValueError(f"Empty third-party license: {source}")
        (destination / name).write_text(text, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("licenses", type=Path)
    args = parser.parse_args()
    normalize_localizations(args.bundle)
    write_licenses(args.licenses)


if __name__ == "__main__":
    main()
