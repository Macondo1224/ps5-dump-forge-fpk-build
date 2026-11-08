#!/usr/bin/env bash
# 产物闸门：宁可构建失败，也不要发出一个跑不起来或没有界面的包。
#
# 用法: bash ci/check-artifact.sh out/ps5-dump-forge-webui
set -euo pipefail

BIN="${1:?用法: check-artifact.sh <二进制路径>}"

fail() { echo "::error::$*"; exit 1; }

[ -f "$BIN" ] || fail "没有产物 $BIN"

SIZE=$(stat -c%s "$BIN")
echo "产物大小: $SIZE 字节"
# 正常约 12 MB；小于 8 MB 说明前端没嵌进去或构建被截断
[ "$SIZE" -gt 8000000 ] || fail "产物只有 $SIZE 字节，明显偏小"

# 闸门 1：不能是上游的占位页
if grep -aq "web UI not built" "$BIN"; then
    fail "产物里是 'web UI not built' 占位页 —— 前端没在 cargo build 之前构建"
fi

# 闸门 2：glibc 不能超过飞牛的能力（fnOS = Debian 12 = glibc 2.36）
MAXV=$(strings -a "$BIN" | grep -oE 'GLIBC_2\.[0-9]+' | sed 's/GLIBC_2\.//' | sort -n | tail -1 || true)
if [ -n "${MAXV:-}" ]; then
    echo "最高 GLIBC 符号版本: 2.$MAXV"
    [ "$MAXV" -le 36 ] || fail "需要 glibc 2.$MAXV，飞牛只有 2.36（是不是用了 ubuntu-latest 构建？）"
else
    echo "::warning::没找到 GLIBC 符号版本信息，跳过该检查"
fi

# 闸门 3：真的能跑
chmod +x "$BIN"
"$BIN" --version || fail "--version 跑不起来（架构或动态库不匹配）"

# 附加信息，便于事后核对
echo "--- 运行时信息 ---"
"$BIN" --version
echo "sha256: $(sha256sum "$BIN" | cut -d' ' -f1)"
echo "OK"
