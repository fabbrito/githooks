#!/usr/bin/env bash
#
# Download the latest githooks release into .githooks/githooks.
#
# Run it from the repo that vendors the engine: one file is vendored, and this
# replaces it with the newest release. It commits nothing, so the diff is
# yours to review.
#
#   scripts/update.sh [--dry-run]
#
# No errexit: each step is checked where it can fail. Exit 2 is a usage,
# config, network or integrity problem; 0 means up to date or updated.

set -uo pipefail

engine_repo='fabbrito/githooks'
engine_path='bin/githooks'
api_url='https://api.github.com/repos'
raw_url='https://raw.githubusercontent.com'
vendored='.githooks/githooks'

# Unauthenticated the API allows 60 requests an hour per address; a token lifts
# that, and is the only thing GITHUB_TOKEN is used for here.
curl_flags=(-fsS --connect-timeout 10 --max-time 60)
if [[ -n ${GITHUB_TOKEN-} ]]; then
	curl_flags+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

tmp=''
trap '[[ -n $tmp ]] && rm -rf -- "$tmp"' EXIT

die() {
	printf 'update: %s\n' "$*" >&2
	exit 2
}

# VERSION='vX.Y.Z' is stamped into the engine by scripts/release.sh, so the tag
# a copy reports is the tag it came from. It is the only proof that the bytes
# fetched are the bytes asked for: no checksum is published. Printed, or fails.
version_of() {
	local line

	while IFS= read -r line; do
		case $line in
			VERSION=\'*\')
				line=${line#VERSION=\'}
				printf '%s' "${line%\'}"
				return 0
				;;
		esac
	done <"$1"

	return 1
}

dry=false
if [[ ${1-} == --dry-run ]]; then
	dry=true
	shift
fi
(($#)) && die "unknown argument: $1"

for cmd in curl jq; do
	command -v "$cmd" >/dev/null ||
		die "$cmd not found - install it first"
done

if [[ ! -f $vendored ]]; then
	die "no $vendored here - run this from the repo that vendors it"
fi

current=$(version_of "$vendored") || current=''

printf 'update: asking %s for the latest release\n' "$engine_repo"
tag=$(curl "${curl_flags[@]}" "$api_url/$engine_repo/releases/latest" |
	jq -r '.tag_name // empty') || die 'cannot reach the GitHub releases API'
[[ -n $tag ]] || die "no tag_name in the API reply for $engine_repo"

if [[ $current == "$tag" ]]; then
	printf 'update: already at %s\n' "$tag"
	exit 0
fi

url="$raw_url/$engine_repo/$tag/$engine_path"
printf 'update: %s -> %s\n' "${current:-unversioned}" "$tag"

if $dry; then
	printf 'update: would install %s\n' "$url"
	exit 0
fi

tmp=$(mktemp -d) || die 'mktemp failed'
curl "${curl_flags[@]}" "$url" -o "$tmp/githooks" || die "cannot download $url"

[[ -s $tmp/githooks ]] || die "empty download from $url"

fetched=$(version_of "$tmp/githooks") ||
	die "$tag does not look like the engine - no VERSION stamp"
[[ $fetched == "$tag" ]] || die "$url stamps $fetched, not $tag"

install -m 755 "$tmp/githooks" "$vendored" || die "cannot write $vendored"

printf 'update: now at %s\n' "$tag"
printf 'update: bump the version named in hooks.conf, then commit\n'
