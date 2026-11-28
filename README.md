# ProxyMirror

**English** | [简体中文](./README.zh-CN.md)

A native macOS HTTP/HTTPS traffic capture and debugging tool inspired by Proxyman.

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)

## Features

- HTTP/1.x and HTTP/2 capture, with HTTPS ALPN, HTTP/2 stream cancellation and trailers, per-domain SSL decryption, and WebSocket support (including RFC 8441 extended CONNECT).
- gRPC and gRPC-Web inspection in binary and Base64 text formats, with Protobuf messages, status, trailers, and FileDescriptorSet imports.
- Map Local, Map Remote, Block/Allow, No Caching, breakpoints, scripts, DNS mapping, and per-host simulation of latency, bandwidth limits, jitter, disconnections, and pauses between body chunks.
- Reverse proxy, HTTP CONNECT, HTTPS CONNECT, SOCKS5 and PAC routing, upstream CAs, mTLS client identities, and TLS key logging.
- Traffic tables, custom columns, combined filters, tabs, and split views. Details include query parameters, cookies, raw content, timing, JSONPath, jq, and binary inspection.
- Compose supports JSON, Form, Multipart, QUERY, WebSocket, timeouts, and redirects. Copy as Code offers 21 formats; standard replays use the local proxy.
- A separate Diff comparison pool for requests, responses, headers, and bodies, with JSON sorting and external diff tools; advanced filtering across 19 fields, nested AND/OR groups, coloring presets, and detail history navigation.
- Saved traffic, versioned sessions, HAR / CSV, redacted Gist publishing, Charles session and rule imports, and rule/settings backups including Protobuf descriptors.
- Built-in HTTP / stdio MCP, a full CLI, nested rule folders, and tool switches. The Automation Dashboard launches terminals, browsers, and Electron with proxy settings.
- CommonJS Addons, Lodash / Moment, environment variables, sharedState, Mock API, and console log levels. Scripts run in separate processes with time limits.
- HTTP and SOCKS5 share a listening port, with zstd decoding, 12 network simulation presets supporting multiple rules, and global Protobuf schema mapping.
- LAN access through multi-IP / CIDR allowlists, with loopback-only listening by default. macOS system proxy bypass lists are preserved and restored.
- External Proxy supports all hosts, exclusion lists, and Inclusive lists; upstream routing can match hosts or HTTP(S) URL wildcards.
- Saved requests support nested folders, moving, and copying, with automatic migration of the old Saved tray. Traffic summaries include status buckets, duration histograms, and P50 / P95 / P99.
- Settings use a categorized sidebar with search and back/forward navigation. Requests and responses can be stacked or placed side by side. Configure font size, monospaced fonts, tabs, character minimaps, scrolling beyond the last line, dates with time zones, themes, and four desktop icons.
- MCP can be started and stopped at runtime, with HTTP and stdio configuration for Claude Code, Codex, and manual setup. AI responses are redacted by default. Copying can preserve original content headers, and rule processing can add diagnostic headers.
- Independent recording controls, quit confirmation, Chinese and English interfaces, update notifications, and cleanup of older completed requests by memory threshold and interval. The Help menu includes troubleshooting and simulated memory warnings.
- Scripts support `fetch`, `@proxymirror/http`, and an HTTP subset of Axios, including awaiting HTTP(S) calls, cancellation, and timeouts. The script window can copy a task for generating scripts through MCP.

Common shortcuts: ⌘F filters current traffic, ⇧⌘F finds sources, ⌥⌘N composes a request, ⌘K edits a request, ⇧⌘R edits and replays, and ⇧⌘C copies cURL.

In the advanced filter panel, ⌘N adds a condition, ⇧⌘N adds a subgroup, ⌘↑ / ⌘↓ navigates, and ⌘B toggles preset coloring. In the list, ⌘C uses the selected default copy format.

## Interface language

Simplified Chinese and English are supported. Choose System, Simplified Chinese, or English in Settings; changes take effect on the next launch. Menus, tools, help, and application error messages use native localization resources. User names, network bodies, and scripts retain their original content.

On its first normal launch, this version performs a one-time reset of local data from earlier versions, including application settings, rules, and Saved items, and switches to stable English storage IDs. Older proprietary sessions and rule backups cannot be read. CAs, Keychain items, and system proxy recovery records are outside this general reset.

See the [localization implementation notes](Docs/localization-implementation.md) for development and validation details.

## Build and run

```zsh
swift build --skip-update -j 2
.build/debug/ProxyMirrorSelfTest
python3 Scripts/test_loopback.py --full
python3 Scripts/test_http2.py  # Go 1.19+ builds the local fixture server; set PM_FIXTURE_GO to choose Go

Scripts/make_app.sh debug
open build_app/ProxyMirror.app
```

