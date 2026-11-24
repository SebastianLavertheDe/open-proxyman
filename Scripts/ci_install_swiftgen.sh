#!/usr/bin/env bash
# The release archive is pinned independently of Homebrew's moving version.
set -euo pipefail
tools_dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/proxymirror-swiftgen-6.6.3"
mkdir -p "$tools_dir"
archive="$tools_dir/swiftgen-6.6.3.zip"
curl --fail --location --retry 3 \
  https://github.com/SwiftGen/SwiftGen/releases/download/6.6.3/swiftgen-6.6.3.zip \
  --output "$archive"
printf '%s  %s\n' 94391c1b5a845150284be69fa9499fb2600231ac8f6a3ea5da53a4b55ee174df "$archive" | shasum -a 256 --check
unzip -q -o "$archive" -d "$tools_dir"
printf 'SWIFTGEN_BIN=%s/bin/swiftgen\n' "$tools_dir" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
