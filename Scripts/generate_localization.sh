#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$#" -gt 0 ]]; then
  if [[ "$#" == 1 && "$1" == --check ]]; then
    exec python3 Scripts/check_localization.py
  fi
  printf '%s\n' 'Usage: Scripts/generate_localization.sh [--check]' >&2
  exit 2
fi

readonly expected_version=6.6.3
generator="$(printenv SWIFTGEN_BIN || true)"
if [[ -z "$generator" ]]; then generator=swiftgen; fi
if ! command -v "$generator" >/dev/null 2>&1; then
  printf '%s\n' 'SwiftGen 6.6.3 is required. Install that version or set SWIFTGEN_BIN.' >&2
  exit 1
fi
version="$("$generator" --version)"
if [[ ! "$version" =~ ^SwiftGen[[:space:]]v?6\.6\.3([[:space:]]|\(|$) ]]; then
  printf 'Expected SwiftGen %s; found %s\n' "$expected_version" "$version" >&2
  exit 1
fi
python3 Scripts/check_localization.py --resources-only
fingerprint="$(python3 Scripts/check_localization.py --fingerprint)"
destination=Sources/ProxyMirrorCore/Localization/Generated
mkdir -p "$destination"
temporary="$(mktemp -d /tmp/proxymirror-localization.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT
python3 Scripts/check_localization.py --resources-only --stage-input "$temporary/en.lproj"
"$generator" run strings \
  --templatePath Scripts/Templates/localization-swift5.stencil \
  --param "resourceFingerprint=$fingerprint" \
  --output "$temporary/Strings.swift" \
  "$temporary/en.lproj"
mv "$temporary/Strings.swift" "$destination/Strings.swift"
python3 Scripts/check_localization.py --write-support --resources-only
python3 Scripts/generate_error_issues.py
python3 Scripts/generate_model_issues.py
python3 Scripts/check_localization.py
