#!/usr/bin/env bash
#
# The whole harness. Plain bash and fixtures; bats only if this outgrows
# itself.
#
#   tests/commit-msg/<name>.msg + <name>.expect   expected exit code
#   tests/pre-commit/                             throwaway repos, built here
#
# No errexit: a failing case is the point, not a reason to stop.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# A git hook exports GIT_DIR, GIT_INDEX_FILE and friends. If this harness ever
# runs from inside one, they would point every `git -C <tmpdir>` back at the
# real repository. Drop them before touching git at all.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_NAMESPACE
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

engine=$PWD/bin/githooks
tmproot=$(mktemp -d) || exit 1
trap 'rm -rf "$tmproot"' EXIT

passed=0
failed=0

green=''
red=''
reset=''
if [[ -t 1 ]]; then
	green=$'\033[0;32m'
	red=$'\033[0;31m'
	reset=$'\033[0m'
fi

ok() {
	printf '%sok%s   %s\n' "$green" "$reset" "$*"
	((passed++))
}

no() {
	printf '%sFAIL%s %s\n' "$red" "$reset" "$1"
	shift
	local line
	for line in "$@"; do
		printf '       %s\n' "$line"
	done
	((failed++))
}

want_exit() {
	local name=$1 want=$2 got=$3
	if ((want == got)); then
		ok "$name"
		return 0
	fi
	no "$name" "want exit $want, got $got"
	return 1
}

want_in() {
	local name=$1 needle=$2 haystack=$3
	if [[ $haystack == *"$needle"* ]]; then
		ok "$name"
		return 0
	fi
	no "$name" "missing: $needle" "output: $haystack"
	return 1
}

want_not_in() {
	local name=$1 needle=$2 haystack=$3
	if [[ $haystack != *"$needle"* ]]; then
		ok "$name"
		return 0
	fi
	no "$name" "unexpected: $needle" "output: $haystack"
	return 1
}

# ------------------------------------------------------------- commit-msg

# Grading is pure text in, exit code out - but the engine locates hooks.conf
# with `rev-parse --show-toplevel` and skips a message mid-rebase, so it must
# run inside a repo. Its own, never this one: a rebase in progress here would
# otherwise pass every fixture.
fixture_repo=''
repo=''

make_fixture_repo() {
	fixture_repo=$(mktemp -d -p "$tmproot") || return 1
	git -C "$fixture_repo" init -q
	mkdir -p "$fixture_repo/tests"
	cp -r tests/commit-msg "$fixture_repo/tests/commit-msg"
}

# grade <name> [VAR=value ...]
grade() {
	local name=$1
	shift
	(cd "$fixture_repo" &&
		GITHOOKS_CONF=$fixture_repo/tests/commit-msg/hooks.conf \
			env "$@" "$engine" commit-msg "tests/commit-msg/$name.msg" 2>&1)
}

run_commit_msg() {
	local msg want got name
	for msg in tests/commit-msg/*.msg; do
		name=${msg##*/}
		name=${name%.msg}
		want=$(<"tests/commit-msg/$name.expect")
		grade "$name" >/dev/null 2>&1
		got=$?
		want_exit "commit-msg/$name" "$want" "$got"
	done
}

# Rejections must say what to write, not just what is wrong.
run_commit_msg_output() {
	local out
	out=$(grade bad-scope)
	want_in 'commit-msg/bad-scope names the scopes' 'alpha' "$out"

	out=$(grade bad-period)
	want_not_in 'commit-msg/bad-period stays quiet about scopes' \
		'scopes:' "$out"

	# Wrapped prose is one rejection, not one per line.
	out=$(grade bad-prose-body)
	want_in 'commit-msg/bad-prose-body names the run' \
		'body is prose, not bullets (lines 3-5)' "$out"
	want_not_in 'commit-msg/bad-prose-body rejects once' \
		'is not a bullet' "$out"

	grade bad-shape GITHOOKS_SKIP=1 >/dev/null 2>&1
	want_exit 'commit-msg GITHOOKS_SKIP passes anything' 0 $?

	# A rebase replays messages it did not author.
	mkdir -p "$fixture_repo/.git/rebase-merge"
	grade bad-shape >/dev/null 2>&1
	want_exit 'commit-msg/mid-rebase grades nothing' 0 $?
	rmdir "$fixture_repo/.git/rebase-merge"
}

