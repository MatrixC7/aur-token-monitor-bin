#!/usr/bin/env bash
#
# resolve-upstream.sh —— 查询上游最新 release，决定要不要更新，并给出 AppImage 地址。
#
# 用法:
#   .github/ci/resolve-upstream.sh                    # 本地调试：直接打印 key=value
#   .github/ci/resolve-upstream.sh                   # CI 中：写入 $GITHUB_OUTPUT
#
# 环境变量:
#   UPSTREAM_REPO  默认 Javis603/token-monitor
#   PKGBUILD       默认 ./PKGBUILD
#   GITHUB_TOKEN   可选，用于提高 GitHub API 速率上限
#   GITHUB_OUTPUT  可选，GitHub Actions 的输出文件
#
# 输出（key=value）:
#   has_update=true|false
#   new_ver     上游版本号（已去掉 tag 的 v 前缀）
#   tag         上游原始 tag
#   asset_url   x86_64 AppImage 的下载地址
#
# 退出码约定：
#   0  正常（包括「网络临时故障，下次再试」这种不该打扰人的情况）
#   1  需要人工介入（上游改了资产命名等），让 Actions 亮红灯提醒
#
set -euo pipefail
export LC_ALL=C

repo=${UPSTREAM_REPO:-Javis603/token-monitor}
pkgbuild=${PKGBUILD:-PKGBUILD}
api="https://api.github.com/repos/${repo}/releases/latest"

log() { printf '%s\n' "$*" >&2; }

out() {
	if [[ -n ${GITHUB_OUTPUT:-} ]]; then
		printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
	else
		printf '%s=%s\n' "$1" "$2"
	fi
}

for tool in curl jq; do
	command -v "$tool" >/dev/null 2>&1 || { log "resolve-upstream: missing '$tool'"; exit 1; }
done

curl_release() {
	local auth=()
	[[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
		-H 'Accept: application/vnd.github+json' "${auth[@]}" "$api"
}

# 带重试地取 release JSON；全部失败返回 1（属于「下次再说」，不是错误）
fetch_json() {
	local attempt
	for attempt in 1 2 3; do
		if json=$(curl_release 2>/dev/null) && [[ -n $json ]]; then
			return 0
		fi
		log "resolve-upstream: API attempt ${attempt}/3 failed"
		((attempt < 3)) && sleep 5
	done
	return 1
}

if ! fetch_json; then
	log "::warning::Could not reach the GitHub release API after 3 attempts; skipping this run."
	out has_update false
	exit 0
fi

tag=$(jq -r '.tag_name // empty' <<<"$json")
if [[ -z $tag ]]; then
	log "::warning::Latest release has no tag_name (API rate limit?); skipping this run."
	log "API message: $(jq -r '.message // "(none)"' <<<"$json")"
	out has_update false
	exit 0
fi

newver=${tag#[vV]}

# pkgver 必须能安全地写进 PKGBUILD 和 .SRCINFO
if [[ ! $newver =~ ^[0-9A-Za-z][0-9A-Za-z._+]*$ ]]; then
	log "::error::Upstream tag '${tag}' does not yield a valid Arch pkgver ('${newver}')."
	exit 1
fi

current=""
if [[ -f $pkgbuild ]]; then
	current=$(sed -n -E 's/^pkgver=(.*)$/\1/p' "$pkgbuild" | head -n1)
fi
log "upstream: ${newver}    PKGBUILD: ${current:-<none>}"

if [[ $newver == "$current" ]]; then
	out has_update false
	exit 0
fi

# 资产命名是 PKGBUILD 里 source= 模板的一部分，必须严格匹配，不能猜。
expected="Token-Monitor-${newver}.AppImage"

# release 建好了但资产还在上传的情况确实存在，给它一点时间（最多约 90 秒）
asset_url=""
for attempt in 1 2 3 4; do
	asset_url=$(jq -r --arg n "$expected" \
		'.assets[]? | select(.name == $n) | .browser_download_url' <<<"$json")
	[[ -n $asset_url ]] && break

	if ((attempt < 4)); then
		log "asset ${expected} not published yet (attempt ${attempt}/4), waiting 30s..."
		sleep 30
		json=$(curl_release 2>/dev/null) || json='{}'
	fi
done

if [[ -z $asset_url ]]; then
	log "::error::Release ${tag} has no asset named '${expected}'."
	log "Available assets:"
	jq -r '.assets[]?.name' <<<"$json" | sed 's/^/  - /' >&2
	log "If upstream renamed the AppImage, update the source= template in PKGBUILD first."
	exit 1
fi

out has_update true
out new_ver "$newver"
out tag "$tag"
out asset_url "$asset_url"
