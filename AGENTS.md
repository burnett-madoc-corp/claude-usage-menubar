# Agent instructions

## Standing agent instructions

### Follow-ups become GitHub issues

Any finding worth acting on later is filed as a GitHub issue before the work is
reported done. Not a line in a summary, not a PR comment, not chat scrollback.
If it is worth saying "someone should look at this later", it is worth an issue.

### Operational facts about this estate

- **Skynet checkouts must stay on `main`.** The Dagster container bind-mounts its
  host checkout at `/opt/dagster/app`, so a checkout parked on a feature branch
  means production runs that branch. The sync job skips any repo not on its
  target branch, so this never self-corrects and merges silently never land.
- **A cancelled build poisons its commit.** A cancelled job leaves a `FAILURE`
  check run that a later `SUCCESS` from a replacement run does **not** supersede.
  The rollup stays `FAILURE` and the PR stays blocked with auto-merge armed and
  never firing. Clear it with `gh run rerun <cancelled-run-id> --failed`.
- **A green scheduled job is not evidence it did anything.** Check what it
  skipped and why before concluding it works. A job can report SUCCESS on every
  tick for days while every item it was meant to process is silently dropped.
