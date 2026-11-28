#!/bin/zsh
# 健壮构建：本机环境下 swift-build 的编译子进程可能被安全软件静默杀死。
# 策略：先正常构建；若失败且日志无编译错误，则用 verbose 提取 swift-frontend
# 命令逐条手动执行（单进程模式不受影响），再重试构建直至完成。
cd "$(dirname "$0")/.."
build_args=(--product ProxyMirror "$@")

attempt_build() {
  # 先清洗 Sources（并行会话写入的文件可能被加密层加密）
  while IFS= read -r -d "" f; do
    tmp="${f}.san"
    if cat "$f" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$f"; else rm -f "$tmp"; fi
  done < <(find Sources -name "*.swift" -print0)
  swift build "${build_args[@]}" -j 1 > /tmp/pmb.log 2>&1
}

if attempt_build; then
  echo "BUILD OK"
  exit 0
fi

for round in 1 2 3 4; do
  if /usr/bin/grep -q "error:" /tmp/pmb.log; then
    # 只有源代码错误才算真错误（链接失败/进程被杀 → 走手动编译重试）
    has_src=$(/usr/bin/grep "error:" /tmp/pmb.log | /usr/bin/grep "\.swift:" | /usr/bin/grep -cv xcrun)
    if [ "$has_src" -gt 0 ]; then
      echo "存在编译错误:"
      /usr/bin/grep "error:" /tmp/pmb.log | /usr/bin/grep "\.swift:" | grep -v xcrun | sort -u | head -12
      exit 1
    fi
  fi
  echo "构建被中断(第 $round 轮)，改用手动编译..."
  swift build "${build_args[@]}" --verbose > /tmp/pmv.log 2>&1 || true
  /usr/bin/grep "swift-frontend" /tmp/pmv.log > /tmp/pmc.txt || true
  if [ ! -s /tmp/pmc.txt ]; then
    echo "没有待执行的前端编译命令，退出"; tail -3 /tmp/pmb.log; exit 1
  fi
  i=0; fails=0
  while IFS= read -r cmd; do
    i=$((i+1))
    if ! zsh -c "$cmd" > /tmp/pmo_$i.log 2>&1; then
      fails=$((fails+1))
      echo "手动编译失败 CMD $i:"
      /usr/bin/grep "error:" /tmp/pmo_$i.log | head -6
    fi
  done < /tmp/pmc.txt
  [ "$fails" -gt 0 ] && exit 1
  if attempt_build; then echo "BUILD OK"; exit 0; fi
done

echo "构建仍未完成:"; tail -5 /tmp/pmb.log
exit 1
