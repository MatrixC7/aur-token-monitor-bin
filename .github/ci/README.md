# CI 说明

这个仓库是 `token-monitor-bin` 的 GitHub 侧源码仓库，`.github/workflows/update.yml`
负责发现上游新版本、更新 `PKGBUILD` / `.SRCINFO`，然后同时推到 GitHub 和 AUR。

## 为什么跑在 Debian 上

旧版本直接在 `archlinux:base-devel` 容器里 `pacman -Sy` 装工具。Arch 是滚动发行版，
官方明确不支持「部分升级」：镜像里打进去的库是旧的，`-Sy` 拉来的索引是新的，
两边一算就得到 `installing X breaks dependency Y` 之类的死结。旧 workflow 用

```sh
pacman -U .../openssl-3.6.5-1-x86_64.pkg.tar.zst
```

把 openssl 钉在一个旧版本，只是在把冲突往后拖——那个包迟早会和更新的
glibc / icu / curl 再撞一次，而且每次撞都得人工救一次。

现在整条流水线只需要「下载一个文件 + 算哈希 + 改几行文本 + git push」，
完全不需要 pacman 和 makepkg，所以跑在 Debian stable 上：

- Debian stable 在一个发行版周期内依赖图始终自洽，不会出现断裂式升级；
- 基础镜像按 **digest** 钉死（`debian:13-slim@sha256:...`），digest 是不可变的，
  不会像 `latest` / `base-devel` 那样今天和明天拉到不同的东西；
- 只装 `ca-certificates curl git jq openssh-client` 这几个包，全都来自 Debian 官方源。

## 文件职责

| 文件 | 作用 |
| --- | --- |
| `.github/workflows/update.yml` | 主流程：查上游 → 下载 → 算哈希 → 改 PKGBUILD → 推 GitHub → 推 AUR |
| `.github/workflows/validate.yml` | 守卫：确认 `.SRCINFO` 与 `PKGBUILD` 一致、脚本语法无误 |
| `.github/ci/resolve-upstream.sh` | 查 GitHub API，判断要不要更新，给出 AppImage 地址 |
| `.github/ci/bump-pkgbuild.sh` | 改 `pkgver` / `pkgrel` / `sha256sums`，参数不合法就拒绝执行 |
| `.github/ci/gen-srcinfo.sh` | 不依赖 makepkg，直接从 PKGBUILD 生成 `.SRCINFO` |
| `.github/ci/push-aur.sh` | 克隆 AUR 仓库、只复制两个文件、提交并推送 |

`gen-srcinfo.sh` 的输出与 `makepkg --printsrcinfo` 逐字节一致（已对 0.89.0 验证过）。
它的策略是「宁可失败也不写坏文件」：PKGBUILD 里一旦出现它不认识的顶层变量，
它会直接报错退出，而不是悄悄产出一份缺字段的 `.SRCINFO`。

## 需要的仓库配置

Secrets：

| 名称 | 必填 | 说明 |
| --- | --- | --- |
| `AUR_SSH_PRIVATE_KEY` | 是 | 已注册到 AUR 账号的 SSH 私钥 |

Variables（Settings → Secrets and variables → Actions → Variables）：

| 名称 | 必填 | 说明 |
| --- | --- | --- |
| `AUR_USERNAME` | 否 | 提交署名，缺省 `github-actions[bot]` |
| `AUR_EMAIL` | 否 | 提交邮箱 |
| `AUR_HOST_KEY` | 否 | `aur.archlinux.org` 的 host key（`known_hosts` 格式一行）。不填会退回 `ssh-keyscan`，等价于每次重新信任，弱一些 |
| `BUILD_IMAGE` | 否 | 覆盖基础镜像，例如临时换回 `debian:12-slim@sha256:...` |

`AUR_HOST_KEY` 可以这样取（在本机执行，然后核对指纹后粘贴进变量）：

```sh
ssh-keyscan -t ed25519 aur.archlinux.org
```

## 升级基础镜像

digest 钉死意味着镜像不会自己更新（这是刻意的）。想跟上新的 Debian 点版本时：

```sh
docker buildx imagetools inspect debian:13-slim --format '{{.Manifest.Digest}}'
```

把拿到的 `sha256:...` 替换 `update.yml` 里 `container.image` 的 digest（或者直接设
`BUILD_IMAGE` 变量），然后手动 `workflow_dispatch` 跑一次确认。

## 本地使用

不需要 Arch、不需要 docker，任何装了 bash + jq 的机器都能重新生成元数据：

```sh
# 只看当前 PKGBUILD 会生成什么
bash .github/ci/gen-srcinfo.sh PKGBUILD

# 手动改版本（正常情况由 CI 做）
bash .github/ci/bump-pkgbuild.sh 0.90.0 <sha256> PKGBUILD
bash .github/ci/gen-srcinfo.sh PKGBUILD > .SRCINFO

# 查上游有没有新版本
GITHUB_TOKEN=$(gh auth token) bash .github/ci/resolve-upstream.sh
```
