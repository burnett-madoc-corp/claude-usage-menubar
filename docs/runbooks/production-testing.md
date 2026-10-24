# Production testing

## Scope and identity

This is a locally installed macOS application, not a network service. Expected source is [`main@b34ed94f`](https://github.com/burnett-madoc-corp/claude-usage-menubar/tree/b34ed94fbd12dfa8036e78bae580071b2500cd4a); the deployed artifact is `/Applications/ClaudeUsage.app` plus LaunchAgent `local.claude-usage-menubar`, per the [pinned install documentation](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/README.md#headless-mode).

## Read-only smoke test

Prerequisites: interactive access to the target Mac as the installed user. Do not print Keychain contents, delete preferences, reset Control Centre, reinstall, or refresh credentials.

```bash
cd "$(git rev-parse --show-toplevel)"
git rev-parse HEAD
test -x /Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage
launchctl print "gui/$UID/local.claude-usage-menubar" >/tmp/claude-usage-launch.txt
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --status-check
```

Expected: approved source/release identity is recorded separately; LaunchAgent lookup exits `0`; `--once` prints provider cards plus title; status reports `isVisible = true`, non-zero geometry, and a title. These modes are defined in the [pinned headless contract](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/README.md#headless-mode). Do not attach `/tmp/claude-usage-launch.txt` without reviewing it for private paths.

## Freshness and user outcome

Open the menu and confirm visible Claude, Codex, OpenRouter and configured Antigravity states. Poll interval is user-configured (1/2/5/10/15 minutes; default 2). Codex is only as fresh as the last recorded turn, and Antigravity is live only while `agy` runs; both limitations are explicit in the [pinned provider behavior](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/README.md#how-it-works). Require age/stale labels to be honest; do not demand live freshness where the source cannot provide it.

If a poll fails, last-good numbers intentionally remain marked stale. A missing Codex session can be a start-time matching limitation, not data loss ([pinned gotcha](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/README.md#deliberate-limitations)). Capture app version/build identity, provider label/age, and status-check output. Stop on any credential-write prompt. Reinstall or rollback requires a separately selected signed/approved build. Recent [PR #74](https://github.com/burnett-madoc-corp/claude-usage-menubar/pull/74) is bounded history only.

## Evidence status and limits

- **Observed:** source SHA and GitHub metadata.
- **Statically verified:** install identity, headless modes, provider freshness semantics, and read-only credential policy.
- **Not executed:** Mac commands, UI, provider polling, install, or credential action.
- **Research limit:** current README, three PRs, and two failed-run records; no target Mac access.