# ------------------------------------------------------------- dispatcher

# A throwaway repo in $repo, its conf read from stdin. Not a command
# substitution: a heredoc inside $( ) has its body outside it, which bash
# warns about and then guesses at.
#
# Every body here is `<<-`, which strips leading tabs only. A fixture line
# that must keep its indentation indents with spaces.
mkrepo() {
	repo=$(mktemp -d -p "$tmproot") || return 1
	git -C "$repo" init -q
	git -C "$repo" config user.email 'test@example.com'
	git -C "$repo" config user.name 'test'
	cat >"$repo/hooks.conf"
}

# Run the engine inside the current fixture repo, stderr folded in.
in_repo() {
	(cd "$repo" && GITHOOKS_CONF=$repo/hooks.conf "$engine" "$@" 2>&1)
}

# `commit --amend --no-edit` stages nothing. A staged lane has nothing to
# hand a formatter; every tree lane runs, `match` or not - a match filters
# what changed and nothing did, while the invariant holds regardless. Going
# quiet there is how a require = true group stops guarding unnoticed.
case_empty_staged() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group whole]
		scope = tree
		run   = printf ran-tree\n

		[group narrow]
		match = *.rs
		scope = tree
		run   = printf ran-narrow\n

		[group paths]
		scope = staged
		run   = printf ran-staged:%s\n
	CONF
	out=$(in_repo pre-commit)
	want_exit 'pre-commit/empty set exits 0' 0 $?
	want_in 'pre-commit/a tree lane runs on an empty set' 'ran-tree' "$out"
	want_in 'pre-commit/a matched tree lane runs on an empty set' \
		'ran-narrow' "$out"
	want_not_in 'pre-commit/a staged lane is never run pathless' \
		'ran-staged' "$out"
}

# The consumer case: an invariant lane on a tree with nothing to commit.
case_check_clean_tree() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group whole]
		scope   = tree
		require = true
		run     = printf tree-ran\n

		[group narrow]
		match   = *.sh
		scope   = tree
		require = true
		run     = printf narrow-ran\n
	CONF
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'init'

	out=$(in_repo check)
	want_exit 'check/a clean tree exits 0' 0 $?
	want_in 'check/a tree lane runs on a clean tree' 'tree-ran' "$out"
	want_in 'check/a matched tree lane runs on a clean tree' \
		'narrow-ran' "$out"
}

# The other half of the rule: `match` still filters once something did
# change. A tree lane narrow enough to be cheap stays out of an unrelated
# commit - that is the only reason to give one a `match`.
case_tree_match_filters() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group narrow]
		match = *.rs
		scope = tree
		run   = printf narrow-ran\n
	CONF
	printf 'x\n' >"$repo/a.rs"
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'init'
	printf 'doc\n' >"$repo/README.md"
	git -C "$repo" add -A

	out=$(in_repo pre-commit)
	want_exit 'pre-commit/an unmatched change exits 0' 0 $?
	want_not_in 'pre-commit/a matched tree lane skips an unmatched change' \
		'narrow-ran' "$out"
}

# A deletion is not in the changed set, so it cannot reach a lane as an
# argument - but it still changed the tree. A tree lane's `match` is a
# trigger, and removing a file is when its invariant is most likely broken.
# The unmatched edit is the point: without it the set is empty and the lane
# would run for the other reason.
case_tree_match_deletion() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group narrow]
		match = *.rs
		scope = tree
		run   = printf narrow-ran\n

		[group paths]
		match = *.rs
		scope = staged
		run   = printf path:%s\n
	CONF
	printf 'x\n' >"$repo/a.rs"
	printf 'doc\n' >"$repo/README.md"
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'init'
	git -C "$repo" rm -q a.rs
	printf 'more\n' >>"$repo/README.md"

	out=$(in_repo check)
	want_in 'check/a deletion triggers a matched tree lane' \
		'narrow-ran' "$out"

	git -C "$repo" add -A
	out=$(in_repo pre-commit)
	want_exit 'pre-commit/a deletion exits 0' 0 $?
	want_in 'pre-commit/a deletion triggers a matched tree lane' \
		'narrow-ran' "$out"
	want_not_in 'pre-commit/a deletion never reaches a staged lane' \
		'path:a.rs' "$out"
}

