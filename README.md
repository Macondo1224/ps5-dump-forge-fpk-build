# ps5-dump-forge-fpk-build

为飞牛 fnOS 上的 **PS5 Dump Forge** fpk 提供可在线更新的二进制：

**定时跟踪上游 [quer3q/ps5-dump-forge](https://github.com/quer3q/ps5-dump-forge) 的新版本 → 构建含 Web UI 的 Linux 二进制 → 发 Release → 刷新 `feed/manifest.json`。**

## 为什么要这个仓库

上游官方的 Linux 包**不含 Web UI**：`scripts/release-linux.sh` 只跑 `cargo build`，前端从未构建，二进制里嵌的是 `web UI not built` 占位页。拿官方包做在线更新，等于把界面更新没。

另外飞牛是 Debian 12（glibc 2.36），用较新的 runner 构建出来的二进制会因 glibc 版本过高而无法启动。

本仓库在**可控环境**里补上前端构建与网关补丁，产物只给自家 fpk 用。

## 构建流程

```
定时（每 6 小时）/ 手动触发
  └─ 查上游最新 release tag
      └─ 该上游版本已构建过？→ 跳过
          └─ docker run rust:1-bookworm ci/build-in-docker.sh
              ├─ git clone --branch <tag>
              ├─ node ci/patch-gateway.mjs      打飞牛网关前缀补丁
              ├─ npm ci && npm run build:http   构建前端（关键，官方漏了这步）
              └─ cargo build --release -p ps5-dump-forge-cli
                  └─ ci/check-artifact.sh       闸门：无占位串 / glibc≤2.36 / 能 --version
                      └─ gh release create v<ver>  附二进制
                          └─ 更新 feed/manifest.json（sha256 + 镜像下载 URL）
```

## 版本号约定

`<上游版本>-<构建号>`，例如 `0.5.4-22`。

- 上游升版 → 构建号回到 1；
- 同一上游强制重编（`force`）→ 构建号 +1；
- **仓库变量 `BUILD_BASE`**：本仓库首次构建某个上游版本时的起始构建号下限。接入本仓库之前，飞牛壳的构建号已由 NAS 本地发版推进到 20+，若这里从 1 起编，新包版本会「小于」已装版本，徽标就不会提示更新，所以初始设为 `21`。**上游升到新版本后把它改回 0**（`gh variable set BUILD_BASE --body 0`），新版本从 `-1` 开始。

飞牛 fpk 的更新边车用 `split_ver()` 把两段拆开：徽标只显示上游版本，面板里分别标注"上游版本"和"本地构建"。

## 产物约束（改动前务必看）

| 约束 | 原因 |
|---|---|
| `runs-on: ubuntu-22.04` | 飞牛 glibc 2.36；`ubuntu-latest`（24.04 / 2.39）构建的产物起不来 |
| 容器 `rust:1-bookworm` | 与 NAS 上验证过的构建环境一致 |
| 先 `npm run build:http` 再 `cargo build` | 否则产物是占位页 |
| 补丁失败必须让构建红 | 宁可没有新版，也不要发"界面点不动"的包 |

## 被谁消费

飞牛上 `ps5dumpforge` fpk 的更新边车（`src/app/updater/updater.py`），读：

```
https://raw.githubusercontent.com/<owner>/<repo>/main/feed/manifest.json
```

manifest 里 `assets.x86_64.file` 写的是 **Release 资产的镜像 URL**（`https://ghfast.top/https://github.com/...`），因为国内直连 `objects.githubusercontent.com` 不通。镜像换掉只需改这里，不用重发二进制。

边车装之前会过四道闸门：sha256 → 扫占位串 → 起临时实例探首页 → 原子替换 + 异步重启。

## 复用性

本仓库的构建与闸门脚本与 NAS 上那套同源，产物的 **sha256 可逐字节复现**：同一 tag、同一容器镜像、同一补丁，CI 产物与 NAS 本机编译产物哈希一致（已验证 `0.5.4-21` 与 `0.5.4-22` 均为 `d21cf2a2…6464`）。

## 许可

构建产物是 [GPL-3.0-or-later](LICENSE) 的衍生作品。本仓库保留上游许可原文，并公开全部构建脚本与补丁以便对照。

- 上游源码：https://github.com/quer3q/ps5-dump-forge
- 本仓库改动：`ci/patch-gateway.mjs`（前端请求路径加 `/app/<appname>` 前缀）
