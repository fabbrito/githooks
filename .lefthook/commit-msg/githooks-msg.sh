#!/usr/bin/env bash
#
# githooks-msg - grade a commit message against a committed hooks.conf.
#
# Delivered to a consumer by lefthook `remotes` (shared/base.yml) as its
# commit-msg script. Lanes are lefthook's; this file only grades messages.
# All per-repo policy lives in .githooks/hooks.conf.
#
#   githooks-msg.sh <file>|-            grade a message; - reads stdin
#   githooks-msg.sh version             print the version
#
# Exit: 0 ok, 1 rejected, 2 usage, config or a broken environment.
set -uo pipefail

VERSION='v0.4.0'
SCHEMA=2

prog=githooks-msg

# Regexes live in variables: inside [[ ]] a bracket class reads as the closing
# ]] to more than one parser, shfmt's included.
re_subject='^([a-zA-Z]+)(\(([^)]*)\))?:[[:space:]](.*)$'
re_trailer='^([A-Za-z][A-Za-z0-9-]*):[[:space:]]*(.*)$'
re_person='^.+[[:space:]]<[^[:space:]@]+@[^[:space:]]+>$'
re_token='^[^[:space:]]+$'

# Git's cut line, exactly: "# ", 24 dashes, " >8 ", 24 dashes. Git ends the
# message only at this line - not at any comment that happens to hold ">8".
cut_line='# ------------------------ >8 ------------------------'

# Bash floor. Exists for the error message, not for portability: without it a
# 3.2 shell dies on a syntax error 300 lines from the cause.
if ((BASH_VERSINFO[0] < 4)) ||
	((BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4)); then
	printf '%s: requires bash >= 4.4, found %s\n' "$prog" "$BASH_VERSION" >&2
	exit 2
fi

# ---------------------------------------------------------------- reporting

red=''
bold=''
reset=''
if [[ -t 2 ]]; then
	red=$'\033[0;31m'
	bold=$'\033[1m'
	reset=$'\033[0m'
fi

status=0
scope_rejected=0

# A usage, config or environment problem - including git itself failing.
# Never 1: none of these judged the commit, and a 1 invites --no-verify as
# the fix when the real problem is the machine.
gh_die() {
	printf '%s%s: %s%s\n' "$red" "$prog" "$*" "$reset" >&2
	exit 2
}

# what -> what to write instead. Every rejection carries both.
gh_reject() {
	printf '%s%s: %s%s\n' "$red" "$prog" "$1" "$reset" >&2
	shift
	local line
	for line in "$@"; do
		printf '  %s\n' "$line" >&2
	done
	status=1
}

gh_note() {
	printf '%s\n' "$*" >&2
}

