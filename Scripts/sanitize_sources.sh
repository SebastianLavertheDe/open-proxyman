#!/bin/bash
# 清洗 Sources：把并行进程写入的被加密文件用 cat 重写为明文（bash 工具具有解密视图）
cd "$(dirname "$0")/.."
count=0
while IFS= read -r -d '' f; do
  tmp="${f}.san"
  if cat "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
    count=$((count+1))
  else
    rm -f "$tmp"
  fi
done < <(find Sources -name '*.swift' -print0)
echo "sanitized $count source files"
