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

	grade bad-shape GITHOOKS_SKIP=1 >/dev/null 2>&1
	want_exit 'commit-msg GITHOOKS_SKIP passes anything' 0 $?

	# A rebase replays messages it did not author.
	git -C "$fixture_repo" rev-parse --git-path rebase-merge >/dev/null
	mkdir -p "$fixture_repo/.git/rebase-merge"
	grade bad-shape >/dev/null 2>&1
	want_exit 'commit-msg/mid-rebase grades nothing' 0 $?
	rmdir "$fixture_repo/.git/rebase-merge"
}

# ------------------------------------------------------------- dispatcher

# A throwaway repo, its conf on stdin.
mkrepo() {
	local dir
	dir=$(mktemp -d -p "$tmproot") || return 1
	git -C "$dir" init -q
	git -C "$dir" config user.email 'test@example.com'
	git -C "$dir" config user.name 'test'
	cat >"$dir/hooks.conf"
	printf '%s' "$dir"
}

# Run the engine inside a fixture repo, stderr folded in.
in_repo() {
	local dir=$1
	shift
	(cd "$dir" && GITHOOKS_CONF=$dir/hooks.conf "$engine" "$@" 2>&1)
}

case_empty_staged() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group always]
run = printf ran:%s\n always
CONF
	out=$(in_repo "$dir" pre-commit)
	want_exit 'pre-commit/empty set exits 0' 0 $?
	want_not_in 'pre-commit/empty set runs nothing' 'ran:' "$out"
}

case_match_and_paths() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
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
	mkdir -p "$dir/deep"
	printf 'x\n' >"$dir/a.sh"
	printf 'x\n' >"$dir/deep/b.sh"
	printf 'x\n' >"$dir/c.txt"
	git -C "$dir" add -A

	out=$(in_repo "$dir" pre-commit)
	want_exit 'pre-commit/matching exits 0' 0 $?
	want_in 'pre-commit/appends the matched path' 'path:a.sh' "$out"
	want_in 'pre-commit/glob crosses a slash' 'path:deep/b.sh' "$out"
	want_not_in 'pre-commit/unmatched path stays out' 'path:c.txt' "$out"
	want_not_in 'pre-commit/group with no match is skipped' 'doc:' "$out"
}

case_aggregate() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group first]
match = *.sh
run   = false

[group second]
match = *.sh
run   = printf second:%s\n
CONF
	printf 'x\n' >"$dir/a.sh"
	git -C "$dir" add -A

	out=$(in_repo "$dir" pre-commit)
	want_exit 'pre-commit/a failed lane exits 1' 1 $?
	want_in 'pre-commit/later groups still run' 'second:a.sh' "$out"
}

case_missing_tool() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group soft]
match = *.sh
run   = githooks-no-such-tool

[group hard]
match   = *.sh
require = true
run     = githooks-no-such-tool-either
CONF
	printf 'x\n' >"$dir/a.sh"
	git -C "$dir" add -A

	out=$(in_repo "$dir" pre-commit)
	want_exit 'pre-commit/require = true fails' 1 $?
	want_in 'pre-commit/a missing tool warns' 'skip' "$out"
	want_in 'pre-commit/require = true says what to install' \
		'githooks-no-such-tool-either' "$out"
}

case_deleted_path() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group shell]
match = *.sh
run   = printf path:%s\n
CONF
	printf 'x\n' >"$dir/gone.sh"
	printf 'x\n' >"$dir/kept.sh"
	git -C "$dir" add -A
	git -C "$dir" commit -qm 'init'
	git -C "$dir" rm -q gone.sh

	out=$(in_repo "$dir" pre-commit)
	want_not_in 'pre-commit/a deleted path never reaches a lane' \
		'path:gone.sh' "$out"
}

case_scope_tree() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group whole]
match = *.sh
scope = tree
run   = printf tree-ran\n
CONF
	printf 'x\n' >"$dir/a.sh"
	git -C "$dir" add -A

	out=$(in_repo "$dir" pre-commit)
	want_in 'pre-commit/scope = tree takes no paths' 'tree-ran' "$out"
	want_not_in 'pre-commit/scope = tree really takes none' 'a.sh' "$out"
}

case_fix_and_restage() {
	local dir out staged
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group shell]
match = *.sh
run   = printf check:%s\n
fix   = tests/fixtures/touch.sh
CONF
	mkdir -p "$dir/tests/fixtures"
	cat >"$dir/tests/fixtures/touch.sh" <<'FIX'
