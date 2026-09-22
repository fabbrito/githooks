# githooks

One git-hook engine, vendored like a C dependency: the same file in every repo, all variation in a
committed `hooks.conf`.

It grades commit messages and runs lanes over the files you are about to commit. Every rejection
says what is wrong **and what to write instead**: the committer is usually an agent, and prose rules
in `AGENTS.md` drift while a tool that rejects does not.

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

Take `bin/githooks` from [the repo](https://github.com/fabbrito/githooks) at the tag you want and
put it in `.githooks/githooks`, executable. How you fetch it is yours: `curl`, `gh`, a copy out of a
local clone.

Then `hooks.conf` beside it — start from `hooks.conf.example` — and two shims, identical in every
repo:

```bash
# .githooks/commit-msg
#!/usr/bin/env bash
# Vendored from fabbrito/githooks; edit hooks.conf, not this.
set -uo pipefail
exec "$(dirname "$0")/githooks" commit-msg "$@"
```

`.githooks/pre-commit` is the same line with `pre-commit "$@"`. Commit all four files.

Updating is the same again at a newer tag. No lock file, no self-update: see [Not here](#not-here).

## Enable it

Hooks do not travel with a clone, so something has to run this once:

```bash
git config core.hooksPath .githooks
```

Your repo's call, not the engine's. Pick whatever already exists:

```make
hooks: ## enable .githooks for this clone
	git config core.hooksPath .githooks

check: ## commit gate - run before committing
	.githooks/githooks check
```

Make `hooks` a prerequisite of the target people already run (`deps`, `bootstrap`, `test`) and a
fresh clone is covered without anyone remembering. A node repo uses `prepare`.

## Commands

| Command                              | Does                                                                                                                                     |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `githooks commit-msg <file>`         | Grade the message at `$1`. Called by the shim.                                                                                           |
| `githooks pre-commit [--fix]`        | Run lanes over the staged set, refusing when the worktree diverges from it. Called by the shim.                                          |
| `githooks check [--fix] [<file>\|-]` | The gate for humans and agents: lanes over working changes, untracked files included, plus a message when one is given. `-` reads stdin. |
| `githooks version`                   | Print the version and schema.                                                                                                            |
| `githooks help`, `-h`, `--help`      | Print the command list.                                                                                                                  |

Exit codes: `0` ok, `1` rejected or a lane failed, `2` usage, config, or a broken environment,
including git itself failing. `2` is distinct on purpose: none of those judged your commit, and a
`1` invites `--no-verify` when the real problem is the machine.

`GITHOOKS_SKIP=1` passes either hook command; `check` is not a hook and does not honor it.
`GITHOOKS_CONF=<file>` points at another config, which is how the tests run.

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
  full list prints only when the rejection is an unknown scope.

Not graded: anything git wrote (`Merge `, `Revert `, `fixup!`, `squash!`, `amend!`), and **every
message during a rebase** — a rebase replays messages it did not author, and failing them would make
this tool the reason you cannot rebase.

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
- The staged set never includes deletions or symlinks: neither has content a lane can read, and
  handing one to a formatter fails for the wrong reason. A deletion still triggers a matched `tree`
  lane, which takes no paths anyway — removing a file is when its invariant is most likely broken.
- An empty staged set (`commit --amend --no-edit`) runs no `staged` lane — there is nothing to hand
  it. Every `tree` lane still runs, `match` or not: a `match` filters what changed and nothing did,
  while the invariant does not. That is the lane you least want going quiet.
- `run`, `fix` and `scope_root` take a line each and accumulate. Every other key is written once,
  and a second line is exit 2 naming the first — a replaced `match` narrows a lane into silence,
  which nothing downstream can catch.
- A missing command warns and skips. `require = true` makes it fail instead.
- The first word resolves against `PATH`, never the engine: internal functions carry a `gh_` prefix,
  so a conf naming one reads as a missing command rather than calling in-process.
- Commands are exec'd as written, split on whitespace: no quoting, no redirection, no pipeline, no
  glob expansion, and the lane inherits the caller's stdin, stdout and stderr. Needing any of those
  means a script the lane calls.
- Those inherited descriptors are git's, or your harness's: no terminal, and sometimes non-blocking.
  A tool that refuses them is your script's problem to solve — open fresh handles in the wrapper.
  The engine hands its lanes what it was given and does not launder it.

`--fix` swaps `run` for `fix`. Under `pre-commit --fix` the matched paths are re-staged — the only
thing this tool mutates — and it **refuses** when one of them has both staged and unstaged changes,
rather than swallowing the half you left out. That holds at every scope: a `tree` lane reads the
worktree freely, but it never stages bytes you did not.

`pre-commit` grades the **index**, but a lane opens a path in the **worktree**. Where the two
disagree for a path a lane would read — staged then edited, or staged then deleted — it refuses
rather than grade bytes nobody staged: `git add` them, or `git stash push` them, then retry. The
refusal is per group, so a dirty file no lane reads never blocks the commit. `check` judges the
worktree by contract and never refuses; `check --fix` formats but never stages, since staging those
files would make a decision you have not made.

Anything the config cannot express — a vault guard, a secret scan — is a script it calls, or a
native `pre-commit` that runs the engine and then its own guard. The format does not grow
conditionals.

## Config

`hooks.conf.example` is the schema document: every key, its default, and what it does.

`hooks.conf` needs no lane of its own. It is parsed on every run, so a typo is exit 2 before any
lane starts — checked harder than a formatter would.

`schema = N` is the one cross-version guarantee. Absent means 1. A schema this engine does not know
is exit 2, naming both numbers and which side is stale. Inside a schema it knows, an unknown key is
a typo rather than a future feature, so that is exit 2 as well.

## Versioning

Three questions, in order. The first `yes` is the bump.

- **Major** — must a consumer edit a file? A `hooks.conf` that parsed no longer parses, a command
  renamed or removed, an exit code that changes meaning.
- **Minor** — can a repo that was green go red with no edit? A new rejection, a widened one, a lane
  that runs where it did not.
- **Patch** — neither.

Pre-1.0 the major row is empty: its cases land as a minor. `1.0.0` when the feature set is stable.

## Not here

No lock file, no integrity check, no self-update, no staleness sweep, no CI. Every copy is bumped by
hand, and nothing notices a repo sitting on an old engine. Deliberate: a lock would only catch
hand-edits, and a stale-but-intact copy passes any check that does not go to the network. It comes
back when a bump actually hurts.

Also not planned: secret scanning, parallel lanes, caching, per-language adapters, a hook installer.
Two repos needing the middle three is the signal to adopt
[lefthook](https://github.com/evilmartians/lefthook) instead.

## Hacking

```bash
make            # the targets
make test       # the fixture harness
make check      # the staging gate, via the vendored copy
make fmt        # the same lanes, writing
```

`bin/githooks` is the source; `.githooks/githooks` is this repo's vendored copy, so the repo is its
own first consumer. `make check` and `make fmt` run the copy and refresh it first — if the two ever
disagree, that is the bug this layout exists to surface.

Tests are plain bash: `tests/commit-msg/<name>.msg` next to `<name>.expect` holding the expected
exit code, and dispatcher cases building throwaway repos in `tests/run.sh`. A rule is written once
and proven once.

MIT.
