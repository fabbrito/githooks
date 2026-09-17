# githooks

One git-hook engine, vendored like a C dependency: the same file in every repo, all variation in a
committed `hooks.conf`.

It does two things. It grades commit messages, and it runs lanes over the files you are about to
commit. Every rejection says what is wrong **and what to write instead**, because the committer is
usually an agent, and prose rules in `AGENTS.md` drift while a tool that rejects does not.

```
$ git commit -m 'Add the dispatcher.'
githooks: subject is not type(scope): subject
  got:   Add the dispatcher.
  write: feat(hooks): add the dispatcher

the shape:
  type(scope): subject

  - bullet
  Trailer: value

  types: feat fix refactor chore style docs build perf
```

## Vendor it

```bash
mkdir -p .githooks
curl -fsSL https://raw.githubusercontent.com/fabbrito/githooks/v1.0.0/bin/githooks \
  -o .githooks/githooks
chmod +x .githooks/githooks
cp /path/to/githooks/hooks.conf.example .githooks/hooks.conf   # then edit it
```

Two shims, identical in every repo:

```bash
# .githooks/commit-msg
#!/usr/bin/env bash
# Vendored from fabbrito/githooks; edit hooks.conf, not this.
set -uo pipefail
exec "$(dirname "$0")/githooks" commit-msg "$@"
```

`.githooks/pre-commit` is the same line with `pre-commit "$@"`. Commit all four files.

Updating is the same `curl` at a newer tag. There is no lock file and no self-update: see
[Not here](#not-here).

## Enable it

Hooks do not travel with a clone, so something has to run this once:

```bash
git config core.hooksPath .githooks
```

That is your repo's call, not the engine's. Pick whatever already exists:

```make
hooks: ## enable .githooks for this clone
	git config core.hooksPath .githooks

check: ## commit gate - run before committing
	.githooks/githooks check
```

Make `hooks` a prerequisite of the target people already run (`deps`, `bootstrap`, `test`) and a
fresh clone is covered without anyone remembering. A node repo can put it in `prepare`.

## Commands

| Command                              | Does                                                                                                           |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `githooks commit-msg <file>`         | Grade the message at `$1`. Called by the shim.                                                                 |
| `githooks pre-commit [--fix]`        | Run lanes over the staged set. Called by the shim.                                                             |
| `githooks check [--fix] [<file>\|-]` | The gate for humans and agents: lanes over working changes, plus a message when one is given. `-` reads stdin. |
| `githooks version`                   | Print the version and schema.                                                                                  |

Exit codes: `0` ok, `1` rejected or a lane failed, `2` usage or config error. `2` is distinct on
purpose, so a broken `hooks.conf` is never mistaken for a rejected commit.

`GITHOOKS_SKIP=1` passes anything. `GITHOOKS_CONF=<file>` points at another config, which is how the
tests run.

## Message rules

`type(scope): subject`, then an optional body, then optional trailers.

- **Subject** — `type` from `types`; `scope`, when present, from the allowlist; the text
  lowercase-first with no trailing period; the whole line at most `subject_max`.
- **Body** — one blank line, then `- ` bullets and nothing else: at most `bullet_max` of them, each
  at most `body_cols`. One more blank line before the trailer block is allowed: that is what git
  itself writes.
- **Trailers** — the allowlist is `trailer_person` plus `trailer_reference`, and nothing else.
  Person keys take `Name <email>`, reference keys take one token. Once a trailer appears, only
  trailers may follow.
- **Scopes** — `scope_fixed`, plus the basename of every directory a `scope_root` glob finds. The
  full list is printed only when the rejection is an unknown scope; the rest of the time it would be
  noise.

Not graded at all: anything git wrote (`Merge `, `Revert `, `fixup!`, `squash!`, `amend!`), and
**every message during a rebase**. A rebase replays messages it did not author, and failing them
would make this tool the reason you cannot rebase.

## Lanes

```
[group shell]
match   = *.sh .githooks/githooks
scope   = staged
require = true
run     = shfmt -i 0 -ci -d
fix     = shfmt -i 0 -ci -w
run     = shellcheck -x
```

- A group runs when any changed path matches a `match` glob; no `match` means always.
- Globs are shell `case` patterns, so `*` crosses `/`. `*.sh` matches `deep/b.sh`.
- `scope = staged` appends the matched paths to each command; `tree` runs it as written.
- Groups run in order, **every** matching group runs even after one fails, and the status aggregates
  — one pass shows you everything to fix.
- The staged set never includes deletions, so a deleted file is not handed to a formatter.
- An empty staged set (`commit --amend --no-edit`) runs nothing and exits 0.
- A missing command warns and skips. `require = true` makes it fail instead.
- Commands are split on whitespace, with no quoting. If you need quoting, call a script.

`--fix` swaps `run` for `fix`. Under `pre-commit --fix` the matched paths are re-staged, which is
the only thing this tool ever mutates — and it **refuses** when a matched file has both staged and
unstaged changes, rather than swallowing the half you left out. `check --fix` formats but never
stages: those files were never staged, and staging them would make a decision you have not made.

Anything the config cannot express — a vault guard, a secret scan — is a script the config calls, or
a native `pre-commit` that runs the engine and then its own guard. The format does not grow
conditionals.

## Config

`hooks.conf.example` is the schema document: every key, its default, and what it does.

`schema = N` is the one cross-version guarantee. Absent means 1. A schema this engine does not know
is exit 2, naming both numbers and which side is stale. Inside a schema it knows, an unknown key is
a typo rather than a future feature, so that is exit 2 as well.

## Not here

No lock file, no integrity check, no self-update, no staleness sweep, no CI. Every copy is bumped by
hand, and nothing notices a repo sitting on an old engine. That is a deliberate cut, not an
oversight: a lock would only catch hand-edits, and a stale-but-intact copy passes any check that
does not go to the network. It comes back when a bump actually hurts.

Also not here, and not planned: secret scanning, parallel lanes, caching, per-language adapters, a
hook installer. Two repos needing the middle three is the signal to adopt
[lefthook](https://github.com/evilmartians/lefthook) instead.

## Hacking

```bash
make            # the targets
make test       # the fixture harness
make check      # the staging gate, via the vendored copy
make fmt        # the same lanes, writing
```

`bin/githooks` is the source; `.githooks/githooks` is this repo's vendored copy of it, so the repo
is its own first consumer. `make check` and `make fmt` run the copy, and both refresh it first — if
they ever disagree with `bin/`, that is the bug this layout exists to surface.

Tests are plain bash: `tests/commit-msg/<name>.msg` next to `<name>.expect` holding the expected
exit code, and dispatcher cases that build throwaway repos in `tests/run.sh`. A rule is written once
and proven once.

MIT.