case_match_and_paths() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		scope = staged
		run   = printf path:%s\n

		[group docs]
		match = *.md
		scope = staged
		run   = printf doc:%s\n
	CONF
	mkdir -p "$repo/deep"
	printf 'x\n' >"$repo/a.sh"
	printf 'x\n' >"$repo/deep/b.sh"
	printf 'x\n' >"$repo/c.txt"
	git -C "$repo" add -A

	out=$(in_repo pre-commit)
	want_exit 'pre-commit/matching exits 0' 0 $?
	want_in 'pre-commit/appends the matched path' 'path:a.sh' "$out"
	want_in 'pre-commit/glob crosses a slash' 'path:deep/b.sh' "$out"
	want_not_in 'pre-commit/unmatched path stays out' 'path:c.txt' "$out"
	want_not_in 'pre-commit/group with no match is skipped' 'doc:' "$out"
}

case_aggregate() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group first]
		match = *.sh
		run   = false

		[group second]
		match = *.sh
		run   = printf second:%s\n
	CONF
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A

	out=$(in_repo pre-commit)
	want_exit 'pre-commit/a failed lane exits 1' 1 $?
	want_in 'pre-commit/later groups still run' 'second:a.sh' "$out"
}

case_missing_tool() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group soft]
		match = *.sh
		run   = githooks-no-such-tool

		[group hard]
		match   = *.sh
		require = true
		run     = githooks-no-such-tool-either
	CONF
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A

	out=$(in_repo pre-commit)
	want_exit 'pre-commit/require = true fails' 1 $?
	want_in 'pre-commit/a missing tool warns' 'skip' "$out"
	want_in 'pre-commit/require = true says what to install' \
		'githooks-no-such-tool-either' "$out"
}

case_deleted_path() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = printf path:%s\n
	CONF
	printf 'x\n' >"$repo/gone.sh"
	printf 'x\n' >"$repo/kept.sh"
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'init'
	git -C "$repo" rm -q gone.sh

	out=$(in_repo pre-commit)
	want_not_in 'pre-commit/a deleted path never reaches a lane' \
		'path:gone.sh' "$out"
}

case_scope_tree() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group whole]
		match = *.sh
		scope = tree
		run   = printf tree-ran\n
	CONF
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A

	out=$(in_repo pre-commit)
	want_in 'pre-commit/scope = tree takes no paths' 'tree-ran' "$out"
	want_not_in 'pre-commit/scope = tree really takes none' 'a.sh' "$out"
}

case_fix_and_restage() {
	local out staged
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = printf check:%s\n
		fix   = tests/fixtures/touch.sh
	CONF
	mkdir -p "$repo/tests/fixtures"
	cat >"$repo/tests/fixtures/touch.sh" <<-'FIX'
		#!/usr/bin/env bash
		printf 'fixed\n' >> "$1"
	FIX
	chmod +x "$repo/tests/fixtures/touch.sh"
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add a.sh

	out=$(in_repo pre-commit --fix)
	want_exit 'pre-commit/--fix exits 0' 0 $?
	want_not_in 'pre-commit/--fix replaces run' 'check:' "$out"
	staged=$(git -C "$repo" show ':a.sh')
	want_in 'pre-commit/--fix re-stages the result' 'fixed' "$staged"
}

# A fixer that rewrote the file and then failed has left something nobody
# asked for. Staging it makes the index differ from what you staged, on the
# one path where the commit is refused anyway.
case_fix_failure_never_stages() {
	local out staged
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = true
		fix   = tests/fixtures/halfway.sh
	CONF
	mkdir -p "$repo/tests/fixtures"
	cat >"$repo/tests/fixtures/halfway.sh" <<-'FIX'
		#!/usr/bin/env bash
		printf 'half\n' >"$1"
		exit 3
	FIX
	chmod +x "$repo/tests/fixtures/halfway.sh"
	printf 'whole\n' >"$repo/a.sh"
	git -C "$repo" add a.sh

	out=$(in_repo pre-commit --fix)
	want_exit 'pre-commit/--fix with a failing fixer exits 1' 1 $?
	staged=$(git -C "$repo" show ':a.sh')
	want_in 'pre-commit/a failed fixer leaves the index alone' \
		'whole' "$staged"
	want_not_in 'pre-commit/a failed fixer stages nothing' 'half' "$staged"
}

