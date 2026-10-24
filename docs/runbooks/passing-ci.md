# Passing CI

This runbook applies to `burnett-madoc-corp/claude-usage-menubar` at default-branch snapshot [`b34ed94fbd12dfa8036e78bae580071b2500cd4a`](https://github.com/burnett-madoc-corp/claude-usage-menubar/tree/b34ed94fbd12dfa8036e78bae580071b2500cd4a). It documents validation only; it does not authorize merges, deployments, scheduled workflows, live data writes, or ruleset changes.

Use the estate's [`run-local-gates` skill](https://github.com/burnett-madoc-corp/Claude-skills/blob/b5c62489e3bb70966fbf5d08a65fee098b3690ee/.claude/skills/run-local-gates/SKILL.md) for generic pre-push discipline. The repository-specific authority is the [pinned CI workflow](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/.github/workflows/ci.yml).

## Gate contract

Ruleset [`20604470`](https://github.com/burnett-madoc-corp/claude-usage-menubar/rules/20604470) is `active` and currently lists `merge-gate`, `pr-title-lint` with `0` approving reviews. The CI trigger covers ready pull requests and pushes to `main`. The macOS job itself is named `merge-gate` and runs static source checks, chart checks, a universal Swift build, and the app self-test. There are no job dependencies. The gate job's declared dependencies are no separate jobs. The live ruleset currently lists `merge-gate, pr-title-lint`; this conflicts with the estate policy that only `merge-gate` is required. Treat it as settings drift and escalate rather than changing or bypassing it.

Passing means an actually executed, current-head `merge-gate` with conclusion `success`. Missing, queued, cancelled, stale-head, or skipped is not passing.

## Prerequisites

macOS 13 or newer, Xcode command-line tools (`swift`, `lipo`, `codesign`), Python 3, and both arm64/x86_64 Swift build support. CI uses `macos-latest`. Start somewhere inside the owned isolated checkout at the exact PR head and do not load production secrets unless a command below explicitly names a read-only requirement.

## Local reproduction

### Run static, build, and self-test gates

```bash
cd "$(git rev-parse --show-toplevel)"
python3 .github/scripts/static_checks.py
python3 tools/check_charts.py
./build.sh
build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test
```

Expected outcome: Both Python checks exit zero, `build.sh` recreates `build/ClaudeUsage.app` with a universal binary, and `--self-test` exits zero. Building is a local artifact mutation, not installation or deployment.

## Confirm execution remotely

The installed Skynet `gh` 2.46.0 does not support `gh pr checks --json`. Use these read-only REST/run payloads; `jq -e` asserts actual keys and values and no pipeline can hide a failed command:

```bash
cd "$(git rev-parse --show-toplevel)"
set -euo pipefail
: "${PR:?set PR to the target pull request number}"
case "$PR" in
  ''|*[!0-9]*) printf '%s\n' 'PR must contain decimal digits only' >&2; exit 2 ;;
esac
: "${CI_RUN_ID:?set CI_RUN_ID to the target CI workflow run ID}"
case "$CI_RUN_ID" in
  ''|*[!0-9]*) printf '%s\n' 'CI_RUN_ID must contain decimal digits only' >&2; exit 2 ;;
esac
HEAD_SHA=$(gh pr view "$PR" -R burnett-madoc-corp/claude-usage-menubar --json headRefOid --jq .headRefOid)
test "${#HEAD_SHA}" -eq 40
CHECKS_JSON=$(mktemp)
RUN_JSON=$(mktemp)
gh api "repos/burnett-madoc-corp/claude-usage-menubar/commits/$HEAD_SHA/check-runs?per_page=100" > "$CHECKS_JSON"
gh run view "$CI_RUN_ID" -R burnett-madoc-corp/claude-usage-menubar --json headSha,event,conclusion,jobs > "$RUN_JSON"
jq -e '  (.check_runs | type == "array") and  (any(.check_runs[]; .name == "merge-gate" and .status == "completed" and .conclusion == "success"))' "$CHECKS_JSON" >/dev/null
jq -e --arg head "$HEAD_SHA" '  (.headSha == $head) and (.event == "pull_request") and (.conclusion == "success") and  (.jobs | type == "array") and  (any(.jobs[]; .name == "merge-gate" and .status == "completed" and .conclusion == "success"))' "$RUN_JSON" >/dev/null
```

Also inspect every gate dependency listed above. A permitted dependency skip must be explained by the workflow's successful selector; the gate itself may not skip. Do not dump full API payloads or environments into tickets because annotations can contain sensitive context.

## Diagnose, stop, and recover

- Do not run this gate on Linux and call it equivalent; the required runner and product are macOS-specific.
- The active ruleset currently requires both `merge-gate` and `pr-title-lint`, conflicting with the estate policy that only `merge-gate` is required. Stop and escalate the settings drift; do not change the ruleset in this procedure.
- Self-test should not prompt for Keychain or use live provider credentials; unset provider secrets if diagnosing locally.
- If all jobs fail before any step executes, diagnose runner/startup/billing separately from code. A non-executed gate is not green.
- After a real failure, reproduce the exact failing command at the same head, fix the cause, and rerun the workflow. Do not push an empty commit or rerun only a downstream gate.
- Stop when a command would dispatch an operational workflow, contact production with write capability, require an unavailable secret, or produce an unexplained skip.

## Bounded history and verification

No failed CI run appeared in the eight most recent runs queried specifically for `ci.yml`; this bounded result is not a claim that older failures do not exist. The latest sampled successful CI run was [run 39218025945](https://github.com/burnett-madoc-corp/claude-usage-menubar/actions/runs/39218025945) on `b34ed94fbd12`. It is historical evidence only, not proof for another head. Research covered eight workflow-specific CI runs, 12 recent merged PRs, recent CI/config commits, the current ruleset, and relevant estate-plan records where found.

At the pinned SHA, static parsing succeeded for `5` tracked Python files and `3` workflow YAML files. The command procedures above were traced to current source. Dependency installation, platform/container builds, credentialed external reads, and deployment were not executed unless explicitly recorded otherwise in the evidence sidecar.
