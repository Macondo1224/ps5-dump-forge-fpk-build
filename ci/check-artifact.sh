#!/usr/bin/env bash
# 产物闸门：宁可构建失败，也不要发出一个跑不起来或没有界面的包。
#
# 用法: bash ci/check-artifact.sh out/ps5-dump-forge-webui
#
# 注意：构建在 docker 里以 root 执行，产物属 root。本脚本在 CI 里以普通用户运行，
# 不能直接 chmod 原文件，所以所有可执行性检查都在临时副本上做。
set -euo pipefail

SRC="${1:?用法: check-artifact.sh <二进制路径>}"

fail() { echo "::error::$*"; exit 1; }

[ -f "$SRC" ] || fail "没有产物 $SRC"

SIZE=$(stat -c%s "$SRC")
echo "产物大小: $SIZE 字节"
# 正常约 12 MB；小于 8 MB 说明前端没嵌进去或构建被截断
[ "$SIZE" -gt 8000000 ] || fail "产物只有 $SIZE 字节，明显偏小"

# 闸门 1：不能是上游的占位页
if grep -aq "web UI not built" "$SRC"; then
    fail "产物里是 'web UI not built' 占位页 —— 前端没在 cargo build 之前构建"
fi

# 闸门 2：网关前缀补丁必须真的进了前端产物
# 补丁给三个前端文件插入了 `const BASE = ... location.pathname ...`，
# location 是浏览器全局属性，压缩混淆不会改名，因此这个串是可靠的指纹。
if ! grep -aq "location.pathname" "$SRC"; then
    fail "前端里找不到网关前缀补丁（location.pathname）—— ci/patch-gateway.mjs 没生效"
fi
echo "网关前缀补丁: 已嵌入"

# 闸门 3：glibc 不能超过飞牛的能力（fnOS = Debian 12 = glibc 2.36）
MAXV=$(strings -a "$SRC" | grep -oE 'GLIBC_2\.[0-9]+' | sed 's/GLIBC_2\.//' | sort -n | tail -1 || true)
if [ -n "${MAXV:-}" ]; then
    echo "最高 GLIBC 符号版本: 2.$MAXV"
    [ "$MAXV" -le 36 ] || fail "需要 glibc 2.$MAXV，飞牛只有 2.36（是不是用了 ubuntu-latest 构建？）"
else
    echo "::warning::没找到 GLIBC 符号版本信息，跳过该检查"
fi

# 闸门 4：真的能跑（在临时副本上，避免 root 属主导致的权限错误）
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
cp "$SRC" "$TMPD/bin"
chmod 755 "$TMPD/bin"
"$TMPD/bin" --version || fail "--version 跑不起来（架构或动态库不匹配）"

# 附加信息，便于事后核对
echo "--- 运行时信息 ---"
"$TMPD/bin" --version
echo "sha256: $(sha256sum "$SRC" | cut -d' ' -f1)"
echo "OK"
