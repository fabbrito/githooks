#!/usr/bin/env bash
#
# Cut a release on this machine: stamp, vendor, gate, commit, tag. Nothing
# leaves the machine - `make publish` does that.
#   make release VERSION=v1.0.0 [DRY_RUN=1]
#
# The version is stamped into bin/githooks and the vendored copy, so a
# consumer that runs `githooks version` gets the tag it fetched, with no lock
# file to keep in sync. Between releases the tree carries the last one: the
# tag is the truth, the constant is a convenience.
#
# A dry run writes nothing and reports every refusal instead of the first.
#
# No errexit: each step is checked where it can fail.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

die() {
	printf 'release: %s\n' "$*" >&2
	exit 1
}

dry=false
if [[ ${1-} == --dry-run ]]; then
	dry=true
	shift
fi

version=${1-}
version=${version#v}
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	printf 'usage: %s [--dry-run] <x.y.z>\n' "$0" >&2
	exit 2
fi
tag=v$version
subject="chore(release): release $tag"

refusals=0
refuse() {
	$dry || die "$@"
	printf 'release: would refuse: %s\n' "$*" >&2
	((refusals += 1))
	return 0
}

[[ $(git branch --show-current) == master ]] || refuse 'not on master'
[[ -z $(git status --porcelain) ]] || refuse 'tree not clean'
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
	refuse "$tag exists - a release is never moved, cut the next patch"
fi
if git remote get-url origin >/dev/null 2>&1; then
	git fetch --quiet origin master || die 'cannot fetch origin'
	git merge-base --is-ancestor origin/master HEAD ||
		refuse 'origin/master has commits this branch lacks'
	# A tag absent here may still be on origin: a stale clone, a pruned tag.
	# `git tag` would not see it, so the release would collide at publish time.
	git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null
	case $? in
		0) refuse "$tag exists on origin - a release is never moved, cut the next patch" ;;
		2) ;;
		*) die 'cannot list tags on origin' ;;
	esac
fi

if $dry; then
	printf 'release: would stamp %s, vendor, gate, commit, tag\n' "$tag"
	((refusals > 0)) && exit 1
	exit 0
fi

# Stamp both copies before the gate: the gate runs the vendored engine, so a
# release is proven with exactly the bytes that ship.
sed -i "s/^VERSION=.*/VERSION='$tag'/" bin/githooks ||
	die 'cannot stamp bin/githooks'
cp bin/githooks .githooks/githooks || die 'cannot vendor the engine'
chmod +x .githooks/githooks

grep -q "^VERSION='$tag'\$" bin/githooks || die 'stamp did not take'

if ! make test check; then
	git checkout -- bin/githooks .githooks/githooks
	die 'gate failed - nothing committed'
fi

git add bin/githooks .githooks/githooks || die 'cannot stage the stamp'
git commit -qm "$subject" || die 'commit failed'
git tag -a "$tag" -m "$tag" || die 'tag failed'

printf 'release: %s tagged - make publish sends it up\n' "$tag"
