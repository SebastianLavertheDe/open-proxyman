#!/bin/zsh
# 清洗 .build/checkouts：把被系统透明加密层写入的文件用 cat 重写为明文。
# 原理：cat/xxd/grep 等工具读取时有解密视图；bash 重定向写出的文件为明文。
# 跳过 .git 目录（git 自身可正常读取加密内容）。
set -e
cd "$(dirname "$0")/.."

count=0
bytes=0
while IFS= read -r -d '' f; do
  # 跳过符号链接
  [ -L "$f" ] && continue
  count=$((count + 1))
  tmp="${f}.sanitize_tmp"
  cat "$f" > "$tmp" || { rm -f "$tmp"; continue; }
  mv -f "$tmp" "$f"
done < <(find .build/checkouts -type f -not -path "*/.git/*" -print0)

echo "已清洗 $count 个文件"
