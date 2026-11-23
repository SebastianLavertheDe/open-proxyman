#!/bin/sh
# Native numeric-IP/CIDR checks use production models and typed diagnostics.
set -eu
network_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$network_root/Scripts/test_network_access.py" "$@"
