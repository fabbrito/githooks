#!/usr/bin/env bash
#
# Publish what `make release` tagged: master and the tag to origin, then a
# GitHub release. Consumers fetch the engine from the tag's raw URL, so the
# tag is the artifact - nothing is uploaded.
#   make publish [DRY_RUN=1]
#
# A release is never moved after this. A bad one gets the next patch.
#
# A dry run touches neither origin nor gh, and reports every refusal.
#
# No errexit: each step is checked where it can fail.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

die() {
	printf 'publish: %s\n' "$*" >&2
	exit 1
}

dry=false
if [[ ${1-} == --dry-run ]]; then
	dry=true
	shift
fi

refusals=0
refuse() {
	$dry || die "$@"
	printf 'publish: would refuse: %s\n' "$*" >&2
	((refusals += 1))
	return 0
}

tag=$(git describe --tags --exact-match HEAD 2>/dev/null) ||
	die 'HEAD carries no tag - make release first'
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$tag is not a release tag"
[[ $(git branch --show-current) == master ]] || refuse 'not on master'
[[ -z $(git status --porcelain) ]] || refuse 'tree not clean'
grep -q "^VERSION='$tag'\$" bin/githooks ||
	refuse "bin/githooks is not stamped $tag"
command -v gh >/dev/null 2>&1 || refuse 'gh not found'

previous=$(git describe --tags --abbrev=0 "$tag^" 2>/dev/null)
if [[ -n $previous ]]; then
	notes=$(git log --pretty='- %s' "$previous..$tag")
else
	notes=$(git log --pretty='- %s' "$tag")
fi
raw=https://raw.githubusercontent.com/fabbrito/githooks/$tag/bin/githooks
notes+=$'\n\nVendor it:\n\n    curl -fsSL '$raw$' -o .githooks/githooks'

if $dry; then
	printf 'publish: would send master and %s to origin, then:\n' "$tag"
	printf '  gh release create %s --title %s --notes ...\n' "$tag" "$tag"
	printf -- '--- notes ---\n%s\n' "$notes"
	((refusals > 0)) && exit 1
	exit 0
fi

git push origin master || die 'cannot push master'
git push origin "$tag" || die 'cannot push the tag'
gh release create "$tag" --title "$tag" --notes "$notes" ||
	die 'gh release failed'

printf 'publish: %s is up\n' "$tag"
