#!/usr/bin/env bash
#
# gen-srcinfo.sh —— 不依赖 pacman/makepkg，从 PKGBUILD 生成 .SRCINFO。
#
# 用法:
#   .github/ci/gen-srcinfo.sh [PKGBUILD] > .SRCINFO
#
# 为什么需要它：
#   update workflow 跑在纯净的 Debian 上（Debian 没有 pacman/makepkg），而 AUR
#   只认 .SRCINFO。makepkg --printsrcinfo 的输出本身就是「把 PKGBUILD 顶层变量
#   按固定顺序打印成 key = value」，所以这里只复刻「打印」这一半，结果是可复现的。
#
# 安全设计（fail closed）：
#   如果 PKGBUILD 里出现了本脚本不认识的顶层变量，脚本会直接报错退出，而不是
#   悄悄产出一份缺字段的 .SRCINFO。这样 PKGBUILD 一改动就能立刻被发现。
#
set -euo pipefail

die() { printf 'gen-srcinfo: %s\n' "$*" >&2; exit 1; }

pkgbuild=${1:-PKGBUILD}
[[ -f $pkgbuild ]] || die "$pkgbuild: no such file"

# ---------------------------------------------------------------------------
# pkgbase 段的字段，顺序与 makepkg --printsrcinfo 一致。
# pkgbase / pkgname 单独处理，见文件末尾。
# ---------------------------------------------------------------------------
scalar_fields=(
	pkgdesc
	pkgver
	pkgrel
	epoch
	url
	install
	changelog
)

array_fields=(
	arch
	license
	groups
	replaces
	depends
	makedepends
	checkdepends
	optdepends
	provides
	conflicts
	backup
	noextract
	options
	source
	validpgpkeys
	md5sums
	sha1sums
	sha224sums
	sha256sums
	sha384sums
	sha512sums
	b2sums
)

# PKGBUILD 被允许定义的变量全集（加上 pkgbase/pkgname 和 _ 前缀的私有变量）
known=("${scalar_fields[@]}" "${array_fields[@]}" pkgbase pkgname)

# bash 自身的易变内部变量，永远不当作 PKGBUILD 变量
volatile_re='^(BASH.*|FUNCNAME|PIPESTATUS|LINENO|SECONDS|RANDOM|SRANDOM|EPOCH.*|BASHPID|PPID|COLUMNS|LINES|OPTIND|OPTARG|OPTERR|COMP_.*|DIRSTACK|PWD|OLDPWD|SHLVL|UID|EUID|GROUPS|HOSTNAME|HOSTTYPE|MACHTYPE|OSTYPE|IFS|PS[1-4]|SHELLOPTS|BASHOPTS|_)$'

# 本脚本自己的循环变量先声明好，避免被误判成「PKGBUILD 新定义的变量」
unknown=()
v=''

# 快照当前环境，用于事后判断「PKGBUILD 到底新定义了哪些变量」
declare -A before=()
while IFS= read -r v; do before[$v]=1; done < <(compgen -v)
v=''

# PKGBUILD 是可信的版本库文件，source 只会定义变量和函数，不会执行 prepare()/package()
# shellcheck disable=SC1090
source "$pkgbuild"

unknown=()
while IFS= read -r v; do
	[[ -n ${before[$v]:-} ]] && continue        # 早就存在 -> 不是 PKGBUILD 定义的
	[[ $v == _* ]] && continue                  # _pkgname 之类的私有变量
	[[ $v =~ $volatile_re ]] && continue
	[[ " ${known[*]} " == *" $v "* ]] && continue
	unknown+=("$v")
done < <(compgen -v)

if ((${#unknown[@]})); then
	die "unsupported PKGBUILD variable(s): ${unknown[*]}
       请把它们补进 $(basename "$0")，否则 .SRCINFO 会缺字段。"
fi

# ---------------------------------------------------------------------------
# pkgname：本脚本只支持单包 PKGBUILD（本项目正是单包）。
# ---------------------------------------------------------------------------
declare -p pkgname >/dev/null 2>&1 || die "PKGBUILD does not define pkgname"
if [[ $(declare -p pkgname) == "declare -a"* ]]; then
	((${#pkgname[@]} == 1)) || die "split packages are not supported; extend this script first"
	pkgname=${pkgname[0]}
fi
[[ -n ${pkgname:-} ]] || die "pkgname is empty"

pkgbase=${pkgbase:-$pkgname}

[[ -n ${pkgver:-} ]] || die "PKGBUILD does not define pkgver"
[[ $pkgver != *-* && $pkgver != *:* && $pkgver != *[[:space:]]* ]] \
	|| die "pkgver '$pkgver' contains characters forbidden by makepkg"

# ---------------------------------------------------------------------------
# 打印。标量一行，数组每个元素一行；未定义或空值跳过（与 makepkg 一致）。
# ---------------------------------------------------------------------------
emit() {
	local key=$1 decl value
	declare -p "$key" >/dev/null 2>&1 || return 0
	decl=$(declare -p "$key")

	if [[ $decl == "declare -a"* || $decl == "declare -A"* ]]; then
		local -n __ref=$key
		for value in "${__ref[@]}"; do
			[[ -n $value ]] || continue
			printf '\t%s = %s\n' "$key" "$value"
		done
	else
		local -n __ref=$key
		[[ -n $__ref ]] || return 0
		printf '\t%s = %s\n' "$key" "$__ref"
	fi
}

printf 'pkgbase = %s\n' "$pkgbase"
for field in "${scalar_fields[@]}"; do emit "$field"; done
for field in "${array_fields[@]}"; do emit "$field"; done

printf '\n'
printf 'pkgname = %s\n' "$pkgname"
