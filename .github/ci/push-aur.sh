#!/usr/bin/env bash
#
# push-aur.sh —— 把仓库根目录的 PKGBUILD 和 .SRCINFO 推到 AUR。
#
# 用法:
#   NEW_VER=0.90.0 AUR_SSH_PRIVATE_KEY="$(cat ~/.ssh/aur)" bash .github/ci/push-aur.sh
#
# 环境变量:
#   NEW_VER              必填，用于 commit message
#   PKGBASE              默认 token-monitor-bin
#   AUR_SSH_PRIVATE_KEY  ssh:// 推送时必填
#   AUR_HOST_KEY         aur.archlinux.org 的 known_hosts 行；不填则退回 ssh-keyscan
#   AUR_USERNAME / AUR_EMAIL  提交署名
#   AUR_URL              覆盖仓库地址（本地测试用 file:// 或路径）
#
set -euo pipefail

die() { printf 'push-aur: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

pkgbase=${PKGBASE:-token-monitor-bin}
newver=${NEW_VER:-}
[[ -n $newver ]] || die "NEW_VER is not set"

url=${AUR_URL:-ssh://aur@aur.archlinux.org/${pkgbase}.git}
gitname=${AUR_USERNAME:-github-actions[bot]}
gitemail=${AUR_EMAIL:-github-actions[bot]@users.noreply.github.com}

for f in PKGBUILD .SRCINFO; do
	[[ -f $f ]] || die "missing $f in $(pwd)"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ $url == ssh://* ]]; then
	[[ -n ${AUR_SSH_PRIVATE_KEY:-} ]] || die "AUR_SSH_PRIVATE_KEY is not set"

	# Windows 上复制粘贴的密钥常带 CRLF，ssh 会直接拒绝，这里顺手清掉
	printf '%s\n' "$AUR_SSH_PRIVATE_KEY" | tr -d '\r' >"$work/aur"
	chmod 600 "$work/aur"

	# 优先用固定的 host key；没有就 ssh-keyscan（TOFU，安全性弱一档）
	if [[ -n ${AUR_HOST_KEY:-} ]]; then
		printf '%s\n' "$AUR_HOST_KEY" >"$work/known_hosts"
	else
		log "::warning::AUR_HOST_KEY is not set; falling back to ssh-keyscan (TOFU)."
		ssh-keyscan -T 15 -t ed25519,rsa aur.archlinux.org >"$work/known_hosts" 2>/dev/null || true
	fi
	[[ -s $work/known_hosts ]] || die "no AUR host key available"

	export GIT_SSH_COMMAND="ssh -i $work/aur -o IdentitiesOnly=yes -o UserKnownHostsFile=$work/known_hosts -o StrictHostKeyChecking=yes"
fi

git clone --depth=1 "$url" "$work/aur-repo" >/dev/null 2>&1 \
	|| die "failed to clone $url (AUR 仓库必须已存在，且密钥已注册到 AUR 账号)"

# 只推送这两个文件：.github 之类的东西不进 AUR 仓库
cp PKGBUILD .SRCINFO "$work/aur-repo/"
cd "$work/aur-repo"

git config user.name "$gitname"
git config user.email "$gitemail"
git add PKGBUILD .SRCINFO

if git diff --cached --quiet; then
	log "AUR already up to date (${pkgbase} ${newver}-1)"
	exit 0
fi

git commit -m "upgpkg: ${pkgbase} ${newver}-1" >/dev/null
git push origin master

log "pushed ${pkgbase} ${newver}-1 to AUR"
