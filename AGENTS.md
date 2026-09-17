# githooks — how to work here

One git-hook engine, vendored into every repo; all policy in a committed `hooks.conf`. The README is
the schema and the vendoring guide — this file is how to change the thing.

**Write terse.** Fewest words that carry the fact: prose, comments, commits, this file.

## The invariant

`bin/githooks` ships verbatim to every consumer. Per-repo behaviour goes in `hooks.conf`, or a
script it calls — never in the engine. A change that makes two copies differ is in the wrong file.

`.githooks/githooks` is this repo's own copy. `make check` and `make fmt` refresh it; never
hand-edit it.

## Errors are the product

- Every rejection says what is wrong **and what to write instead**. Only the first half is an
  unfinished feature.
- Exit 2 for usage and config, 1 only for a real rejection. A broken `hooks.conf` must never read as
  a rejected commit.
- Aggregate: grade the whole message, run every matching group. One pass, everything to fix.

## Shell

- [YSAP style](https://style.ysap.sh), bash 4.4+, `shfmt -i 0 -ci`, `shellcheck -x`,
  `set -uo pipefail` with explicit checks. No `set -e`.
- A regex with a bracket class goes in a variable: inline, `[[:space:]]` reads as the closing `]]`
  to more than one parser, `shfmt` included.
- Config values are split on whitespace, never `eval`'d. A lane that needs quoting is a script.

## Tests

- Every rule gets a fixture: a `.msg` + `.expect` in `tests/commit-msg/`, or a throwaway repo in
  `tests/run.sh`. A rule proven once is the reason this repo exists.
- `make test` green before `make release`. bats only when the harness outgrows itself.

## Commits

- Every commit lands green: `make check` runs the vendored engine over the staged set.
- `type(scope): subject`, scope from `.githooks/hooks.conf`. The hook owns the shape and prints it
  on reject — do not restate it here.
- AI co-authored: `Co-Authored-By:` naming the model. Never a session link.

## Scope

Omissions are deliberate and listed under **Not here** in the README: no lock, no self-update, no
staleness sweep, no secret scanning, no CI. Each has a recorded trigger. Bring the trigger, not the
feature.