case_fix_refuses_partial() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = printf check:%s\n
		fix   = true
	CONF
	printf 'one\n' >"$repo/a.sh"
	git -C "$repo" add a.sh
	printf 'two\n' >>"$repo/a.sh"

	out=$(in_repo pre-commit --fix)
	want_exit 'pre-commit/--fix refuses a partial stage' 1 $?
	want_in 'pre-commit/--fix names the partial file' 'a.sh' "$out"
}

case_check_sees_unstaged() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = printf path:%s\n
	CONF
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'init'
	printf 'y\n' >>"$repo/a.sh"

	out=$(in_repo check)
	want_in 'check/judges working changes, staged or not' 'path:a.sh' "$out"
}

case_check_sees_untracked() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = printf path:%s\n
	CONF
	printf 'ignored.sh\n' >"$repo/.gitignore"
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'init'
	printf 'y\n' >"$repo/new.sh"
	printf 'z\n' >"$repo/ignored.sh"

	out=$(in_repo check)
	want_in 'check/judges an untracked file' 'path:new.sh' "$out"
	want_not_in 'check/an ignored file stays out' 'path:ignored.sh' "$out"

	out=$(in_repo pre-commit)
	want_not_in 'pre-commit/an untracked file is not staged' \
		'path:new.sh' "$out"
}

case_check_never_stages() {
	local out staged
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		fix   = true
		run   = true
	CONF
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'init'
	printf 'y\n' >>"$repo/a.sh"

	out=$(in_repo check --fix)
	want_exit 'check/--fix exits 0' 0 $?
	staged=$(git -C "$repo" diff --cached --name-only)
	want_not_in 'check/--fix stages nothing' 'a.sh' "$staged"
}

case_check_grades_stdin() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1
		types  = feat
	CONF
	out=$(cd "$repo" &&
		printf 'nope\n' |
		GITHOOKS_CONF=$repo/hooks.conf "$engine" check - 2>&1)
	want_exit 'check/grades a message on stdin' 1 $?
	want_in 'check/stdin rejection says the shape' 'the shape' "$out"
}

case_symlink_skipped() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = printf path:%s\n
	CONF
	printf 'x\n' >"$repo/a.sh"
	ln -s a.sh "$repo/link.sh"
	git -C "$repo" add -A

	out=$(in_repo pre-commit)
	want_in 'pre-commit/a real file reaches the lane' 'path:a.sh' "$out"
	want_not_in 'pre-commit/a symlink never reaches a lane' \
		'path:link.sh' "$out"
}

case_runs_from_a_subdir() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = printf path:%s\n
	CONF
	mkdir -p "$repo/deep"
	printf 'x\n' >"$repo/deep/a.sh"
	git -C "$repo" add -A

	out=$(cd "$repo/deep" && GITHOOKS_CONF=$repo/hooks.conf "$engine" check 2>&1)
	want_in 'check/paths stay relative to the repo root' \
		'path:deep/a.sh' "$out"
}

case_no_match_runs_always() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group always]
		run = printf ran\\n
	CONF
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A

	out=$(in_repo pre-commit)
	want_in 'pre-commit/a group with no match always runs' 'ran' "$out"
}

case_lane_failure_names_the_fixer() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1

		[group shell]
		match = *.sh
		run   = false
		fix   = true
	CONF
	printf 'x\n' >"$repo/a.sh"
	git -C "$repo" add -A

	out=$(in_repo pre-commit)
	want_exit 'pre-commit/a failed lane exits 1' 1 $?
	want_in 'pre-commit/a failed lane names the fixer' '--fix' "$out"
}

