#!/usr/bin/env python3
"""Check native resources and the committed SwiftGen-generated interface."""
from __future__ import annotations
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/ProxyMirrorCore/Resources"
GENERATED = ROOT / "Sources/ProxyMirrorCore/Localization/Generated"
TEMPLATE = ROOT / "Scripts/Templates/localization-swift5.stencil"
VERSION = "6.6.3"
TOKEN = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[=;]', re.S)
SPECIFIER = re.compile(r'%(?:(\d+)\$)?(?:#@([A-Za-z_][A-Za-z_0-9]*)@|[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|ll|h|l|L|z|t|j)?([@diuoxXfFeEgGaAcsp]))')
KEY = re.compile(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*\Z")

def load_strings(path):
    text = path.read_text(encoding="utf-8-sig")
    tokens, end = [], 0
    for match in TOKEN.finditer(text):
        if text[end:match.start()].strip():
            raise ValueError(f"{path}: invalid syntax near {text[end:match.start()]!r}")
        value = match.group()
        if not value.startswith(("/*", "//")): tokens.append(value)
        end = match.end()
    if text[end:].strip() or len(tokens) % 4: raise ValueError(f"{path}: incomplete entry")
    values = {}
    for index in range(0, len(tokens), 4):
        key, equals, value, semicolon = tokens[index:index + 4]
        if equals != "=" or semicolon != ";": raise ValueError(f"{path}: expected key = value;")
        def decode(token): return json.loads(re.sub(r"\\U([0-9A-Fa-f]{4})", r"\\u\1", token))
        key, value = decode(key), decode(value)
        if key in values: raise ValueError(f"{path}: duplicate {key!r}")
        if not KEY.fullmatch(key): raise ValueError(f"{path}: expected stable lower_snake_case key: {key!r}")
        if not value.strip(): raise ValueError(f"{path}: empty {key}")
        values[key] = value
    return values

def parameter_type(length, conversion):
    if conversion == "@": return "String"
    if conversion in "fFeEgGaA": return "Double"
    if conversion in "diuoxX" and length != "L": return "Int64" if length == "ll" else "Int"
    if conversion == "c": return "Int"
    raise ValueError(f"Unsupported interface format %{length}{conversion}; use %@ for text")

def format_parameters(value, plural_variables=None, allow_sparse=False, implicit_start=1):
    """Keep parameter positions and plural bindings until all references are checked."""
    plural_variables = plural_variables or {}
    parameters, bindings, next_position, explicit, implicit = {}, {}, implicit_start, False, False
    work = value.replace("%%", "")
    matches = list(SPECIFIER.finditer(work))
    covered = {index for match in matches for index in range(match.start(), match.end())}
    if any(character == "%" and index not in covered for index, character in enumerate(work)):
        raise ValueError(f"Unescaped literal percentage or invalid placeholder in {value!r}; use %% for a literal percentage")
    for match in matches:
        position = int(match.group(1)) if match.group(1) else next_position
        if position < 1: raise ValueError(f"Invalid placeholder position {position} in {value!r}")
        if match.group(1): explicit = True
        else:
            implicit = True
            next_position += 1
        name = match.group(2)
        if name is not None:
            if name not in plural_variables: raise ValueError(f"Unknown plural variable {name}")
            spec = plural_variables[name]["NSStringFormatValueTypeKey"]
            kind = parameter_type(spec[:-1], spec[-1])
            bindings.setdefault(name, set()).add(position)
        else:
            kind = parameter_type(match.group(3) or "", match.group(4))
        if position in parameters and parameters[position] != kind:
            raise ValueError(f"Conflicting placeholder {position} in {value!r}")
        parameters[position] = kind
    if explicit and implicit: raise ValueError(f"Mixed placeholder positions in {value!r}")
    if parameters and not allow_sparse and sorted(parameters) != list(range(1, len(parameters) + 1)):
        raise ValueError(f"Non-contiguous positions in {value!r}")
    return parameters, bindings

def signature(value, plural_variables=None, allow_sparse=False):
    """Compare complete call signatures while permitting grammatical reordering."""
    parameters, _ = format_parameters(value, plural_variables, allow_sparse)
    return tuple(parameters[position] for position in sorted(parameters))

def validate_parameter_references(parameters, available, context):
    for position, kind in parameters.items():
        if position not in available:
            raise ValueError(f"{context}: placeholder position {position} is outside the message arguments")
        if available[position] != kind:
            raise ValueError(f"{context}: placeholder {position} expects {available[position]}, got {kind}")

def load_plurals(path, language, fallbacks=None):
    if not path.exists(): return {}
    values = plistlib.loads(path.read_bytes())
    if not isinstance(values, dict): raise ValueError(f"{path}: expected dictionary")
    for key, entry in values.items():
        if not KEY.fullmatch(key) or not isinstance(entry, dict): raise ValueError(f"{path}: invalid plural {key}")
        if not isinstance(entry.get("NSStringLocalizedFormatKey"), str): raise ValueError(f"{path}:{key}: missing format")
        variables = {name: rule for name, rule in entry.items() if name != "NSStringLocalizedFormatKey"}
        if not variables: raise ValueError(f"{path}:{key}: no plural variable")
        for name, rule in variables.items():
            if not isinstance(rule, dict) or rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType":
                raise ValueError(f"{path}:{key}:{name}: invalid rule")
            spec = rule.get("NSStringFormatValueTypeKey")
            if spec not in ("ld", "lld", "d"): raise ValueError(f"{path}:{key}:{name}: expected integer")
            required = {"one", "other"} if language == "en" else {"other"}
            if not required <= rule.keys(): raise ValueError(f"{path}:{key}:{name}: missing {required - rule.keys()}")
        outer, bindings = format_parameters(entry["NSStringLocalizedFormatKey"], variables,
                                            allow_sparse=fallbacks is not None)
        if fallbacks is not None:
            if key not in fallbacks: raise ValueError(f"{path}:{key}: missing fallback string")
            available, _ = format_parameters(fallbacks[key])
        else:
            available = outer
        validate_parameter_references(outer, available, f"{path}:{key}")
        for name, rule in variables.items():
            if name not in bindings: raise ValueError(f"{path}:{key}:{name}: unused plural variable")
            for category, text in rule.items():
                if category.startswith("NSString"): continue
                if not isinstance(text, str) or not text.strip(): raise ValueError(f"{path}:{key}: empty variant")
                if category not in {"zero", "one", "two", "few", "many", "other"}:
                    raise ValueError(f"{path}:{key}:{name}: unknown plural category {category}")
                # An implicit %ld consumes this plural variable's argument, which
                # need not be argument 1. Explicit positions refer to the full call.
                for position in bindings[name]:
                    parameters, _ = format_parameters(text, allow_sparse=True, implicit_start=position)
                    validate_parameter_references(parameters, available, f"{path}:{key}:{name}:{category}")
    return values

def camel(key):
    head, *tail = key.split("_")
    return head + "".join(word[:1].upper() + word[1:] for word in tail)

def catalogue():
    catalogues, plurals = {}, {}
    for language in ("en", "zh-Hans"):
        directory = RESOURCES / f"{language}.lproj"
        files = sorted(directory.glob("*.strings"))
        if not files: raise ValueError(f"Missing language resources: {directory}")
        catalogues[language] = {path.stem: load_strings(path) for path in files}
        plurals[language] = {table: load_plurals(directory / (table + ".stringsdict"), language, values)
                            for table, values in catalogues[language].items()}
        orphan = {path.stem for path in directory.glob("*.stringsdict")} - catalogues[language].keys()
        if orphan: raise ValueError(f"{language}: plural tables without fallback strings: {sorted(orphan)}")
    if catalogues["en"].keys() != catalogues["zh-Hans"].keys(): raise ValueError("Language table sets differ")
    for table, english in catalogues["en"].items():
        chinese = catalogues["zh-Hans"][table]
        if english.keys() != chinese.keys():
            raise ValueError(f"{table}: language keys differ: {sorted(english.keys() ^ chinese.keys())}")
        if len({camel(key) for key in english}) != len(english): raise ValueError(f"{table}: duplicate Swift member")
        if plurals["en"][table].keys() != plurals["zh-Hans"][table].keys(): raise ValueError(f"{table}: plural keys differ")
        for key, value in english.items():
            if signature(value) != signature(chinese[key]): raise ValueError(f"{table}.{key}: placeholder signatures differ")
        extra = plurals["en"][table].keys() - english.keys()
        if extra: raise ValueError(f"{table}: plurals need English fallback strings: {sorted(extra)}")
    return catalogues, plurals

def fingerprint():
    digest = hashlib.sha256()
    for path in sorted(RESOURCES.glob("*/*.strings*")):
        digest.update(str(path.relative_to(RESOURCES)).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    digest.update(TEMPLATE.read_bytes())
    digest.update(VERSION.encode())
    return digest.hexdigest()

def swift_literal(value):
    return re.sub(r"\\u([0-9a-fA-F]{4})", r"\\u{\1}", json.dumps(value, ensure_ascii=False))

def english_support(english):
    lines = ["// Generated by Scripts/generate_localization.sh. Do not edit.",
             "import Foundation", "", "enum GeneratedEnglishFallbacks {",
             "    private static let tables: [String: [String: String]] = ["]
    for table, values in sorted(english.items()):
        lines.append(f"        {swift_literal(table)}: [")
        for key, value in sorted(values.items()): lines.append(f"            {swift_literal(key)}: {swift_literal(value)},")
        lines.append("        ],")
    lines.extend(["    ]", "", "    static func value(table: String, key: String) -> String {",
                  '        tables[table]?[key] ?? "The requested message is unavailable."',
                  "    }", "}", ""])
    return "\n".join(lines)

def stage_input(catalogues, directory):
    """Both platforms give SwiftGen the same normalized native resource input."""
    directory.mkdir(parents=True, exist_ok=True)
    for table, values in catalogues["en"].items():
        (directory / (table + ".strings")).write_bytes(plistlib.dumps(values, sort_keys=True))
        plural = RESOURCES / "en.lproj" / (table + ".stringsdict")
        if plural.exists(): shutil.copy2(plural, directory / plural.name)

def swiftgen_executable(generator=None):
    requested = generator or os.environ.get("SWIFTGEN_BIN") or "swiftgen"
    executable = shutil.which(requested)
    if not executable:
        raise ValueError(f"SwiftGen {VERSION} is required to verify generated accessors; install it or set SWIFTGEN_BIN.")
    result = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=30)
    version = result.stdout + result.stderr
    if result.returncode or not re.search(r"^SwiftGen v?" + re.escape(VERSION) + r"(?=\s|\(|$)", version, re.M):
        raise ValueError(f"Expected SwiftGen {VERSION}; found {version.strip()!r}")
    return executable

def render_accessors(catalogues, generator=None):
    """Generate disposable output with the actual pinned SwiftGen executable."""
    executable = swiftgen_executable(generator)
    with tempfile.TemporaryDirectory(prefix="pm-swiftgen-check-") as folder:
        directory = Path(folder)
        inputs, output = directory / "en.lproj", directory / "Strings.swift"
        stage_input(catalogues, inputs)
        result = subprocess.run([executable, "run", "strings", "--templatePath", str(TEMPLATE),
                                 "--param", "resourceFingerprint=" + fingerprint(),
                                 "--output", str(output), str(inputs)],
                                cwd=ROOT, capture_output=True, text=True, timeout=60)
        if result.returncode or not output.exists():
            raise ValueError("SwiftGen accessor verification failed: " + (result.stderr or result.stdout).strip())
        return output.read_bytes()

def verify_generated(catalogues, generated_directory=None, generator=None):
    generated_directory = generated_directory or GENERATED
    accessors = generated_directory / "Strings.swift"
    expected = render_accessors(catalogues, generator)
    if not accessors.exists(): raise ValueError("Generated accessors are missing; regenerate")
    actual = accessors.read_bytes()
    if actual != expected:
        difference = difflib.unified_diff(actual.decode("utf-8").splitlines(),
                                         expected.decode("utf-8").splitlines(),
                                         fromfile="committed Strings.swift", tofile="SwiftGen " + VERSION)
        raise ValueError("Generated accessors differ from real SwiftGen output; run Scripts/generate_localization.sh.\n"
                         + "\n".join(list(difference)[:40]))

def validate_calls(catalogues):
    members = {(table, camel(key)) for table, values in catalogues["en"].items() for key in values}
    problems = []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        if GENERATED in path.parents: continue
        source = path.read_text(encoding="utf-8")
        for match in re.finditer(r"\bStrings\.([A-Z][A-Za-z0-9]*)\.([A-Za-z_][A-Za-z0-9_]*)", source):
            if match.groups() not in members:
                line = source.count("\n", 0, match.start()) + 1
                problems.append(f"{path.relative_to(ROOT)}:{line}: unknown accessor {match.group()}")
        for match in re.finditer(r"\bL10n\.(?:string|format)\s*\(", source):
            line = source.count("\n", 0, match.start()) + 1
            problems.append(f"{path.relative_to(ROOT)}:{line}: legacy string-key localization")
    return problems

def review_inventory(catalogues, plurals):
    """Export a disposable review snapshot; native resources remain canonical."""
    references = {}
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        if GENERATED in path.parents: continue
        source = path.read_text(encoding="utf-8")
        for match in re.finditer(r"\bStrings\.([A-Z][A-Za-z0-9]*)\.([A-Za-z_][A-Za-z0-9_]*)", source):
            references.setdefault(match.groups(), []).append({
                "path": str(path.relative_to(ROOT)),
                "line": source.count("\n", 0, match.start()) + 1,
                "column": match.start() - source.rfind("\n", 0, match.start())
            })
    entries = []
    for table, values in sorted(catalogues["en"].items()):
        for key, english in sorted(values.items()):
            member = camel(key)
            entries.append({
                "table": table, "key": key,
                "en": english, "zh-Hans": catalogues["zh-Hans"][table][key],
                "signature": [{"position": position, "swift_type": kind}
                              for position, kind in enumerate(signature(english), 1)],
                "plural_rules": {language: plurals[language][table].get(key)
                                 for language in ("en", "zh-Hans")},
                "typed_accessor": f"Strings.{table}.{member}",
                "typed_source_references": references.get((table, member), []),
                "human_review": {"status": "pending", "reviewer": None, "notes": None},
                "screenshot_verification": {"status": "pending", "en": None, "zh-Hans": None},
                "length_constraints": None
            })
    return {"schema_version": 1, "kind": "localization_review_snapshot",
            "canonical_source": str(RESOURCES.relative_to(ROOT)),
            "resource_fingerprint": fingerprint(), "entry_count": len(entries),
            "notice": "Derived review snapshot, not a translation source. Edit the native resource files.",
            "entries": entries}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fingerprint", action="store_true")
    parser.add_argument("--write-support", action="store_true")
    parser.add_argument("--resources-only", action="store_true")
    parser.add_argument("--stage-input", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--inventory", type=Path, help="Export an optional disposable translation review inventory")
    args = parser.parse_args()
    if args.fingerprint:
        print(fingerprint())
        return
    catalogues, plurals = catalogue()
    if args.stage_input:
        # 规范化成等价 plist 输入；SwiftGen 官方解析器在 Linux 不接受 OpenStep。
        # 两平台都走相同输入，避免改变翻译维护源或模板结果。
        stage_input(catalogues, args.stage_input)
    expected = english_support(catalogues["en"])
    support = GENERATED / "EnglishFallbacks.swift"
    if args.write_support:
        support.parent.mkdir(parents=True, exist_ok=True)
        support.write_text(expected)
    errors = []
    generated_verified = False
    if not args.resources_only:
        if not support.exists() or support.read_text() != expected: errors.append("English fallback support is stale; regenerate")
        try:
            verify_generated(catalogues)
            generated_verified = True
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            errors.append(str(error))
        errors.extend(validate_calls(catalogues))
        for filename in ("generate_error_issues.py", "generate_model_issues.py", "audit_ui_localization.py"):
            generator = ROOT / "Scripts" / filename
            if not generator.exists():
                errors.append(f"Missing required localization check: {filename}")
                continue
            arguments = [] if filename == "audit_ui_localization.py" else ["--check"]
            checked = subprocess.run([sys.executable, str(generator), *arguments], capture_output=True, text=True)
            if checked.returncode: errors.append(checked.stderr.strip() or checked.stdout.strip() or f"{filename}: failed")
    report = {"languages": ["en", "zh-Hans"], "tables": len(catalogues["en"]),
              "keys": sum(len(values) for values in catalogues["en"].values()),
              "plural_keys": sum(len(values) for values in plurals["en"].values()),
              "generated_accessors_checked": generated_verified, "errors": errors}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if errors: raise ValueError("\n".join(errors))
    if args.inventory:
        args.inventory.parent.mkdir(parents=True, exist_ok=True)
        args.inventory.write_text(json.dumps(review_inventory(catalogues, plurals), ensure_ascii=False, indent=2) + "\n")
    suffix = "; real SwiftGen output matches" if not args.resources_only else "; resources only"
    print(f"PASS: {report['keys']} keys in {report['tables']} tables; en / zh-Hans resources are consistent{suffix}")

if __name__ == "__main__":
    try: main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        print(f"Localization check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
