# Agent instructions

## Version Control

This repository uses Jujutsu (`jj`) locally with GitHub as the canonical remote.

- Use `jj status` and `jj diff` before editing.
- Do not run `git add`, `git commit`, or `git rebase`.
- Prefer `jj describe`, `jj commit`, `jj split`, and `jj squash`.
- Before major edits, run `jj new main` or create a new change from the current base.
- After edits, run tests and summarize changed files.
- Do not push directly to `main`.
- Push via a named `jj` bookmark and open a GitHub PR.

## Multi-Agent File Parity & Symlinks

- Whenever creating or editing agent instructions, skills, or sub-project rules, relative symlinks must always be put in place between `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` (e.g., `ln -sf AGENTS.md GEMINI.md`) so Codex, Claude, and Gemini remain perfectly in sync.
- Never create standalone divergent instruction files for one tool without linking or mirroring them across all agent formats.


Notes for AI coding agents working in this repository. Humans want
[CONTRIBUTING.md](CONTRIBUTING.md) instead — everything about building, testing
and raising a PR lives there and is not repeated here.

## Standing agent instructions

### Follow-ups become GitHub issues

Any finding worth acting on later is filed as a GitHub issue before the work is
reported done. Not a line in a summary, not a PR comment, not chat scrollback.
If it is worth saying "someone should look at this later", it is worth an issue.

### Verify before claiming

The self tests are `precondition` calls behind `--self-test`; a build that
compiles proves nothing about behaviour. Run the build *and* the self tests, and
paste the real output rather than describing it.

### Operational facts about this repository's CI

- **A cancelled build poisons its commit.** A cancelled job leaves a `FAILURE`
  check run that a later `SUCCESS` from a replacement run does **not** supersede.
  The rollup stays `FAILURE` and the PR stays blocked with auto-merge armed and
  never firing. Clear it with `gh run rerun <cancelled-run-id> --failed`. This is
  why `pr-title-lint` sets `cancel-in-progress: false` despite running on every
  title edit.
- **A green scheduled job is not evidence it did anything.** Check what it
  skipped and why before concluding it works. A job can report SUCCESS on every
  tick for days while every item it was meant to process is silently dropped.
- **`merge-gate` and `pr-title-lint` are both required checks.** `merge-gate`
  is the substantive one: it builds on `macos-latest` and runs `--self-test`,
  so it is a real gate, not a structural approximation. `pr-title-lint` only
  enforces the `[type][scope]` title convention, but it is required too — a
  bad title blocks the merge the same as a failing build.
