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

# 闸门 2：网关前缀补丁与前端构建都真的发生了
# 构建元信息由 build-in-docker.sh 在容器内写出（补丁处数、带 BASE 的文件数、index.html 大小）。
# 不用二进制里 grep 字符串：前端资产被压缩后未必保留明文指纹。
META="$(dirname "$SRC")/build-meta.json"
[ -f "$META" ] || fail "缺少 $META —— 构建脚本没跑到导出步骤"
echo "--- 构建元信息 ---"; cat "$META"; echo
read -r PF PI < <(python3 - "$META" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("patch_files",0), d.get("index_bytes",0))
PY
)
[ "${PF:-0}" = "3" ] || fail "网关补丁只落到 $PF/3 个前端文件 —— ci/patch-gateway.mjs 没生效"
[ "${PI:-0}" -gt 100 ] || fail "前端 dist-http/index.html 只有 $PI 字节 —— 前端没真正构建"
echo "网关前缀补丁: 已嵌入 3/3 文件；前端 index.html: $PI 字节"

# 闸门 3：glibc 不能超过飞牛的能力（fnOS = Debian 12 = glibc 2.36）
MAXV=$(strings -a "$SRC" | grep -oE 'GLIBC_2\.[0-9]+' | sed 's/GLIBC_2\.//' | sort -n | tail -1 || true)
if [ -n "${MAXV:-}" ]; then
    echo "最高 GLIBC 符号版本: 2.$MAXV"
    [ "$MAXV" -le 36 ] || fail "需要 glibc 2.$MAXV，飞牛只有 2.36（是不是用了 ubuntu-latest 构建？）"
else
    echo "::warning::没找到 GLIBC 符号版本信息，跳过该检查"
fi

# 闸门 4：真的能跑（在临时副本上，避免 root 属主导致的权限错误）
# 上游 CLI 没有 --version 参数（会打印帮助并以非 0 退出），所以用 --help + 输出里有没有用法行来判断。
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
cp "$SRC" "$TMPD/bin"
chmod 755 "$TMPD/bin"
file "$TMPD/bin" 2>/dev/null | sed 's/^/文件类型: /' || true
HELP="$("$TMPD/bin" --help 2>&1 || true)"
echo "$HELP" | grep -qiE 'usage|用法' || fail "--help 跑不起来或没有输出用法（架构或动态库不匹配？）"
echo "可执行性: 通过（--help 正常输出）"

# 附加信息，便于事后核对
echo "--- 运行时信息 ---"
echo "$HELP" | head -3
echo "sha256: $(sha256sum "$SRC" | cut -d' ' -f1)"
echo "OK"