# A preview line, cut to fit the width a bullet is graded against.
gh_clip() {
	local text=$1 max=$2
	if ((${#text} > max)); then
		printf '%s...' "${text:0:max-3}"
	else
		printf '%s' "$text"
	fi
}

# ------------------------------------------------------------------- config

declare -A conf

gh_conf_defaults() {
	conf[schema]=1
	conf[types]='feat fix refactor chore style docs build perf'
	conf[subject_max]=72
	conf[bullet_max]=2
	conf[body_cols]=80
	conf[trailer_person]='Co-Authored-By Signed-off-by Reviewed-by'
	conf[trailer_reference]='Refs Closes Fixes'
	conf[scope_fixed]=''
	conf[scope_root]=''
}

# Append to a newline-joined accumulator.
gh_append() {
	local -n ref=$1
	if [[ -z ${ref:-} ]]; then
		ref=$2
	else
		ref+=$'\n'$2
	fi
}

gh_parse_conf() {
	local file=$1
	local line key value lineno=0
	# Line each key was first written on. A second line replaces, and a
	# replaced list narrows the policy with nothing downstream to catch it.
	local -A seen=()

	while IFS= read -r line || [[ -n $line ]]; do
		((lineno++))
		line=${line%$'\r'}
		line=${line#"${line%%[![:space:]]*}"}

		[[ -z $line ]] && continue
		[[ $line == '#'* ]] && continue

		if [[ $line == '['* ]]; then
			gh_die "$file:$lineno: lanes moved to lefthook.yml -" \
				"delete every [group] section and set schema = $SCHEMA"
		fi

		[[ $line == *=* ]] ||
			gh_die "$file:$lineno: expected key = value, got: $line"

		key=${line%%=*}
		value=${line#*=}
		key=${key%"${key##*[![:space:]]}"}
		value=${value#"${value%%[![:space:]]*}"}
		value=${value%%[[:space:]]#*}
		value=${value%"${value##*[![:space:]]}"}

		if [[ $key != scope_root ]]; then
			if [[ -n ${seen[$key]:-} ]]; then
				gh_die "$file:$lineno: duplicate key: $key, first at line" \
					"${seen[$key]} - write one $key line; only scope_root accumulates"
			fi
			seen[$key]=$lineno
		fi

		# conf_defaults already holds every key there is, so "has a
		# default" is the whole validator - no second list to drift.
		case $key in
			scope_root) gh_append "conf[scope_root]" "$value" ;;
			*)
				[[ -n ${conf[$key]+set} ]] ||
					gh_die "$file:$lineno: unknown key: $key"
				conf[$key]=$value
				;;
		esac
	done <"$file"
}

gh_check_schema() {
	local declared=${conf[schema]}
	[[ $declared =~ ^[0-9]+$ ]] ||
		gh_die "schema must be a number, got: $declared"
	((declared == SCHEMA)) && return 0
	local speaks="hooks.conf declares schema $declared; $prog"
	speaks+=" $VERSION speaks schema $SCHEMA"
	if ((declared > SCHEMA)); then
		gh_die "$speaks - the grader is stale, bump the remote ref"
	fi
	gh_die "$speaks - move lanes to lefthook.yml and set schema = $SCHEMA," \
		"see the README"
}
gh_check_numbers() {
	local key
	for key in subject_max bullet_max body_cols; do
		[[ ${conf[$key]} =~ ^[0-9]+$ ]] ||
			gh_die "$key must be a number, got: ${conf[$key]}"
	done
}

gh_load_conf() {
	gh_conf_defaults
	local file=${GITHOOKS_CONF:-$root/.githooks/hooks.conf}
	[[ -f $file ]] || gh_die "no config at $file"
	gh_parse_conf "$file"
	gh_check_schema
	gh_check_numbers
}

# --------------------------------------------------------------- git basics

# Sets $root. Never a command substitution: `die` inside $( ) exits only that
# subshell, and the caller carries on with an empty root.
gh_find_root() {
	root=$(git rev-parse --show-toplevel 2>/dev/null) ||
		gh_die 'not inside a git repository'
}

# Mid-rebase? .git is a file in a worktree, so ask git for the real dir.
gh_rebase_in_progress() {
	local dir
	dir=$(git rev-parse --git-path rebase-merge 2>/dev/null)
	[[ -d $dir ]] && return 0
	dir=$(git rev-parse --git-path rebase-apply 2>/dev/null)
	[[ -d $dir ]]
}

# -------------------------------------------------------------- commit-msg

# Strip what git itself would strip: CR, the scissors tail, comment lines,
# trailing whitespace, and leading/trailing blank lines.
gh_read_message() {
	local raw=() line
	lines=()

	if [[ $1 == '-' ]]; then
		mapfile -t raw
	else
		[[ -f $1 ]] || gh_die "no such message file: $1"
		mapfile -t raw <"$1"
	fi

	for line in "${raw[@]}"; do
		line=${line%$'\r'}
		[[ $line == "$cut_line" ]] && break
		[[ $line == '#'* ]] && continue
		lines+=("${line%"${line##*[![:space:]]}"}")
	done

	while ((${#lines[@]} > 0)) && [[ -z ${lines[0]} ]]; do
		lines=("${lines[@]:1}")
	done
	while ((${#lines[@]} > 0)) && [[ -z ${lines[-1]} ]]; do
		unset 'lines[-1]'
	done
}

# Messages git wrote, not a person: grading them rejects work nobody typed.
gh_is_generated() {
	case $1 in
		'Merge '* | 'Revert '* | 'fixup!'* | 'squash!'* | 'amend!'*) return 0 ;;
	esac
	return 1
}

gh_in_list() {
	local needle=$1 item
	shift
	for item in "$@"; do
		[[ $item == "$needle" ]] && return 0
	done
	return 1
}

# scope_fixed plus the basename of every directory a scope_root glob finds.
# An unmatched glob is dropped, not an error: a repo can outgrow a root.
gh_scope_list() {
	local pattern path base
	scopes=()
	read -r -a scopes <<<"${conf[scope_fixed]}"

	while IFS= read -r pattern; do
		[[ -z $pattern ]] && continue
		for path in "$root"/$pattern; do
			[[ -e $path ]] || continue
			base=${path%/}
			base=${base##*/}
			gh_in_list "$base" "${scopes[@]}" || scopes+=("$base")
		done
	done <<<"${conf[scope_root]}"
}

gh_print_shape() {
	gh_note ''
	gh_note "${bold}the shape:${reset}"
	gh_note '  type(scope): subject'
	gh_note ''
	gh_note '  - bullet'
	gh_note '  Trailer: value'
	gh_note ''
	gh_note "  types: ${conf[types]}"
	if ((scope_rejected)); then
		gh_note "  scopes: ${scopes[*]}"
	fi
}

gh_grade_subject() {
	local subject=$1 type parens scope text types=()
	read -r -a types <<<"${conf[types]}"

	if [[ ! $subject =~ $re_subject ]]; then
		gh_reject 'subject is not type(scope): subject' \
			"got:   $subject" \
			'write: feat(hooks): add the dispatcher'
		return
	fi

	type=${BASH_REMATCH[1]}
	parens=${BASH_REMATCH[2]}
	scope=${BASH_REMATCH[3]}
	text=${BASH_REMATCH[4]}

	if ! gh_in_list "$type" "${types[@]}"; then
		gh_reject "unknown type: $type" \
			"write: one of ${conf[types]}"
	fi

	# The capture group, not the raw line: a subject whose text carries
	# parens - "add foo (bar)" - has no scope and is not an empty one.
	if [[ -n $parens ]]; then
		if [[ -z $scope ]]; then
			gh_reject 'empty scope' \
				'write: drop the parens, or name a scope'
		elif ! gh_in_list "$scope" "${scopes[@]}"; then
			scope_rejected=1
			gh_reject "unknown scope: $scope" \
				'write: one of the scopes listed below'
		fi
	fi

	if [[ -z $text ]]; then
		gh_reject 'empty subject' \
			'write: say what changed, lowercase, no period'
	else
		if [[ ${text:0:1} == [A-Z] ]]; then
			gh_reject 'subject starts with a capital' \
				"got:   $text" \
				"write: ${text,}"
		fi
		if [[ $text == *. ]]; then
			gh_reject 'subject ends with a period' \
				"write: ${text%.}"
		fi
	fi

	if ((${#subject} > conf[subject_max])); then
		gh_reject "subject is ${#subject} chars, max is ${conf[subject_max]}" \
			'write: cut the subject, move detail into a bullet'
	fi
}

gh_grade_body() {
	local i=1 j k line next prose key value bullets=0 in_trailers=0
	local persons=() refs=()
	read -r -a persons <<<"${conf[trailer_person]}"
	read -r -a refs <<<"${conf[trailer_reference]}"

	((${#lines[@]} < 2)) && return

	if [[ -n ${lines[1]} ]]; then
		gh_reject 'body must follow a blank line' \
			'write: one empty line between the subject and the body'
	fi
	i=2

	for (( ; i < ${#lines[@]}; i++)); do
		line=${lines[i]}

		if [[ -z $line ]]; then
			# One blank line before the trailer block is git's own
			# convention - interpret-trailers writes it. Anywhere else a
			# blank line means the body is not bullets.
			if ((in_trailers == 0)) && [[ ${lines[i + 1]-} =~ $re_trailer ]]; then
				continue
			fi
			gh_reject "blank line inside the body (line $((i + 1)))" \
				'write: bullets and trailers only, one blank before the trailers'
			continue
		fi

		if [[ $line =~ $re_trailer ]]; then
			key=${BASH_REMATCH[1]}
			value=${BASH_REMATCH[2]}
			in_trailers=1

			if gh_in_list "$key" "${persons[@]}"; then
				[[ $value =~ $re_person ]] ||
					gh_reject "trailer $key needs Name <email>" \
						"got:   $value" \
						'write: Claude Opus 5 <noreply@anthropic.com>'
			elif gh_in_list "$key" "${refs[@]}"; then
				[[ $value =~ $re_token ]] ||
					gh_reject "trailer $key takes one token" \
						"got:   $value" \
						'write: Refs: #42'
			else
				gh_reject "unknown trailer: $key" \
					"write: one of ${conf[trailer_person]} ${conf[trailer_reference]}"
			fi
			continue
		fi

		if ((in_trailers)); then
			gh_reject "text after a trailer (line $((i + 1)))" \
				'write: move the bullets above the trailers'
			continue
		fi

		if [[ $line == '-' ]]; then
			gh_reject "empty bullet (line $((i + 1)))" \
				'write: - say what the bullet is for'
			continue
		fi

		if [[ $line != '- '* ]]; then
			# A non-bullet line after a bullet is that bullet wrapped: one
			# point over two lines. Saying "- " here would turn one bullet
			# into two and the count would then reject it - name the wrap.
			if [[ ${lines[i - 1]} == '- '* ]]; then
				for ((j = i; j + 1 < ${#lines[@]}; j++)); do
					next=${lines[j + 1]}
					[[ -z $next ]] && break
					[[ $next == '-'* ]] && break
					[[ $next =~ $re_trailer ]] && break
				done
				prose=${lines[i - 1]}
				for ((k = i; k <= j; k++)); do
					prose+=" ${lines[k]}"
				done
				gh_reject "bullet wraps across lines $i-$((j + 1))" \
					"got:   $(gh_clip "$prose" $((conf[body_cols] - 7)))" \
					'write: one bullet per line - split the point, or cut it' \
					'       if it is a new point, start it with "- "'
				i=$j
				continue
			fi

			# Wrapped prose is one mistake, not one per line: bulleting
			# each line would cut sentences where the wrap fell.
			for ((j = i; j + 1 < ${#lines[@]}; j++)); do
				next=${lines[j + 1]}
				[[ -z $next ]] && break
				[[ $next == '-'* ]] && break
				[[ $next =~ $re_trailer ]] && break
			done

			if ((j > i)); then
				prose=$line
				for ((k = i + 1; k <= j; k++)); do
					prose+=" ${lines[k]}"
				done
				gh_reject "body is prose, not bullets (lines\
 $((i + 1))-$((j + 1)))" \
					"got:   $(gh_clip "$prose" $((conf[body_cols] - 7)))" \
					'write: - one bullet per point, rewrapped' \
					'       never one bullet per wrapped line'
				i=$j
				continue
			fi

			gh_reject "body line is not a bullet (line $((i + 1)))" \
				"got:   $line" \
				"write: - $line"
			continue
		fi

		((bullets++))
		if ((${#line} > conf[body_cols])); then
			gh_reject "bullet is ${#line} chars, max is\
 ${conf[body_cols]} (line $((i + 1)))" \
				'write: split it into two bullets, or cut it'
		fi
	done

	if ((bullets > conf[bullet_max])); then
		gh_reject "$bullets bullets, max is ${conf[bullet_max]}" \
			'write: keep the why, drop the rest'
	fi
}

gh_grade_message() {
	gh_read_message "$1"

	if ((${#lines[@]} == 0)); then
		gh_reject 'empty commit message' \
			'write: feat(hooks): add the dispatcher'
		gh_print_shape
		return
	fi

	gh_is_generated "${lines[0]}" && return 0

	gh_scope_list
	gh_grade_subject "${lines[0]}"
	gh_grade_body

	((status)) && gh_print_shape
	return 0
}

# --------------------------------------------------------------------- main

gh_usage() {
	cat <<-'USAGE'
		usage: githooks-msg.sh <file>|-   grade a commit message; - reads stdin
		       githooks-msg.sh version    print the version

		exit: 0 ok, 1 rejected, 2 usage, config or environment
	USAGE
}

gh_main() {
	(($# == 1)) || {
		gh_usage >&2
		exit 2
	}

	case $1 in
		version)
			printf '%s %s (schema %s)\n' "$prog" "$VERSION" "$SCHEMA"
			return 0
			;;
		-h | --help | help)
			gh_usage
			return 0
			;;
	esac

	# The path is the caller's, relative to where it stands; the conf and
	# every scope_root glob are relative to the root. Resolve before moving.
	local msg=$1
	[[ $msg == - || $msg == /* ]] || msg=$PWD/$msg

	gh_find_root
	cd "$root" || gh_die "cannot enter $root"
	gh_load_conf

	# A rebase replays messages it did not author. Failing them makes this
	# tool the reason you cannot rebase.
	gh_rebase_in_progress && return 0

	gh_grade_message "$msg"
	return $status
}

lines=()
scopes=()
root=''

gh_main "$@"
