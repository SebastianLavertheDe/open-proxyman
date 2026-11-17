#!/bin/sh
# Build an offline Magisk module for a test device that reads system/etc/security/cacerts.
set -eu

if [ "$#" -ne 2 ] || [ ! -f "$1" ]; then
    echo "Usage: $0 <ca.pem> <module.zip>" >&2
    exit 64
fi
certificate="$1"
destination="$2"
if [ -e "$destination" ]; then
    echo "Output already exists: $destination" >&2
    exit 73
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/module/system/etc/security/cacerts"
hash=$(/usr/bin/openssl x509 -subject_hash_old -noout -in "$certificate")
case "$hash" in
    ????????) ;;
    *) echo "Invalid certificate subject hash." >&2; exit 65 ;;
esac
case "$hash" in
    *[!0-9a-f]*) echo "Invalid certificate subject hash." >&2; exit 65 ;;
esac
/usr/bin/openssl x509 -in "$certificate" -out "$work/module/system/etc/security/cacerts/$hash.0"
chmod 644 "$work/module/system/etc/security/cacerts/$hash.0"
cat > "$work/module/module.prop" <<'EOF'
id=proxymirror_ca
name=ProxyMirror Debug CA
version=1.0
versionCode=1
author=ProxyMirror
description=Adds the exported ProxyMirror CA to the system trust store on a compatible test device.
EOF
(cd "$work/module" && /usr/bin/zip -q -r "$work/module.zip" module.prop system)
cp -n "$work/module.zip" "$destination"
echo "Created $destination"
