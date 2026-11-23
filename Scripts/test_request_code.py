"""Parse generated request snippets without executing them or making network requests.

Requires a running ProxyMirror app and a complete captured request ID:
  python3 Scripts/test_request_code.py --binary build_app/ProxyMirror.app/Contents/MacOS/ProxyMirror --id UUID
Missing optional language toolchains are reported as SKIP.
"""

import argparse
import ast
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


FORMATS = (
    "curl", "httpie", "python", "fetch", "swift", "alamofire", "moya", "go",
    "nodeHTTP", "axios", "got", "nodeRequest", "jquery", "kotlin", "java", "dart",
    "php", "rust", "objectiveC", "har", "postman",
)


def checked(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise AssertionError(f"{command[0]} rejected generated code:\n{result.stderr}\n{result.stdout}")


def check_snippet(language, code, directory):
    if not code.strip():
        raise AssertionError(f"{language} returned an empty snippet")
    if language == "python":
        ast.parse(code)
        return True
    if language in {"har", "postman"}:
        document = json.loads(code)
        if language == "har":
            assert isinstance(document["log"]["entries"], list)
        else:
            assert document["info"]["schema"].endswith("collection/v2.1.0/collection.json")
            assert isinstance(document["item"], list)
        return True
    if language in {"curl", "httpie"}:
        filename = directory / f"{language}.sh"
        filename.write_text(code, encoding="utf-8")
        checked(["/bin/sh", "-n", str(filename)])
        return True
    if language in {"fetch", "nodeHTTP", "axios", "got", "nodeRequest", "jquery"}:
        if not (node := shutil.which("node")):
            return False
        filename = directory / f"{language}.{'mjs' if language == 'got' else 'cjs'}"
        filename.write_text(code, encoding="utf-8")
        checked([node, "--check", str(filename)])
        return True
    if language in {"swift", "alamofire", "moya"}:
        if not (swift := shutil.which("swiftc")):
            return False
        filename = directory / f"{language}.swift"
        filename.write_text(code, encoding="utf-8")
        checked([swift, "-parse", str(filename)])
        return True
    if language == "go":
        if not (gofmt := shutil.which("gofmt")):
            return False
        filename = directory / "request.go"
        filename.write_text(code, encoding="utf-8")
        checked([gofmt, "-e", str(filename)])
        return True
    if language == "java":
        if not (javac := shutil.which("javac")):
            return False
        filename = directory / "CapturedRequest.java"
        filename.write_text(code, encoding="utf-8")
        checked([javac, "-d", str(directory), str(filename)])
        return True
    if language == "php":
        if not (php := shutil.which("php")):
            return False
        filename = directory / "request.php"
        filename.write_text(code, encoding="utf-8")
        checked([php, "-l", str(filename)])
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--id", required=True, help="ID of a complete captured request")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pm-code-check-") as temporary:
        directory = Path(temporary)
        for language in FORMATS:
            result = subprocess.run(
                [str(args.binary.resolve()), "code", "--id", args.id, "--language", language],
                check=True, capture_output=True, text=True, timeout=15,
            )
            code = json.loads(result.stdout)["code"]
            parsed = check_snippet(language, code, directory)
            print(f"{'PASS' if parsed else 'SKIP'}  {language}" + ("" if parsed else " (no configured syntax checker)"))


if __name__ == "__main__":
    main()