# Regression: `die` used to run inside $(git_root), so it exited that subshell
# and the engine carried on with an empty root and passed the commit.
case_outside_a_repo() {
	local dir out
	dir=$(mktemp -d -p "$tmproot") || return
	printf 'schema = 1\n' >"$dir/hooks.conf"

	out=$(cd "$dir" && GITHOOKS_CONF=$dir/hooks.conf "$engine" pre-commit 2>&1)
	want_exit 'engine/outside a repo exits 2' 2 $?
	want_in 'engine/outside a repo says so' 'not inside a git repository' "$out"
}

case_cli_surface() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1
	CONF
	out=$(in_repo version)
	want_exit 'cli/version exits 0' 0 $?
	want_in 'cli/version names the schema' 'schema' "$out"

	in_repo >/dev/null 2>&1
	want_exit 'cli/no arguments exits 2' 2 $?

	in_repo not-a-command >/dev/null 2>&1
	want_exit 'cli/an unknown command exits 2' 2 $?

	in_repo commit-msg >/dev/null 2>&1
	want_exit 'cli/commit-msg with no file exits 2' 2 $?

	in_repo pre-commit --nope >/dev/null 2>&1
	want_exit 'cli/an unknown flag exits 2' 2 $?
}

# ------------------------------------------------------------------ config

case_conf_errors() {
	local out
	mkrepo <<-'CONF' || return
		schema = 1
		subjet_max = 72
	CONF
	out=$(in_repo check)
	want_exit 'conf/unknown key exits 2' 2 $?
	want_in 'conf/unknown key names the key' 'subjet_max' "$out"

	mkrepo <<-'CONF' || return
		schema      = 1
		subject_max = wide
	CONF
	out=$(in_repo check)
	want_exit 'conf/bad value exits 2' 2 $?

	mkrepo <<-'CONF' || return
		schema = 99
	CONF
	out=$(in_repo check)
	want_exit 'conf/unknown schema exits 2' 2 $?
	want_in 'conf/unknown schema names the stale side' 'stale' "$out"

	mkrepo <<-'CONF' || return
		[group shell
		run = true
	CONF
	out=$(in_repo check)
	want_exit 'conf/malformed group header exits 2' 2 $?

	# A second `match` replaced the first and the lane went quiet - the one
	# config typo nothing downstream can catch.
	mkrepo <<-'CONF' || return
		schema = 1

		[group two]
		match = *.aaa
		match = *.bbb
		scope = staged
		run   = true
	CONF
	out=$(in_repo check)
	want_exit 'conf/a duplicate key exits 2' 2 $?
	want_in 'conf/a duplicate key names both lines' 'first at line 4' "$out"
	want_in 'conf/a duplicate key says what to write' \
		'write one match line' "$out"

	mkrepo <<-'CONF' || return
		schema      = 1
		subject_max = 72
		subject_max = 80
	CONF
	out=$(in_repo check)
	want_exit 'conf/a duplicate top-level key exits 2' 2 $?

	# `run` still stacks, and one key per group is per *group*: two groups
	# each write their own. `scope_root` accumulating is the commit-msg
	# fixture conf, which derives its scopes from two of them.
	mkrepo <<-'CONF' || return
		schema = 1

		[group one]
		match = *.aaa
		scope = tree
		run   = printf one\n
		run   = printf two\n

		[group other]
		match = *.bbb
		scope = tree
		run   = printf three\n
	CONF
	printf 'x\n' >"$repo/f.aaa"
	printf 'x\n' >"$repo/f.bbb"
	out=$(in_repo check)
	want_exit 'conf/accumulating keys still accumulate' 0 $?
	want_in 'conf/every run line runs' 'two' "$out"
	want_in 'conf/each group writes its own match' 'three' "$out"
}

# -------------------------------------------------------------------- main

make_fixture_repo || exit 1
run_commit_msg
run_commit_msg_output
case_empty_staged
case_check_clean_tree
case_tree_match_filters
case_tree_match_deletion
case_match_and_paths
case_aggregate
case_missing_tool
case_deleted_path
case_scope_tree
case_fix_and_restage
case_fix_failure_never_stages
case_fix_refuses_partial
case_check_sees_unstaged
case_check_sees_untracked
case_check_never_stages
case_check_grades_stdin
case_symlink_skipped
case_runs_from_a_subdir
case_no_match_runs_always
case_lane_failure_names_the_fixer
case_outside_a_repo
case_cli_surface
case_conf_errors

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
