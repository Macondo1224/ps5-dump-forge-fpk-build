#!/bin/sh
# 在容器里从上游 tag 编译出「含 Web UI」的 Linux 二进制。
#
# 本脚本与 NAS 上那套流程同源（fpk 的 src/app/build/build-upstream.sh），只多了几个
# 环境变量开关，让 GitHub Actions（境外网络）能走直连、省掉国内镜像：
#   FORGE_REPO_URL      源码地址；留空则走 gh-proxy/ghfast 镜像链（NAS 默认行为）
#   FORGE_NODE_BASE     node 二进制下载前缀，默认 npmmirror
#   FORGE_NPM_REGISTRY  npm 源，默认 npmmirror
#   FORGE_CARGO_DIRECT  1=不写 cargo 镜像配置，直接用 crates.io
#   FORGE_TAG           上游 git tag（必填）
#   NODE_VER            node 版本，默认 v22.14.0
#
# 输出：/out/ps5-dump-forge-webui（可执行）+ /out/.build-ok
set -e

TAG="${FORGE_TAG:?缺少 FORGE_TAG}"
NODE_VER="${NODE_VER:-v22.14.0}"
NODE_BASE="${FORGE_NODE_BASE:-https://registry.npmmirror.com/-/binary/node}"
NPM_REG="${FORGE_NPM_REGISTRY:-https://registry.npmmirror.com}"
REPO_URL="${FORGE_REPO_URL:-}"

echo "==> [1/8] 准备工具链 (tag=$TAG)"
mkdir -p /work/node /work/src /work/target /out
if [ ! -x "/work/node/node-$NODE_VER-linux-x64/bin/node" ]; then
    cd /work/node
    curl -fsSLO "$NODE_BASE/$NODE_VER/node-$NODE_VER-linux-x64.tar.xz"
    tar xf "node-$NODE_VER-linux-x64.tar.xz"
fi
export PATH="/work/node/node-$NODE_VER-linux-x64/bin:/usr/local/cargo/bin:$PATH"
export CARGO_TARGET_DIR=/work/target
node -v
rustc --version

export RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static
export RUSTUP_UPDATE_ROOT=https://mirrors.ustc.edu.cn/rust-static/rustup

echo "==> [2/8] 克隆上游源码 $TAG"
rm -rf /work/src
if [ -n "$REPO_URL" ]; then
    git clone --depth 1 --branch "$TAG" "$REPO_URL" /work/src
elif ! git clone --depth 1 --branch "$TAG" https://gh-proxy.com/https://github.com/quer3q/ps5-dump-forge /work/src 2>/dev/null; then
    rm -rf /work/src
    git clone --depth 1 --branch "$TAG" https://ghfast.top/https://github.com/quer3q/ps5-dump-forge /work/src
fi

echo "==> [3/8] 打统一网关前缀补丁"
node /scripts/patch-gateway.mjs /work/src

echo "==> [4/8] npm 安装依赖"
cd /work/src/app
npm ci --registry="$NPM_REG"
# npm optional deps bug(#4828):rolldown 的平台包要显式装
npm install --no-save @rolldown/binding-linux-x64-gnu --registry="$NPM_REG"

echo "==> [5/8] 构建前端 (build:http)"
npm run build:http
ls -l dist-http/index.html

echo "==> [6/8] 配置 cargo 镜像"
if [ "${FORGE_CARGO_DIRECT:-0}" = "1" ]; then
    echo "    跳过（直接用 crates.io）"
else
    mkdir -p /root/.cargo
    printf '[source.crates-io]\nreplace-with = "ustc"\n\n[source.ustc]\nregistry = "sparse+https://mirrors.ustc.edu.cn/crates.io-index/"\n' > /root/.cargo/config.toml
fi

echo "==> [7/8] cargo build --release (最慢的一步)"
cd /work/src
cargo build --release -p ps5-dump-forge-cli

echo "==> [8/8] 导出产物"
cp /work/target/release/ps5-dump-forge /out/ps5-dump-forge-webui
chmod 755 /out/ps5-dump-forge-webui
rm -f /out/.build-ok
touch /out/.build-ok
echo "==> 完成 $(date '+%F %T')"
