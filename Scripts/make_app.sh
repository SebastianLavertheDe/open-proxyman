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
	<string>zh-Hans</string>
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
swift build -j "${PM_BUILD_JOBS:-2}" -c "$CONFIG" "${build_flags[@]}" 2>&1 | tail -10
BIN_DIR=".build/$CONFIG"
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

# 图标（若存在）
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

if (( TRANSPARENT )); then
  host_id=$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")
  extension="$APP/Contents/Library/SystemExtensions/$host_id.transparent-proxy.systemextension"
  cp "$BIN_DIR/ProxyMirrorTransparentExtension" "$extension/Contents/MacOS/ProxyMirrorTransparentExtension"
  plutil -lint "$extension/Contents/Info.plist"
  codesign "${signature_args[@]}" --entitlements "$STAGING/extension.entitlements" "$extension"
  codesign --verify --strict "$extension"
  signature_args+=(--entitlements "$STAGING/app.entitlements")
fi

codesign "${signature_args[@]}" --options runtime "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$PREVIOUS"; fi
mv "$APP" "$DESTINATION"

echo "打包完成: $DESTINATION"
