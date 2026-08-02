# AI Usage — macOS menu bar

A tiny native menu bar app showing rate-limit and credit usage across the AI
coding tools you actually use: **Claude**, **Codex**, **Antigravity**,
**OpenRouter** and **Grok**.

Claude's 5-hour and weekly windows plus Codex's weekly percentage stay in the
menu bar title. Reset times and every other provider live one click away.

```
[Claude] 5h 17%  wk 85%   [Codex] 42%  ← menu bar title (tinted by severity)

Claude
  5-hour   ██░░░░░░░░   17%   resets in 3h 23m
  Weekly   █████████░   85%   resets in 1d 15h
  Fable    ████░░░░░░   37%   resets in 1d 15h
Codex
  Weekly   ██████████  100%   resets in 59m
  (plan: plus · as of 6d ago)
Antigravity
  gemini-2.5-pro        ░░░░░░░░░░   0%   resets in 23h 59m
  gemini-3.1-flash-lite ░░░░░░░░░░   0%   resets in 23h 59m
OpenRouter
  Used     ██░░░░░░░░   18%   $1.80 of $10.00
  Remaining                   $8.20
```

## Provider support

| Provider | Source | Needs a key? |
|---|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage` (Keychain token) | no |
| Codex | `rate_limits` recorded in `~/.codex/sessions/**.jsonl` | no |
| Antigravity | `POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` | no |
| OpenRouter | `GET openrouter.ai/api/v1/credits` | yes |
| Grok (xAI) | `GET api.x.ai/v1/api-key` | yes |

Two caveats worth knowing up front:

- **Codex has no pollable usage API.** It does record the server's `rate_limits`
  payload into its session logs on every turn, so this reads the newest entry —
  free and local, but only as fresh as your last Codex turn. The row is labelled
  with its age (`as of 6d ago`) so a stale number never masquerades as live.
- **xAI publishes no credit-balance endpoint.** `/v1/api-key` returns key
  metadata, so the app reports key health (active / blocked / disabled) rather
  than inventing a balance.

The plain Gemini CLI is deliberately not included: Google exposes no quota
endpoint for it — the CLI itself only learns its quota from the metadata on a
429. Antigravity is covered instead, because it has a real quota RPC.

## API keys

OpenRouter and Grok need keys. Put them in
`~/.config/claude-usage/config.json` (never in the repo):

```json
{
  "openrouter_key": "sk-or-v1-…",
  "xai_key": "xai-…"
}
```

`OPENROUTER_API_KEY` / `XAI_API_KEY` environment variables override the file.
Providers without a key simply show "no API key" — nothing else breaks.

## Install

```bash
./install.sh
```

Copies the app to `/Applications` and registers a LaunchAgent so it starts at
login. To just build and run without installing:

```bash
./build.sh && open build/ClaudeUsage.app
```

On first launch macOS asks for Keychain access — choose **Always Allow** so it
does not prompt again.

### Uninstall

```bash
launchctl bootout gui/$UID/local.claude-usage-menubar
rm -rf /Applications/ClaudeUsage.app ~/Library/LaunchAgents/local.claude-usage-menubar.plist
```

## Headless mode

```bash
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once
```

Prints the same numbers and exits — useful for scripting or a shell prompt.

## How it works

Every provider is polled concurrently every 2 minutes, but rendered in a fixed
order so rows never jump around. A failed poll keeps the last good numbers and
marks them `stale` rather than blanking the section — the Anthropic usage
endpoint rate-limits aggressively, and a transient 429 should not look like an
outage.

**Claude** — `GET /api/oauth/usage`, the same endpoint Claude Code's own
`/usage` uses. The `limits` array is authoritative: `kind: "session"` is the
5-hour window, `weekly_all` the weekly one, and `weekly_scoped` entries carry a
`scope.model.display_name` like `Fable`. Scoped windows are iterated, not
hardcoded, so new per-model caps appear on their own.

**Antigravity** — the live token is in the Keychain under service `gemini`,
account `antigravity`, stored by go-keyring as base64 JSON. The plain file at
`~/.gemini/antigravity-cli/antigravity-oauth-token` goes stale; the CLI and IDE
refresh into the Keychain, not the file. `remainingFraction` is what is *left*
(1.0 = untouched), so the displayed percentage is `1 - remainingFraction`.

## A deliberate limitation

The app **only ever reads** credentials; it never writes and never redeems a
refresh token. Anthropic rotates refresh tokens on use, so redeeming one here
would invalidate the token Claude Code itself holds and break its login.

The trade-off: if a token expires while you are not using the tool in question,
the app says so — *"Token expired — run `claude` to refresh"*, or *"run `agy`"*.
Running that tool once refreshes it, and since credentials are re-read on every
poll the app recovers on its own. No restart needed.

## Requirements

macOS 13+, Xcode command line tools (for `swiftc`), and a logged-in Claude Code
install. No third-party dependencies.
