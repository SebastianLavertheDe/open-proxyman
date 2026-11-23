#!/bin/sh
# Native numeric-IP/CIDR checks. Uses the real production Swift model and has
# no SwiftUI, Network.framework, NIO, package resolution or network dependency.
set -eu
network_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
network_temp=$(mktemp -d "${TMPDIR:-/tmp}/pm-access.XXXXXX")
trap 'rm -rf "$network_temp"' EXIT HUP INT TERM
swiftc "$network_root/Sources/ProxyMirrorCore/System/NetworkAccessPolicy.swift" \
  "$network_root/Tests/ProxyMirrorCoreChecks/NetworkAccessChecks.swift" \
  "$network_root/Tests/Fixtures/NetworkAccess/main.swift" \
  -o "$network_temp/network-access-checks"
"$network_temp/network-access-checks"
