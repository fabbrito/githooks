# githooks

Shared [lefthook](https://lefthook.dev) configs, and the commit-message grader they call. Lanes are
lefthook's; policy is a committed `lefthook.yml` and `.githooks/hooks.conf`.

Every rejection says what is wrong **and what to write instead**: the committer is usually an agent,
and prose rules in `AGENTS.md` drift while a tool that rejects does not.

```
$ git commit -m 'Add the dispatcher.'
githooks-msg: subject is not type(scope): subject
  got:   Add the dispatcher.
  write: feat(hooks): add the dispatcher

the shape:
  type(scope): subject

  - bullet
  Trailer: value

  types: feat fix refactor chore style docs build perf
```

## Use it

Install lefthook 2.1 or newer — `apt`, `brew`, `npm`, `go install`; any of
[them](https://lefthook.dev/installation/). Then, in the repo:

```yaml
# lefthook.yml
min_version: "2.1"
glob_matcher: doublestar # `**/*.sh` matches the root too

remotes:
  - git_url: https://github.com/fabbrito/githooks
    ref: v0.4.0
    configs:
      - shared/base.yml # the grader + a `lefthook validate` gate - always
      - shared/shell.yml # shfmt + shellcheck
      - shared/prettier.yml # md, json, yml, yaml
# pre-commit / check / fix jobs of your own go here
```

`.githooks/hooks.conf` beside it — start from `hooks.conf.example`. Then once per clone:

```make
hooks: ## install lefthook's hooks for this clone
	@git config --unset core.hooksPath || true
	lefthook install

check: ## the commit gate - run before committing
	lefthook run check
```

Updating is a new `ref:`. lefthook fetches the remote on first run and caches it.

## Hooks

Each shared config defines three hooks, and a repo's own jobs should follow the same split:

| Hook         | Files                                       | Formatters                          | Linters |
| ------------ | ------------------------------------------- | ----------------------------------- | ------- |
| `pre-commit` | the staged set                              | write, and re-stage (`stage_fixed`) | check   |
| `check`      | working changes vs HEAD, untracked included | check                               | check   |
| `fix`        | same as `check`                             | write, never stage                  | —       |

`--all-files` swaps the set for every tracked file: `lefthook run check --all-files` is the
whole-tree gate.

- Partially staged files are safe: lefthook hides the unstaged half while jobs run, so a formatter
  sees and re-stages only what you staged, and your unstaged edits come back untouched.
- A whole-tree formatter — prettier after its config changed, `cargo fmt --all` — checks on commit,
  never writes: `stage_fixed` re-stages staged paths only, so the rest would stay unstaged.
- Every job gets `file_types: [not symlink]`: a formatter handed a symlink fails for the wrong
  reason.
- A job a remote defines wins over a local one with the same name. Per-repo tool flags go in the
  tool's own config — `.shellcheckrc`, `.prettierrc.json` — never in a redefined job.
- `LEFTHOOK=0` skips every hook. `lefthook run commit-msg <file>` grades a message by hand.

## Exit codes

The grader: `0` ok, `1` rejected, `2` usage, config, or a broken environment, including git itself
failing. `2` is distinct on purpose: none of those judged your commit, and a `1` invites
`--no-verify` when the real problem is the machine. Lanes exit with their tool's own code.

## Message rules

`type(scope): subject`, then an optional body, then optional trailers.

- **Subject** — `type` from `types`; `scope`, when present, from the allowlist; the text
  lowercase-first with no trailing period; the whole line at most `subject_max`.
- **Body** — one blank line, then `- ` bullets and nothing else: at most `bullet_max` of them, each
  one line of at most `body_cols`. A wrapped line is not a bullet, it is the bullet above it. One
  more blank line before the trailer block is allowed: that is what git itself writes.
- **Trailers** — the allowlist is `trailer_person` plus `trailer_reference`, and nothing else.
  Person keys take `Name <email>`, reference keys take one token. Once a trailer appears, only
  trailers may follow.
- **Scopes** — `scope_fixed`, plus the basename of every directory a `scope_root` glob finds. The
  full list prints only when the rejection is an unknown scope.

Not graded: anything git wrote (`Merge `, `Revert `, `fixup!`, `squash!`, `amend!`), and **every
message during a rebase** — a rebase replays messages it did not author, and failing them would make
this tool the reason you cannot rebase.

## Config

`hooks.conf.example` is the schema document: every key, its default, and what it does. The grader
reads `.githooks/hooks.conf` from the repo root, or `GITHOOKS_CONF=<file>`.

It is parsed on every message, so a typo is exit 2 — checked harder than a formatter would. An
unknown key, a second line for a key that does not accumulate, a bad number: all exit 2, naming the
line.

`schema = 2` is the one cross-version guarantee. Absent means 1, which carried `[group]` lanes;
those moved to `lefthook.yml`, and the grader says so. A schema the grader does not know is exit 2,
naming both numbers and which side is stale.

## Versioning

Three questions, in order. The first `yes` is the bump.

- **Major** — must a consumer edit a file? A `hooks.conf` that parsed no longer parses, a command
  renamed or removed, an exit code that changes meaning.
- **Minor** — can a repo that was green go red with no edit? A new rejection, a widened one, a lane
  that runs where it did not.
- **Patch** — neither.

Pre-1.0 the major row is empty: its cases land as a minor. `1.0.0` when the feature set is stable.

## Not here

No secret scanning, no CI, no staleness sweep: nothing notices a repo pinned to an old `ref`. A
guard the shared configs cannot express — a vault check, a secret scan — is a local job calling a
script. The grader does not grow lanes back.

## Hacking

```bash
make            # the targets
make test       # the fixture harness
make check      # every lane over the whole tree, read only
make fmt        # the same lanes, writing
```

This repo's `lefthook.yml` extends `shared/` from the tree instead of a remote, so every commit here
runs the configs it publishes.

Tests are plain bash: `tests/commit-msg/<name>.msg` next to `<name>.expect` holding the expected
exit code, and cases in `tests/run.sh` that build throwaway repos. The lefthook cases publish this
tree as a tagged remote and commit through it, so what a consumer pins is what gets proven.

MIT.
