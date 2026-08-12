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
| Keychain service `gemini`, account `antigravity` | Antigravity's OAuth token, stored there by go-keyring | Keychain read |
| `~/.codex/sessions/**.jsonl` | Codex's recorded `rate_limits` payloads | file read |

**Credentials it stores on your behalf**, in the login Keychain under service
`local.claude-usage-menubar`, accounts `openrouter_key` and `xai_key`: the
OpenRouter and xAI API keys you paste into Settings. These are yours, entered
deliberately, and can be removed from Settings or with `security
delete-generic-password -s local.claude-usage-menubar`.

**Local state it reads:** `~/.claude/sessions/<pid>.json`, Codex's
`state_*.sqlite`, and `lsof`/`ps` output to match live agent processes to their
working directories. Session working directory paths are shown in the dropdown.

**Network egress** is limited to the five provider endpoints documented in the
README (`api.anthropic.com`, `openrouter.ai`, `api.x.ai`,
`cloudcode-pa.googleapis.com`) plus nothing else. There is no telemetry, no
analytics, no crash reporting, and no update check.

## The refresh-token boundary

The app never redeems a refresh token. Anthropic rotates refresh tokens on use,
so redeeming one here would invalidate the token Claude Code itself holds and
silently break its login. When a token has expired the app says so and asks you
to run the underlying tool once, rather than refreshing on your behalf.

Treat any change that writes to, redeems, or transmits a credential read from
another tool as a security-relevant change, and say so explicitly in the PR.

## Things that are not vulnerabilities

- **The app is ad-hoc signed, not notarized.** `build.sh` signs with `-` so the
  Keychain can grant a stable identity to your "always allow" decision. Every
  rebuild produces a new signature and re-prompts for Keychain access. That is
  expected.
- **Undocumented data formats.** The Claude session registry and the Codex
  SQLite schema are internal details of tools this project does not control. The
  app degrades to "no sessions from this source" rather than crashing when they
  change. A format change breaking a reading is a bug, not a vulnerability.
- **Usage numbers being stale.** Codex has no pollable usage API; the app reads
  the newest `rate_limits` payload from its session logs and labels the row with
  its age.