Start listening or recording from the toolbar. The default manual proxy address is `127.0.0.1:9090`. To decrypt HTTPS, install and trust the local CA from the Certificates menu.

The traffic list preserves the current selection and scroll position by default. To follow new requests, click Auto Select below the list.

When listening starts, ProxyMirror automatically takes over the macOS system proxy by default. The first takeover requests permission to install a background service through the macOS authorization dialog. Subsequent launches of the same signed build reuse that authorization; a newly signed build requires approval again. Disable automatic takeover in Settings → General, or use the top status popover to change recording, the macOS proxy, and the network extension for the current session.

Each takeover saves the current HTTP / HTTPS proxy settings. They are restored when the app quits, listening stops, or Restore System Proxy is clicked. If the app exits unexpectedly, the background service also attempts restoration when the connection closes. Restoration preserves proxy entries changed by other apps during takeover. After restoring the system proxy, use Remove System Proxy Authorization in Settings → General to uninstall the background service.

### Transparent capture on macOS

A signed build with the network extension can capture traffic from Mac apps without an HTTP proxy configured, through Tools → Start Transparent Capture or Preferences → Network Extension. Approve the extension when macOS prompts on first use. Coverage currently includes IPv4 / IPv6 TCP ports 80 (HTTP) and 443 (HTTPS). HTTPS uses the existing CA and per-domain/per-app SSL rules. UDP / QUIC / HTTP/3, other ports, and loopback connections remain direct. Starting transparent capture first restores the system proxy; stop transparent capture before switching back to the system proxy.

The default ad hoc build does not include the extension. Build with a matching Developer ID Application signing identity and Network Extension provisioning profiles for both the main app, `com.sebastianLavertheDe.proxymirror`, and the system extension, `com.sebastianLavertheDe.proxymirror.transparent-proxy`:

```zsh
PM_DEVELOPER_ID='<Developer ID Application SHA-1 or full name>' \
PM_APP_PROVISION_PROFILE='/path/to/app.provisionprofile' \
PM_EXTENSION_PROVISION_PROFILE='/path/to/extension.provisionprofile' \
PM_APP_PATH='build_app/transparent/ProxyMirror.app' \
  Scripts/make_app.sh release --transparent
python3 Scripts/test_app_bundle.py --app build_app/transparent/ProxyMirror.app --expect-transparent
```

Before distribution or extension activation on a test Mac with default security settings, submit the signed app for Apple notarization. If `notarytool` credentials are already configured in the local Keychain:

```zsh
ditto -c -k --keepParent build_app/transparent/ProxyMirror.app build_app/transparent/ProxyMirror-notary.zip
xcrun notarytool submit build_app/transparent/ProxyMirror-notary.zip --keychain-profile '<Keychain notarization profile name>' --wait
# Run the following two commands after the notarization result is Accepted.
xcrun stapler staple build_app/transparent/ProxyMirror.app
xcrun stapler validate build_app/transparent/ProxyMirror.app
```