#!/usr/bin/env bash
printf 'fixed\n' >> "$1"
FIX
	chmod +x "$dir/tests/fixtures/touch.sh"
	printf 'x\n' >"$dir/a.sh"
	git -C "$dir" add a.sh

	out=$(in_repo "$dir" pre-commit --fix)
	want_exit 'pre-commit/--fix exits 0' 0 $?
	want_not_in 'pre-commit/--fix replaces run' 'check:' "$out"
	staged=$(git -C "$dir" show ':a.sh')
	want_in 'pre-commit/--fix re-stages the result' 'fixed' "$staged"
}

case_fix_refuses_partial() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group shell]
match = *.sh
run   = printf check:%s\n
fix   = true
CONF
	printf 'one\n' >"$dir/a.sh"
	git -C "$dir" add a.sh
	printf 'two\n' >>"$dir/a.sh"

	out=$(in_repo "$dir" pre-commit --fix)
	want_exit 'pre-commit/--fix refuses a partial stage' 1 $?
	want_in 'pre-commit/--fix names the partial file' 'a.sh' "$out"
}

case_check_sees_unstaged() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group shell]
match = *.sh
run   = printf path:%s\n
CONF
	printf 'x\n' >"$dir/a.sh"
	git -C "$dir" add -A
	git -C "$dir" commit -qm 'init'
	printf 'y\n' >>"$dir/a.sh"

	out=$(in_repo "$dir" check)
	want_in 'check/judges working changes, staged or not' 'path:a.sh' "$out"
}

case_check_never_stages() {
	local dir out staged
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group shell]
match = *.sh
fix   = true
run   = true
CONF
	printf 'x\n' >"$dir/a.sh"
	git -C "$dir" add -A
	git -C "$dir" commit -qm 'init'
	printf 'y\n' >>"$dir/a.sh"

	out=$(in_repo "$dir" check --fix)
	want_exit 'check/--fix exits 0' 0 $?
	staged=$(git -C "$dir" diff --cached --name-only)
	want_not_in 'check/--fix stages nothing' 'a.sh' "$staged"
}

case_check_grades_stdin() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1
types  = feat
CONF
	out=$(cd "$dir" &&
		printf 'nope\n' |
		GITHOOKS_CONF=$dir/hooks.conf "$engine" check - 2>&1)
	want_exit 'check/grades a message on stdin' 1 $?
	want_in 'check/stdin rejection says the shape' 'the shape' "$out"
}

case_symlink_skipped() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group shell]
match = *.sh
run   = printf path:%s\n
CONF
	printf 'x\n' >"$dir/a.sh"
	ln -s a.sh "$dir/link.sh"
	git -C "$dir" add -A

	out=$(in_repo "$dir" pre-commit)
	want_in 'pre-commit/a real file reaches the lane' 'path:a.sh' "$out"
	want_not_in 'pre-commit/a symlink never reaches a lane' \
		'path:link.sh' "$out"
}

case_runs_from_a_subdir() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1

[group shell]
match = *.sh
run   = printf path:%s\n
CONF
	mkdir -p "$dir/deep"
	printf 'x\n' >"$dir/deep/a.sh"
	git -C "$dir" add -A

	out=$(cd "$dir/deep" && GITHOOKS_CONF=$dir/hooks.conf "$engine" check 2>&1)
	want_in 'check/paths stay relative to the repo root' \
		'path:deep/a.sh' "$out"
}

# ------------------------------------------------------------------ config

case_conf_errors() {
	local dir out
	dir=$(mkrepo <<'CONF') || return
schema = 1
subjet_max = 72
CONF
	out=$(in_repo "$dir" check)
	want_exit 'conf/unknown key exits 2' 2 $?
	want_in 'conf/unknown key names the key' 'subjet_max' "$out"

	dir=$(mkrepo <<'CONF') || return
schema      = 1
subject_max = wide
CONF
	out=$(in_repo "$dir" check)
	want_exit 'conf/bad value exits 2' 2 $?

	dir=$(mkrepo <<'CONF') || return
schema = 99
CONF
	out=$(in_repo "$dir" check)
	want_exit 'conf/unknown schema exits 2' 2 $?
	want_in 'conf/unknown schema names the stale side' 'stale' "$out"

	dir=$(mkrepo <<'CONF') || return
[group shell
run = true
CONF
	out=$(in_repo "$dir" check)
	want_exit 'conf/malformed group header exits 2' 2 $?
}

# -------------------------------------------------------------------- main

make_fixture_repo || exit 1
run_commit_msg
run_commit_msg_output
case_empty_staged
case_match_and_paths
case_aggregate
case_missing_tool
case_deleted_path
case_scope_tree
case_fix_and_restage
case_fix_refuses_partial
case_check_sees_unstaged
case_check_never_stages
case_check_grades_stdin
case_symlink_skipped
case_runs_from_a_subdir
case_conf_errors

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
