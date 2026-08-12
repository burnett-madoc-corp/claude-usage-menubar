# Agent instructions

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
- **`merge-gate` is the only required check.** It builds on `macos-latest` and
  runs `--self-test`, so it is a real gate, not a structural approximation.
