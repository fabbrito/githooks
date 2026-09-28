# githooks — how to work here

Shared lefthook configs in `shared/`, and the commit-message grader they call in
`.lefthook/commit-msg/githooks-msg.sh`. Consumers pin a tag via lefthook `remotes`. The README is
the schema and the consumer guide — this file is how to change the thing.

**Write terse.** Fewest words that carry the fact: prose, comments, commits, this file.

## The invariant

Lanes are lefthook's. `shared/` is what every consumer runs verbatim; per-repo behaviour goes in the
consumer's own `lefthook.yml` jobs or a tool's own config (`.shellcheckrc`) — never a redefined
shared job, since a remote job wins over a local one with the same name.

The grader grades messages and nothing else. It does not grow lanes back.

This repo's `lefthook.yml` extends `shared/` from the tree: every commit here runs what it
publishes.

## Errors are the product

- Every rejection says what is wrong **and what to write instead**. Only the first half is an
  unfinished feature.
- Grader: exit 2 for usage, config, or a broken environment (git failing, no repo); 1 only for a
  real rejection.
- Aggregate: grade the whole message. One pass, everything to fix.

## Shared configs

- Each file defines `pre-commit` (formatters write + `stage_fixed`, linters check), `check` (read
  only, working changes + untracked) and `fix` (writes, never stages). Keep the three in step with
  YAML anchors.
- Every job carries `file_types: [not symlink]`.
- A whole-tree formatter checks on commit, never writes: `stage_fixed` re-stages staged paths only.

## Shell

- [YSAP style](https://style.ysap.sh), bash 4.4+, `shfmt -i 0 -ci`, `shellcheck -x`,
  `set -uo pipefail` with explicit checks. No `set -e`.
- A regex with a bracket class goes in a variable: inline, `[[:space:]]` reads as the closing `]]`
  to more than one parser, `shfmt` included.
- Grader functions carry a `gh_` prefix.

## Tests

- Test our code and our composition, not lefthook's mechanics (stashing, chunking, globbing).
- Every message rule gets a `.msg` + `.expect` in `tests/commit-msg/`. Every choice `shared/`
  encodes — which hook writes, which stages, the file set — gets a case in `tests/run.sh` that
  commits through the tree published as a remote.
- `make test` green before `make release`. bats only when the harness outgrows itself.

## Commits

- Every commit lands green: lefthook's `pre-commit` runs `shared/` over the staged set. `make check`
  runs the same lanes over the whole tree.
- `type(scope): subject`, scope from `.githooks/hooks.conf`. The hook owns the shape and prints it
  on reject — do not restate it here.
- AI co-authored: `Co-Authored-By:` naming the model. Never a session link.

## Scope

Omissions are deliberate and listed under **Not here** in the README. Bring the trigger, not the
feature.
