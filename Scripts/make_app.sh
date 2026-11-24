#!/bin/zsh
# 默认打包 ad-hoc .app。使用 --transparent 时嵌入 Developer ID 签名的系统扩展。
set -e -o pipefail
cd "$(dirname "$0")/.."

function usage {
  echo "用法：Scripts/make_app.sh [debug|release] [--transparent]"
  echo "透明代理需要 PM_DEVELOPER_ID、PM_APP_PROVISION_PROFILE 和 PM_EXTENSION_PROVISION_PROFILE。"
}

CONFIG=release
TRANSPARENT=0
case "${1:-}" in
  debug|release) CONFIG="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
esac
if [[ "${1:-}" == --transparent ]]; then
  TRANSPARENT=1
  shift
fi
if (( $# > 0 )); then
  usage >&2
  exit 2
fi

if (( TRANSPARENT )); then
  if [[ -z "${PM_DEVELOPER_ID:-}" || -z "${PM_APP_PROVISION_PROFILE:-}" || -z "${PM_EXTENSION_PROVISION_PROFILE:-}" ]]; then
    usage >&2
    exit 2
  fi
fi

if [[ "${PM_ENABLE_SPARKLE:-0}" == 1 && ( -z "${PM_DEVELOPER_ID:-}" || "${PM_DEVELOPER_ID:-}" == - ) ]]; then
  echo 'PM_ENABLE_SPARKLE=1 需要 PM_DEVELOPER_ID；普通 ad-hoc 构建保留手动更新。' >&2
  exit 2
fi
if [[ "${PM_ENABLE_SPARKLE:-0}" != 1 && ( -n "${PM_APPCAST_URL:-}" || -n "${PM_UPDATE_PUBLIC_KEY:-}" ) ]]; then
  echo '配置签名更新源时需要同时设置 PM_ENABLE_SPARKLE=1。' >&2
  exit 2
fi

DESTINATION="${PM_APP_PATH:-build_app/ProxyMirror.app}"
PARENT="$(dirname "$DESTINATION")"
mkdir -p "$PARENT"
STAGING="$(mktemp -d "$PARENT/.ProxyMirror-build.XXXXXX")"
APP="$STAGING/ProxyMirror.app"
PREVIOUS="$STAGING/Previous.app"
function clean_up {
  if [[ -e "$PREVIOUS" && ! -e "$DESTINATION" ]]; then
    mv "$PREVIOUS" "$DESTINATION" || return
  fi
  rm -rf -- "$STAGING"
}
trap clean_up EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array><string>zh-Hans</string><string>en</string></array>
	<key>CFBundleDisplayName</key>
	<string>ProxyMirror</string>
	<key>CFBundleExecutable</key>
	<string>ProxyMirror</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.sebastianLavertheDe.proxymirror</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>ProxyMirror</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1.1</string>
	<key>CFBundleVersion</key>
	<string>4</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>ProxyMirror opens Terminal or iTerm windows configured with the proxy.</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>com.sebastianLavertheDe.proxymirror.session</string>
			<key>UTTypeDescription</key>
			<string>ProxyMirror Session</string>
			<key>UTTypeConformsTo</key>
			<array><string>public.json</string></array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array><string>proxymirror</string></array>
			</dict>
		</dict>
	</array>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>ProxyMirror Session</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.sebastianLavertheDe.proxymirror.session</string>
			</array>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>ProxyMirror HAR</string>
			<key>CFBundleTypeExtensions</key>
			<array>
				<string>har</string>
			</array>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Default</string>
		</dict>
	</array>
</dict>
</plist>
PLIST

signature_args=(--force --sign -)
if [[ "${PM_ENABLE_SPARKLE:-0}" == 1 ]]; then
  signature_args=(--force --sign "$PM_DEVELOPER_ID" --options runtime --timestamp)
fi
if (( TRANSPARENT )); then
  fingerprint=$(python3 Scripts/prepare_transparent_signing.py \
    "$APP" "$PM_DEVELOPER_ID" "$PM_APP_PROVISION_PROFILE" "$PM_EXTENSION_PROVISION_PROFILE")
  signature_args=(--force --sign "$fingerprint" --options runtime --timestamp)
fi

build_flags=()
# The app imports the core module's internal UI and controller APIs via @testable.
if [[ "$CONFIG" == release ]]; then
  build_flags=(-Xswiftc -enable-testing)
fi
python3 Scripts/check_localization.py
swift build -j "${PM_BUILD_JOBS:-2}" -c "$CONFIG" "${build_flags[@]}" 2>&1 | tail -10
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
LOCALIZATION_BUNDLE="ProxyMirror_ProxyMirrorCore.bundle"
if [[ ! -d "$BIN_DIR/$LOCALIZATION_BUNDLE" ]]; then
  echo "Missing SwiftPM localization bundle: $BIN_DIR/$LOCALIZATION_BUNDLE" >&2
  exit 1
fi
cp -R "$BIN_DIR/$LOCALIZATION_BUNDLE" "$APP/Contents/Resources/$LOCALIZATION_BUNDLE"
cp "$BIN_DIR/ProxyMirror" "$APP/Contents/MacOS/ProxyMirror"
for helper in ProxyMirrorScriptWorker ProxyMirrorSystemProxyHelper; do
  cp "$BIN_DIR/$helper" "$APP/Contents/MacOS/$helper"
  if [[ "$helper" == ProxyMirrorSystemProxyHelper ]]; then
    codesign "${signature_args[@]}" --options runtime --identifier com.sebastianLavertheDe.proxymirror.system-proxy "$APP/Contents/MacOS/$helper"
  else
    codesign "${signature_args[@]}" "$APP/Contents/MacOS/$helper"
  fi
done

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ship licenses for the embedded scripting libraries and Zstandard decoder.
mkdir -p "$APP/Contents/Resources/ThirdParty"
for language in en zh-Hans; do
  localization="Resources/$language.lproj"
  [[ -f "$localization/InfoPlist.strings" ]]
  mkdir -p "$APP/Contents/Resources/$language.lproj"
  cp "$localization/InfoPlist.strings" "$APP/Contents/Resources/$language.lproj/InfoPlist.strings"
done
python3 Scripts/prepare_app_resources.py \
  "$APP/Contents/Resources/$LOCALIZATION_BUNDLE" "$APP/Contents/Resources/ThirdParty"

if [[ "${PM_ENABLE_SPARKLE:-0}" == 1 ]]; then
  sparkle_framework=$(python3 - <<'PY'
from pathlib import Path
frameworks = [path for path in Path('.build/artifacts').rglob('Sparkle.framework')
              if path.parent.name.startswith('macos-') and (path / 'Versions/B').is_dir()]
if len(frameworks) != 1:
    raise SystemExit('找不到唯一的 macOS Sparkle.framework，请先检查 SwiftPM artifact。')
print(frameworks[0].resolve())
PY
  )
  bash Scripts/embed_sparkle.sh "$APP" "$sparkle_framework" "$PM_DEVELOPER_ID"
  python3 Scripts/configure_updates.py "$APP"
fi

# 启动和运行时统一使用原有宇航员图标；缺失图标时让打包失败。
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if (( TRANSPARENT )); then
  host_id=$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")
  extension="$APP/Contents/Library/SystemExtensions/$host_id.transparent-proxy.systemextension"
  cp "$BIN_DIR/ProxyMirrorTransparentExtension" "$extension/Contents/MacOS/ProxyMirrorTransparentExtension"
  for language in en zh-Hans; do
    mkdir -p "$extension/Contents/Resources/$language.lproj"
    cp "Resources/TransparentExtension/$language.lproj/InfoPlist.strings" "$extension/Contents/Resources/$language.lproj/InfoPlist.strings"
  done
  plutil -lint "$extension/Contents/Info.plist"
  codesign "${signature_args[@]}" --entitlements "$STAGING/extension.entitlements" "$extension"
  codesign --verify --strict "$extension"
fi

# Terminal/iTerm launch uses Apple Events; preserve Network Extension entitlements.
python3 - "$STAGING/app.entitlements" <<'PY'
from pathlib import Path
import plistlib
import sys
path = Path(sys.argv[1])
entitlements = plistlib.loads(path.read_bytes()) if path.exists() else {}
entitlements['com.apple.security.automation.apple-events'] = True
path.write_bytes(plistlib.dumps(entitlements))
PY
signature_args+=(--entitlements "$STAGING/app.entitlements")

codesign "${signature_args[@]}" --options runtime "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
bundle_check_flags=()
if (( TRANSPARENT )); then bundle_check_flags=(--expect-transparent); fi
python3 Scripts/test_app_bundle.py --app "$APP" "${bundle_check_flags[@]}"
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$PREVIOUS"; fi
mv "$APP" "$DESTINATION"

echo "打包完成: $DESTINATION"
