# Security policy

## Reporting a vulnerability

Report privately through GitHub: open the repository's **Security** tab and
choose **Report a vulnerability**. That opens a private advisory visible only to
the maintainers.

Please do not open a public issue for anything that exposes a credential or a
path to reading one.

Expect an acknowledgement within a week. This is a hobby-scale project with no
paid support and no bounty — what you get is a fix, credit in the advisory if
you want it, and a straight answer if the report is not something we will act
on.

## Supported versions

Only the current `main` is supported. There are no tagged releases, no
backports, and no binary distribution — you build from source.

## What this app touches

The app is a read-only observer of credentials and logs that other tools own. It
is worth being precise about that boundary, because it is the main thing a
vulnerability here could break.

**Credentials it reads and never writes:**

| Source | What | How |
|---|---|---|
| Keychain item `Claude Code-credentials` | Claude Code's OAuth token | shelling out to `security find-generic-password` |
| `~/.codex/sessions/**.jsonl` | Codex's recorded `rate_limits` payloads | file read |

**Credentials it stores on your behalf**, in the login Keychain under service
`local.claude-usage-menubar`, account `openrouter_key`: the OpenRouter API key
you paste into Settings. It is yours, entered deliberately, and can be removed
from Settings or with `security delete-generic-password -s
local.claude-usage-menubar -a openrouter_key`.

If you ran a build before xAI support was removed, an `xai_key` item may still
exist under that same service. Nothing reads it any more, but nothing deletes
it either — remove it yourself with `security delete-generic-password -s
local.claude-usage-menubar -a xai_key`.

**Local state it reads:** `~/.claude/sessions/<pid>.json` (the registry of
live Claude Code processes); `~/.claude/projects/**/*.jsonl` — full Claude
Code conversation transcripts, parsed for per-session token and
context-window statistics. This is the most privacy-sensitive read the app
performs: a transcript is not just token counts, it is everything you typed
and everything the model wrote back. Also Codex's `state_*.sqlite` and the
rollout/session logs under `~/.codex/` that its `rollout_path` column points
to, read the same way and for the same reason (per-session token/context
stats); and `lsof`/`ps` output to match live agent processes to their working
directories. Every one of these reads is local-only — nothing parsed from a
transcript or rollout log is ever transmitted anywhere, it only feeds the
Sessions section's on-screen display. Session working directory paths are
shown in the dropdown.

**Network egress** is limited to the two provider endpoints documented in the
README (`api.anthropic.com`, `openrouter.ai`) and nothing else — Codex is read
entirely from local files. There is no telemetry, no analytics, no crash
reporting, and no update check.

## The refresh-token boundary

The app never redeems a refresh token. Anthropic rotates refresh tokens on use,
so redeeming one here would invalidate the token Claude Code itself holds and
silently break its login. When a token has expired the app says so and asks you
to run the underlying tool once, rather than refreshing on your behalf.

Treat any change that writes to, redeems, or transmits a credential read from
another tool as a security-relevant change, and say so explicitly in the PR.

## Things that are not vulnerabilities

- **The app is ad-hoc signed, not notarized.** Ad-hoc signing gives the bundle
  a signature so macOS will run it. It buys no Keychain stability and is not
  what keeps the "always allow" dialog away — that job is done by routing keys
  through `/usr/bin/security`, whose identity does not change between builds.
- **Pre-#24 Keychain items may still prompt once per launch.** An item written
  by a build from before #24 is pinned to that build's cdhash and costs one
  dialog per launch until it is re-saved from Settings. That is a legitimate
  leftover, not a regression.
- **Any process running as you can read these keys.** Routing keys through
  `security` trades a code-identity gate for rebuild-stability: Developer ID
  signing would restore the gate; ad-hoc cannot.
- **Undocumented data formats.** The Claude session registry and the Codex
  SQLite schema are internal details of tools this project does not control. The
  app degrades to "no sessions from this source" rather than crashing when they
  change. A format change breaking a reading is a bug, not a vulnerability.
- **Usage numbers being stale.** Codex has no pollable usage API; the app reads
  the newest `rate_limits` payload from its session logs and labels the row with
  its age.
