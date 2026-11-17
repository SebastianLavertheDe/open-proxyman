#!/bin/sh
# install_certificate_android_emulator.sh — ProxyMirror Android 模拟器证书自动化（原创实现）
# 用法: install_certificate_android_emulator.sh <ca.pem> [serial]
# 说明: 对 Google APIs 镜像走 adb root + remount 路线安装系统级 CA；
#       Google Play 镜像不支持，请改用 Magisk 模块或用户证书安装指南。
set -e

CERT="${1:?usage: $0 <ca.pem> [serial]}"
SERIAL="${2:-}"

if [ ! -f "$CERT" ]; then
    echo "找不到证书文件: $CERT" >&2
    exit 64
fi
ADB="${PM_ADB:-adb}"
if [ -z "$SERIAL" ]; then
    SERIAL=$("$ADB" devices | awk '$1 ~ /^emulator-/ && $2 == "device" { print $1 }')
fi
case "$SERIAL" in
    emulator-*) ;;
    *) echo "请选择一个已连接的 Android 模拟器序列号。" >&2; exit 69 ;;
esac
case "${SERIAL#emulator-}" in
    *[!0-9]*|'') echo "模拟器序列号无效: $SERIAL" >&2; exit 69 ;;
esac
run_adb() { "$ADB" -s "$SERIAL" "$@"; }

SDK=$(run_adb shell getprop ro.build.version.sdk | tr -d '[:space:]')
case "$SDK" in
    *[!0-9]*|'') echo "无法识别模拟器的 Android API。" >&2; exit 69 ;;
esac
if [ "$SDK" -ge 34 ] || run_adb shell getprop ro.build.fingerprint | grep -qi 'playstore'; then
    echo "需要 Android 13 或更早的可写测试镜像。请使用用户证书安装指南。" >&2
    exit 69
fi

echo "将为 $SERIAL（API $SDK）安装系统级 CA。"
run_adb root >/dev/null
run_adb wait-for-device
if [ "$(run_adb shell id -u | tr -d '[:space:]')" != 0 ]; then
    echo "模拟器没有允许 adb root。" >&2
    exit 69
fi
run_adb remount >/dev/null

HASH=$(openssl x509 -subject_hash_old -noout -in "$CERT" | head -n1)
if [ -z "$HASH" ]; then
    echo "无法计算证书 subject_hash_old（需要 openssl）。" >&2
    exit 65
fi

run_adb push "$CERT" "/system/etc/security/cacerts/${HASH}.0" >/dev/null
run_adb shell chmod 644 "/system/etc/security/cacerts/${HASH}.0"
echo "已安装系统级 CA: /system/etc/security/cacerts/${HASH}.0"
echo "如应用未生效，重启模拟器后重试。"
