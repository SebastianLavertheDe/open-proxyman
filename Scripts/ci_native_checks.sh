#!/usr/bin/env bash
# Run from the repository root on a Mac with Xcode. Every lane fails closed.
set -euo pipefail
cd "$(dirname "$0")/.."
lane="${1:?Use debug, release or tsan}"
swift --version
python3 Scripts/check_localization.py
python3 Scripts/test_localization_resources.py
python3 Scripts/audit_ui_localization.py

case "$lane" in
  debug)
    swift build -j 2 --product ProxyMirrorSelfTest
    swift build -j 2 --product ProxyMirrorScriptWorker
    support_dir="$(mktemp -d)"
    trap 'rm -rf "$support_dir"' EXIT
    export PM_SUPPORT_DIR="$support_dir"
    swift test -j 2 --filter ProxyMirrorFoundationTests
    swift test -j 2 --filter ProxyMirrorCoreTests
    .build/debug/ProxyMirrorSelfTest --core-unit
    python3 Scripts/test_loopback.py --full
    python3 Scripts/test_loopback.py --concurrency
    python3 Scripts/test_http2.py
    python3 Scripts/test_http_transport.py
    python3 Scripts/test_compose_transport.py
    python3 Scripts/test_localization_runtime.py
    python3 Scripts/test_localized_errors.py
    PM_APP_PATH="$PWD/.build/ci-debug/ProxyMirror.app" Scripts/make_app.sh debug
    python3 Scripts/test_app_bundle.py --app .build/ci-debug/ProxyMirror.app
    python3 Scripts/test_cli.py --app .build/ci-debug/ProxyMirror.app
    python3 Scripts/test_preferences_ui.py --app .build/ci-debug/ProxyMirror.app --language both --appearance both
    ;;
  release)
    # A separate CI job ensures testability flags from test builds cannot leak
    # into the production application or helper binaries.
    PM_APP_PATH="$PWD/.build/ci-release/ProxyMirror.app" Scripts/make_app.sh release
    python3 Scripts/test_app_bundle.py --app .build/ci-release/ProxyMirror.app
    python3 Scripts/test_cli.py --app .build/ci-release/ProxyMirror.app
    ;;
  tsan)
    swift build --scratch-path .build/tsan --sanitize=thread -j 2 --product ProxyMirrorSelfTest
    swift build --scratch-path .build/tsan --sanitize=thread -j 2 --product ProxyMirrorScriptWorker
    tsan_bin="$(swift build --scratch-path .build/tsan --sanitize=thread --show-bin-path)"
    export PM_SELFTEST_BIN="$tsan_bin/ProxyMirrorSelfTest"
    export TSAN_OPTIONS=halt_on_error=1
    support_dir="$(mktemp -d)"
    trap 'rm -rf "$support_dir"' EXIT
    export PM_SUPPORT_DIR="$support_dir"
    "$PM_SELFTEST_BIN" --core-unit
    python3 Scripts/test_loopback.py --concurrency --timeout 180
    python3 Scripts/test_loopback.py --full --timeout 180
    python3 Scripts/test_http2.py --timeout 180
    python3 Scripts/test_http_transport.py
    ;;
  *) printf 'Unknown CI lane: %s\n' "$lane" >&2; exit 2 ;;
esac
