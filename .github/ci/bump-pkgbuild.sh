#!/usr/bin/env bash
#
# bump-pkgbuild.sh —— 把 PKGBUILD 更新到新的上游版本。
#
# 用法:
#   .github/ci/bump-pkgbuild.sh <版本号> <sha256> [PKGBUILD]
#
# 只改三个地方：pkgver、pkgrel（归 1）、sha256sums。
# source= / noextract= 里用的是 ${pkgver} 变量，会自动跟着变，不需要 sed。
#
# 校验是刻意的「宁可失败也不写坏文件」：参数不合法、字段没匹配到、源数量不是 1，
# 都会直接退出并返回非零，让 workflow 停在这一步而不是推一份坏元数据出去。
#
set -euo pipefail

die() { printf 'bump-pkgbuild: %s\n' "$*" >&2; exit 1; }

if (($# < 2)); then
	die "usage: ${0##*/} <pkgver> <sha256> [PKGBUILD]"
fi

newver=$1
newsum=$2
pkgbuild=${3:-PKGBUILD}

[[ -f $pkgbuild ]] || die "$pkgbuild: no such file"

# Arch 允许的 pkgver 字符集：字母数字 . _ +，且不能以 - 或 : 开头。
# 这个白名单同时也保证下面的 sed 替换不会被特殊字符污染（不含 & | / 等）。
[[ $newver =~ ^[0-9A-Za-z][0-9A-Za-z._+]*$ ]] || die "invalid pkgver: '$newver'"
[[ $newsum =~ ^[0-9a-f]{64}$ ]] || die "invalid sha256: '$newsum'"

# 本脚本只处理「单源」PKGBUILD：一个 source 对应一个校验和。
# 多源包需要人来看，别让它自动算错。
nsrc=$(bash -c 'set -euo pipefail; source "$1" >/dev/null 2>&1 || exit 0; echo ${#source[@]}' _ "$pkgbuild" 2>/dev/null || echo 0)
[[ $nsrc == 1 ]] || die "expected exactly 1 source entry, found '${nsrc}' — update this PKGBUILD by hand"

# --- pkgver / pkgrel -------------------------------------------------------
sed -i -E "s|^pkgver=.*|pkgver=${newver}|" "$pkgbuild"
sed -i -E "s|^pkgrel=.*|pkgrel=1|" "$pkgbuild"

# --- sha256sums ------------------------------------------------------------
sed -i -E "s|^sha256sums=\(.*\)\s*$|sha256sums=('${newsum}')|" "$pkgbuild"

# --- 校验：三个字段都真的改到位了 ------------------------------------------
grep -qx "pkgver=${newver}" "$pkgbuild"             || die "failed to set pkgver"
grep -qx "pkgrel=1" "$pkgbuild"                     || die "failed to set pkgrel"
grep -qx "sha256sums=('${newsum}')" "$pkgbuild"     || die "failed to set sha256sums (is it a single-line array?)"

printf 'bump-pkgbuild: %s -> pkgver=%s pkgrel=1 sha256=%s\n' "$pkgbuild" "$newver" "$newsum"