Move the notarized app into Applications on the test Mac before launching it. Use your own test app and non-loopback HTTP / HTTPS services, confirm that no explicit proxy is configured, and verify capture, direct connections after stopping, and direct connections after quitting. After a force quit, the extension routes new connections to their original destinations once the host handshake fails; existing intercepted connections require the client to reconnect. ProxyMirror cleans up residual configuration on its next launch. Actual activation, network switching, sleep, and coexistence with VPNs still require acceptance testing in a signed environment. [Apple system extension requirements](https://developer.apple.com/documentation/systemextensions) · [Apple notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)

### Per-app SSL configuration

Open Tools → Configure SSL by Application, select a local `.app` or enter a Bundle ID, and choose decryption or passthrough. You can also open the editor from the context menu of HTTPS traffic with an identified source. Saved rules apply to new CONNECT connections; clients reusing existing connections must reconnect.

The global SSL switch and excluded hosts take priority. Enabled app rules apply next. Unmatched apps, processes without attribution, and LAN devices follow the existing domain rules. App attribution uses the process and Bundle ID of local loopback TCP connections; network helper processes inside an app bundle are attributed to that app. Passthrough records only CONNECT, and the client validates the server certificate directly.

### HTTP/2 and gRPC

The SSL settings page controls HTTP/2 negotiation for new HTTPS connections. HTTP/2 clients can use h2c when forwarding to configured HTTP targets. Connection logs in traffic details show the upstream protocol, ALPN, and stream ID.

Select gRPC traffic and inspect messages in the request or response gRPC tab. Generate a descriptor with `protoc --descriptor_set_out=echo.pb --include_imports echo.proto`, then import `echo.pb` in that tab.

### Connecting devices and runtimes

- When a physical device and the Mac share a test network, enable the LAN proxy in General settings, select the Mac's IPv4 address, enter the device's IPv4 address, and apply. Set the device's Wi-Fi proxy to the Mac's IP and listening port. On iOS, after installing the exported CA, enable full trust under Settings → General → About → Certificate Trust Settings. Restore the device's original proxy settings after testing. [Apple certificate trust guide](https://support.apple.com/en-us/102390)
- For the iOS Simulator, start with the Mac's system proxy and install the test CA in the simulator. When Android Emulator app traffic uses the Android System Proxy, `10.0.2.2` reaches the Mac's loopback listener. For your own Android debug builds, trust the test CA in the app's debug network security configuration. [Android Emulator proxy](https://developer.android.com/studio/run/emulator-networking-proxy) · [Android Emulator addresses](https://developer.android.com/studio/run/emulator-networking-address)
- From a terminal, verify with `curl --proxy http://127.0.0.1:9090 --cacert ./proxymirror-ca.pem <test-URL>`. Node.js versions supporting environment proxies can use `NODE_USE_ENV_PROXY=1`, `HTTP_PROXY`, `HTTPS_PROXY`, and `NODE_EXTRA_CA_CERTS` for a single process. [Node.js proxy and CA options](https://nodejs.org/api/cli.html#node_use_env_proxy1)

- Certificates → Install Certificate on iOS → One-click iOS Simulator Setup installs the CA into booted simulators through simctl, then takes over the system proxy through the existing macOS authorization flow. The adb entry in the same menu copies an Android user certificate to the device; confirm installation in the device's Settings.
- Writable test images running Android 13 or earlier can use `Scripts/install_certificate_android_emulator.sh <ca.pem> [serial]`. Test images configured with Magisk and reading CAs from system directories can use `Scripts/make_android_ca_magisk_module.sh <ca.pem> <module.zip>` to generate an offline module. [Android writable system images](https://developer.android.com/studio/run/emulator-commandline) · [Magisk module format](https://topjohnwu.github.io/Magisk/guides.html)
- Your own iOS debug apps can use [ProxyMirrorBridgeKit](./ProxyMirrorBridgeKit/README.md) to send records directly to the Mac after pairing.

### Migrating from Charles

Use File → Import Charles Session to select an XML or JSON session exported by Charles. Native `.chls` / `.chlz` files can be converted to HAR with the locally installed Charles `convert` command. If Charles is not installed, export XML / JSON / HAR first. Tools → Import Rules from Charles previews compatible rules and skipped items before applying them. [Charles conversion command](https://www.charlesproxy.com/documentation/tools/command-line-tools/)

### Source folders and settings search

Click the plus button beside Source Folders in the sidebar and choose captured apps or domains. Right-click an app, domain, or folder to change its assignment or name. Folders match any selected source and combine with other filters in the current view. Each tab and split view has its own source selection; folder names and members persist across launches.

Search Settings for terms such as `HTTP/2`, `TLS MITM`, or body truncation, then select a result to navigate to and highlight the corresponding control. Press Return to open the first result.

## Local command line

After launching ProxyMirror, invoke the binary inside the app bundle from a terminal. Status and query results are JSON; errors go to standard error.

```zsh
pm=./build_app/ProxyMirror.app/Contents/MacOS/ProxyMirror
"$pm" status
"$pm" traffic --method GET --status 404 --limit 20
"$pm" traffic --url /api/ --limit 50
"$pm" export-har --selected --output ./selected.har
"$pm" export-har --id 8233BD29-7982-4534-9FF3-B70EE20F5AFB --output -
```

`status` reports proxy listening, recording, and system proxy status separately. `traffic` and `export-har` query live captures by default. `--selected` queries records selected in the current view and can be combined with other filters. Queries return the most recent matching records in capture order: 100 by default, up to 1000.

HAR includes captured request headers, response headers, and bodies. The body limit per export is 24 MiB; narrow the filters if needed. When a file path is specified, the app writes it with read/write permissions for the current user. `--output -` writes HAR to standard output.

`export logs` exports the entire retained native session without the traffic query's default 100-record limit. `domains` groups records by domain, and exported log bundles can be reopened as sessions. Split exports by domain and ISO 8601 timestamps with time zones. `export flows` continues to support incremental queries and pagination.

```zsh
"$pm" export logs all --output ./traffic.proxymirror
"$pm" export logs domains --domains '*.example.com' --output ./domains.proxymirror
"$pm" rules dns rename --id "$rule_id" --name 'Test DNS'
"$pm" rules dns duplicate --id "$rule_id" --name 'Test DNS Copy'
```

### Migrating rules and settings

```zsh
"$pm" rules export --output ./backup.json
"$pm" rules export --tool dns --output ./dns.json
"$pm" rules export --tool sslApplications --output ./ssl-apps.json
"$pm" rules preview --input ./backup.json --mode merge
# Review the preview, then assign the returned previewToken to preview_token.
"$pm" rules apply --input ./backup.json --mode merge --preview-token "$preview_token"
```

The rule preview reports additions, replacements, removals, unchanged entries, and order changes. The default `merge` mode merges by rule ID; per-app SSL rules merge by Bundle ID. `replace` replaces only the tools included in the backup. Preview again if the input file, import mode, or current configuration changes. ProxyMirror JSON backups and legacy `rules.json` files are supported. Backups include basic rules, DNS, breakpoint rules, latency simulation, and common app settings. Map Local preserves file paths; prepare the file contents on the destination Mac. App settings take effect on the next launch or can be applied manually in Settings.

| Exit code | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Invalid command or filter arguments |
| 3 | Cannot connect to the local app |
| 4 | Communication, export, or rule application failed |
| 5 | No records selected in the current view, or no matching records for export |
| 6 | Rule preview has expired |

## Architecture

### MCP, rule tools, and development workbench

Install the CLI from Help → Install proxymirror-cli to PATH, then reopen the terminal:

```zsh
proxymirror-cli proxy-address
proxymirror-cli flow --id <UUID>
proxymirror-cli export flows --format json --after-id <UUID> --limit 100 --output -
proxymirror-cli rules mapLocal list
proxymirror-cli tools disable --tool rewrite
proxymirror-cli code --id <UUID> --language swift
proxymirror-cli mcp config
```

The app starts MCP on a random loopback port at launch. `mcp config` prints the current endpoint and token; the token file has permissions of 0600 and is removed when the app quits. Copy the HTTP configuration from Help → View MCP Connection Configuration, or configure an AI client to launch `proxymirror-cli mcp stdio`. With `--after-id`, each page returns the earliest records after the cursor. Continue with the last ID on that page to avoid missing new traffic that exceeds a page's size.

The Tools menu provides separate windows for Diff, Protobuf, rule folders, custom previewers, summaries, and Automation. In the script window, ⌘B formats and ⌘S saves and enables the script. Custom previewers receive `preview(input)` and return text or JSON from a separate worker. Results are displayed as plain text.

Rules, folders, tool switches, and Protobuf descriptors are stored together in `rules.json`; a single backup is limited to 16 MiB. The Certificates menu offers a PEM / DER / P12 import wizard and encrypted private key export. Gist publishing requires a GitHub token with Gists write permission, which can be saved in Keychain. Review the redacted HAR preview before publishing.

See the [gap implementation and acceptance notes](Docs/gap-implementation.md) for scope, validation commands, and capabilities that still require external setup.

```
Sources/
  ProxyMirrorCore/        # Core library
    Proxy/                # NIO proxy engine, HTTP parsing, MITM certificates, SNI sniffing
    Model/                # Transaction / TrafficStore / AppSettings
    UI/                   # Sidebar, list, details, and settings (SwiftUI)
    Export/               # HAR + cURL + Repeat
    System/               # SystemConfiguration proxy settings, certificates, and trust
  ProxyMirror/            # @main app shell (menu commands and separate windows)
  ProxyMirrorSelfTest/    # CLT unit test entry point, loopback, concurrency, and benchmarks
Tests/                    # Core assertions, XCTest, and performance tests
Scripts/                  # Test fixtures, packaging, and builds
```

## Local build notes

Only macOS Command Line Tools are required. The project runs regressions through the SelfTest executable. If the local environment terminates parallel compilation, use `swift build -j 1`. If an explicit UTF-8 decoding error occurs after fetching dependencies for the first time, inspect the files in the dependency checkout.

## Testing

### Preferences UI acceptance

The settings window follows the reference layout with General, Appearance, Privacy, MCP, GitHub, Tools, Network Extension, Advanced, Workspace, and Products pages. The previous SSL, LAN, mTLS, bypass, and external proxy settings are under Advanced Proxy Settings… and can also be located through search.

After building on a Mac, export screenshots of real native windows. Screenshot mode uses a temporary data directory and skips proxy, MCP, and update service startup. It does not change user preferences or require Screen Recording permission:

```zsh
Scripts/make_app.sh debug
python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --appearance both
python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --pages general appearance tools --language en
```

PNGs, window dimensions, and each page's `.layout.json` are saved to `build_app/preferences-review/` by default. Capture measures the actual header and requires it to be fully inside the window's unobscured `contentLayoutRect` and its parent view's visible area. Title bar overlap, parent clipping, or compressed header height causes acceptance to fail. PNGs include the system title bar; pixels and interactions still need comparison with the reference images. Network extension activation requires the signed build described above.

To retest settings title bar clipping, run `python3 Scripts/test_preferences_ui.py --app build_app/ProxyMirror.app --pages mcp workspace --language both --appearance dark`. Negative cases for the current geometry checks can run across platforms with `python3 Scripts/test_preferences_layout.py`; they do not replace real macOS UI checks. [Apple content layout rectangle documentation](https://developer.apple.com/documentation/appkit/nswindow/contentlayoutrect)

### Core and proxy regressions

Core unit tests are shared by XCTest and the CLT self-test entry point. HTTP loopback, CLI, and concurrency suites use local fixtures and isolated data directories. Bundle checks verify signing, architecture, the script worker, and the CLI entry point.

```zsh
swift build --skip-update -j 2
.build/debug/ProxyMirrorSelfTest --core-unit
python3 Scripts/test_loopback.py --full
python3 Scripts/test_loopback.py --concurrency
python3 Scripts/test_http2.py

PM_APP_PATH="$PWD/.build/test-app/ProxyMirror.app" Scripts/make_app.sh debug
python3 Scripts/test_app_bundle.py --app .build/test-app/ProxyMirror.app
python3 Scripts/test_cli.py --app .build/test-app/ProxyMirror.app
```

For HTTP/2, set `PM_FIXTURE_GO` to choose Go, or pass an executable built from the same fixture source through `PM_HTTP2_FIXTURE_BIN`. With full Xcode installed, run `swift test --filter ProxyMirrorCoreTests --enable-code-coverage` for XCTest and coverage.

### Thread Sanitizer

```zsh
tsan_scratch="${PM_TSAN_SCRATCH:-.build/tsan}"
swift build --scratch-path "$tsan_scratch" --sanitize=thread --skip-update -j 2
tsan_bin="$(swift build --scratch-path "$tsan_scratch" --sanitize=thread --show-bin-path)"
TSAN_OPTIONS=halt_on_error=1 PM_SELFTEST_BIN="$tsan_bin/ProxyMirrorSelfTest" \
  python3 Scripts/test_loopback.py --concurrency --timeout 180
TSAN_OPTIONS=halt_on_error=1 PM_SELFTEST_BIN="$tsan_bin/ProxyMirrorSelfTest" \
  python3 Scripts/test_loopback.py --timeout 180
```

If a TSan process launched through Python exits during initialization, run the concurrency suite with its built-in local origin server directly from the shell.

```zsh
tsan_support="$(mktemp -d -t proxymirror-tsan)"
TSAN_OPTIONS=halt_on_error=1 PM_SUPPORT_DIR="$tsan_support" "$tsan_bin/ProxyMirrorSelfTest" --concurrency
```

### Performance regressions

Release self-tests measure actual traffic filtering, sorting, and body appends. Loopback load tests measure direct connections and the HTTP/1.1 proxy path with recording paused and enabled, checking every response and capture count. Rerun on the same machine with the same load parameters and use `--baseline` to compare against a previous loopback report. Full Xcode can run `swift test -c release --filter ProxyMirrorPerformanceTests` to record timing and memory baselines in XCTest.

```zsh
swift build -c release --product ProxyMirrorSelfTest -Xswiftc -enable-testing --skip-update -j 2
mkdir -p .build/performance
.build/release/ProxyMirrorSelfTest --benchmark-core > .build/performance/core.json
python3 Scripts/bench_proxy.py --output .build/performance/small-requests.json
```

See the [test implementation plan](./outputs/ProxyMirror%20测试实施方案.md) for UI and macOS system acceptance environments.

## Alignment scope

See the [implementation checklist](./outputs/ProxyMirror%20对齐%20Proxyman%20实施清单.md) for the comparison baseline, and [development delivery and acceptance](./outputs/ProxyMirror%20对齐开发交付与验收.md) for current implementation, validation results, and remaining work.

## Debugging tips

- Set `PM_SNAPSHOT=/tmp/x.pdf PM_SNAPSHOT_DELAY=15 PM_SNAPSHOT_SELECT=1` to render the main window offscreen after a delay, without Screen Recording permission, for headless UI validation.
- Engine logs (proxy start/stop, upstream connections, and root certificate counts) are written to stdout.
