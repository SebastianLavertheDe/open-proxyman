#!/bin/bash
# Embed an SPM-resolved Sparkle framework into a staged app, before the app's final signature.
set -euo pipefail
if [[ $# -ne 3 ]]; then
  echo 'Usage: Scripts/embed_sparkle.sh staged.app Sparkle.framework signing-identity' >&2
  exit 2
fi
PM_STAGED_APP="$1"
PM_SPARKLE_SOURCE="$2"
PM_SPARKLE_IDENTITY="$3"
if [[ ! -d "$PM_STAGED_APP/Contents/MacOS" || ! -d "$PM_SPARKLE_SOURCE/Versions/B" || "${PM_SPARKLE_SOURCE##*/}" != Sparkle.framework ]]; then
  echo 'Expected a staged app and the resolved Sparkle.framework.' >&2
  exit 2
fi
if [[ -z "$PM_SPARKLE_IDENTITY" || "$PM_SPARKLE_IDENTITY" == - ]]; then
  echo 'Sparkle packaging requires PM_DEVELOPER_ID. Ordinary ad-hoc builds use manual Releases updates.' >&2
  exit 2
fi
PM_SPARKLE_DESTINATION="$PM_STAGED_APP/Contents/Frameworks/Sparkle.framework"
if [[ -e "$PM_SPARKLE_DESTINATION" ]]; then
  echo 'Sparkle.framework already exists in the staged app.' >&2
  exit 2
fi
mkdir -p "$PM_STAGED_APP/Contents/Frameworks"
# ditto preserves the framework's versioned directory symlinks and executable permissions.
ditto "$PM_SPARKLE_SOURCE" "$PM_SPARKLE_DESTINATION"
for PM_SPARKLE_COMPONENT in \
  "$PM_SPARKLE_DESTINATION/Versions/B/XPCServices/Downloader.xpc" \
  "$PM_SPARKLE_DESTINATION/Versions/B/XPCServices/Installer.xpc" \
  "$PM_SPARKLE_DESTINATION/Versions/B/Updater.app" \
  "$PM_SPARKLE_DESTINATION/Versions/B/Autoupdate"; do
  if [[ -e "$PM_SPARKLE_COMPONENT" ]]; then
    codesign --force --sign "$PM_SPARKLE_IDENTITY" --options runtime --timestamp \
      --preserve-metadata=entitlements "$PM_SPARKLE_COMPONENT"
  fi
done
codesign --force --sign "$PM_SPARKLE_IDENTITY" --options runtime --timestamp "$PM_SPARKLE_DESTINATION"
codesign --verify --deep --strict "$PM_SPARKLE_DESTINATION"
PM_SPARKLE_EXECUTABLE="$PM_STAGED_APP/Contents/MacOS/ProxyMirror"
if ! otool -l "$PM_SPARKLE_EXECUTABLE" | /usr/bin/grep -Fq 'path @executable_path/../Frameworks '; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$PM_SPARKLE_EXECUTABLE"
fi
mkdir -p "$PM_STAGED_APP/Contents/Resources/ThirdParty"
cp "$(dirname "$0")/../ThirdParty/Sparkle-LICENSE" "$PM_STAGED_APP/Contents/Resources/ThirdParty/Sparkle-LICENSE"
echo 'Embedded and signed Sparkle.framework. Sign the host app after this step.'
