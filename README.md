# AI Usage — macOS menu bar

A tiny native menu bar app showing rate-limit and credit usage across the AI
coding tools you actually use: **Claude**, **Codex**, **Antigravity**,
**OpenRouter** and **Grok**.

Claude's 5-hour and weekly windows plus Codex's weekly percentage stay in the
menu bar title. Reset times, every other provider, and live agent sessions all
live one click away — alongside a Settings window (⌘,) for provider
visibility, refresh interval, and API keys.

```
[Claude] 5h 17%  wk 85%   [Codex] wk 42%  ← menu bar title (RAG coloured)

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

All five providers are visible by default, in both the dropdown and (where
they publish a headline) the title — see [Settings](#settings) to change that
per provider.

## Settings

Everything below is one **Settings…** (⌘,) click away from the dropdown — a
plain AppKit window, no SwiftUI, matching the rest of the app. Nothing in it
needs a restart: prefs are read fresh on every poll and every menu rebuild.

**Providers** — two independent checkboxes per provider: *Dropdown* (show its
card in the menu) and *Menu bar* (put it in the title). Menu bar only exists
for Claude and Codex — they're the only two with a headline value to put in
12pt of title text, so the other three simply don't get that checkbox rather
than showing it disabled. Hiding a provider from both stops polling it
entirely — a real saving, since the Anthropic usage endpoint rate-limits
aggressively and every unnecessary poll eats into that budget. `--once`
ignores all of this and always reports every provider, since headless output
is a diagnostic, not a display.

**Refresh interval** — 1/2/5/10/15 minutes, default 2. Floored at 60s for the
same reason: the Claude usage API rate-limits aggressively enough that a
faster poll risks trading a working title for a string of 429s.

**Sessions** — a show/hide checkbox for the whole section below, and a
Compact/Detailed row-style choice. See [Sessions](#sessions).

## API keys

OpenRouter and Grok need keys. Highest-precedence source wins:

1. `OPENROUTER_API_KEY` / `XAI_API_KEY` environment variables.
2. The macOS Keychain — set from **Settings… → API Keys**, service
   `local.claude-usage-menubar`.
3. Legacy `~/.config/claude-usage/config.json` (never in the repo):

```json
{
  "openrouter_key": "sk-or-v1-…",
  "xai_key": "xai-…"
}
```

The legacy file is a permanent fallback, not a deprecation notice with a
deadline: if you never open Settings, it keeps working forever, un-nagged. If
it holds a key with no matching Keychain item yet, Settings offers a one-click
"Import from config.json" — the file itself is left on disk either way, since
deleting a user's config out from under them isn't this app's call to make.

Each key gets **Test** (validates whatever's currently typed, not what's
saved, so you can try a key before committing to it) and **Save** (saving an
empty field deletes the Keychain item rather than storing an empty string,
which would just be a key that silently outranks nothing). If an env var is
set, its field shows disabled instead of quietly being outranked — a saved
Keychain key you can't tell is being ignored is exactly the kind of thing that
costs someone an afternoon.

These keys are written and read through `/usr/bin/security` rather than
Security.framework, which is the one non-obvious thing about this code. macOS
gates a Keychain item on *code identity* — the item's ACL names trusted
applications, and its partition list names permitted signing identities, both
filled in from whoever created the item. This app is ad-hoc signed
(`build.sh`), so it has no stable identity: an item written with `SecItemAdd`
came out pinned to that exact binary, `Partitions: [cdhash:…]`, and the next
build was a stranger to it. The result was a login-password dialog after every
install, where "Always Allow" grants access to a binary about to be replaced.
Going through `security` borrows an identity that does not change
(`apple-tool:`), which is also why this app's reads of *other* apps' items
never prompted.

The trade-off is deliberate: any process running as you can also run
`security` and read these keys back. That was already true of every other
Keychain item this app reads, and the code-identity gate it replaces bought no
confidentiality — an ad-hoc app cannot hold one — only a dialog. Developer ID
signing would restore a real gate; out of scope here.

An item written *before* this change is still pinned to the build that wrote
it, and by design cannot be read without one approval dialog. If that dialog
goes unanswered, the account is treated as having no key **for the rest of that
run** rather than being asked for again on the next poll — one dialog, not an
endless stream — and Settings says `stored key unreadable` instead of
pretending no key is set. Pasting the key in and saving repairs the item with
no dialog at all.

Providers without a key simply show "no API key" — nothing else breaks.

## Why monitor tokens at all

Every request is stateless: the client re-sends the **entire transcript** —
system prompt, tool definitions, every earlier message, every tool result — as
input, and gets a comparatively tiny output back. So a long session gets
quadratically expensive in total and individually heavier per turn, which is
the whole reason the [Sessions](#sessions) section exists.

![Input composition by turn](docs/charts/07-input-composition-by-turn.svg)

![Total input, cumulative](docs/charts/02-cumulative-input.svg)

[docs/token-metering.md](docs/token-metering.md) has the rest: the anatomy of
one turn, the context window filling, per-turn cost by session length, when
caching helps, and why output is a rounding error.

## Sessions

A read-only view of your **live** Claude Code and Codex processes, answering
one question: *should I clear this session?* Is a conversation still cheap to
continue, or is every turn now dragging a huge amount of context behind it?
It only reads process state and on-disk logs — no per-session cost estimate,
no history sparkline, no way to kill or attach to a session from here.

Two complementary signals drive each row:

- **contextPercent** — how full the context window is, against the model's
  window size. Absolute, but only as good as the window it's dividing by —
  see the limitation below.
- **BLOAT** — a *relative* cost multiple: what a turn costs right now versus
  the first few turns of the session (or since the last compaction). It needs
  no context-window constant at all, so it stays correct even in the cases
  where contextPercent is working from a wrong denominator. (`xFloor` in the
  source, which is where the `x` in `5.2x` comes from.)

Row colour is the **worse of the two** severities — a session that opened
with one huge turn pins BLOAT near 1.0x forever while contextPercent quietly
climbs toward full, and neither signal alone would catch that.

Two row styles, chosen in Settings (default Detailed):

- **Compact** — one line per session, through the same `NSMenuItem`
  attributed-title mechanism the provider rows use. `cwd`, model, raw token
  totals, and compaction/reclaim detail ride the native tooltip instead of
  taking up row width.
- **Detailed** — a richer two-line row (glyph, name and multiple on top;
  model, bar, turns and totals below) that you click to expand in place for
  `cwd` and compaction detail, without the menu closing.

Compaction is surfaced per session: how many, how long since the last one,
and what it reclaimed (context before → after, as a percentage). A session
with zero compactions shows nothing for it — no "⌁0" — and a compaction with
no usage recorded since it fired shows reclaim as pending (`—`), never a
fabricated 0% or 100%.

Detailed, the default:

```
Sessions
  ● worktree-a   5.2x
    claude-opus-5   ████░░░░░░  37%   217 turns   49.8M in / 138k out
  ○ sqlmesh   2.5x
    claude-opus-5   █░░░░░░░░░  12%   57 turns   5.5M in / 32k out
  ○ scratch-1   3.4x
    claude-opus-5   ██░░░░░░░░  16%   84 turns   9.5M in / 87k out
  ○ scratch-2   9.7x
    claude-opus-5   ████░░░░░░  38%   363 turns   76.2M in / 238k out
  ○ worktree-b   2.8x
    claude-opus-5   ██░░░░░░░░  18%   35 turns   3.7M in / 43k out

  (worktree-a clicked — expands in place:)
  ● worktree-a   5.2x
    claude-opus-5   ████░░░░░░  37%   217 turns   49.8M in / 138k out
    /Users/you/worktrees/agent-a
```

Compact renders the same data as single lines, cwd and detail in the tooltip:

```
Sessions
  ● worktree-a      ████░░░░░░  37%  5.2x  217t
  ○ sqlmesh         █░░░░░░░░░  12%  2.5x  57t
  ○ scratch-1       ██░░░░░░░░  16%  3.4x  84t
  ○ scratch-2       ████░░░░░░  38%  9.7x  363t
  ○ worktree-b      ██░░░░░░░░  18%  2.8x  35t
```

The `●`/`○` glyph tracks whether the process is currently busy (Detailed
pulses it; Compact stays static). A session with no usage recorded yet
(brand new, before its first message) shows "starting — no usage yet"
instead of a bar, and one whose model's context window couldn't be resolved
shows the raw token count with "window unknown" rather than a bar with a
fabricated denominator.

## Install

```bash
./install.sh
```

Copies the app to `/Applications` and registers a LaunchAgent so it starts at
login. To just build and run without installing:

```bash
./build.sh && open build/ClaudeUsage.app
```

The app's own API keys never raise a Keychain dialog (see above). Items
created by *other* apps — Claude Code's OAuth token, Antigravity's — carry
their own access rules, so macOS may ask about one of those once; choose
**Always Allow**.

### Uninstall

```bash
launchctl bootout gui/$UID/local.claude-usage-menubar
rm -rf /Applications/ClaudeUsage.app ~/Library/LaunchAgents/local.claude-usage-menubar.plist
```

## Headless mode

```bash
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once
```

Prints the same numbers — every provider card plus any live Sessions — and
exits; useful for scripting or a shell prompt. Unlike the live dropdown,
`--once` always reports all five providers regardless of what's hidden in
Settings.

## How it works

Every provider is polled concurrently on the configured refresh interval
(default 2 minutes, see [Settings](#settings)), but rendered in a fixed order
so rows never jump around. A failed poll keeps the last good numbers and
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

**Sessions** — no network call at all. Live processes come from `ps`; Claude
session data from an incremental, byte-offset read of
`~/.claude/projects/**/*.jsonl` (only newly-appended bytes are ever re-read);
Codex from a strictly read-only query against `~/.codex/state_*.sqlite` plus
the same incremental read of its rollout log. The section re-scans every 2
seconds *while the dropdown is open* — session files change on the order of
seconds, far faster than the provider poll interval — and that tick stops the
moment you close the menu.

## Deliberate limitations

The app **only ever reads** credentials; it never writes and never redeems a
refresh token. Anthropic rotates refresh tokens on use, so redeeming one here
would invalidate the token Claude Code itself holds and break its login.

The trade-off: if a token expires while you are not using the tool in question,
the app says so — *"Token expired — run `claude` to refresh"*, or *"run `agy`"*.
Running that tool once refreshes it, and since credentials are re-read on every
poll the app recovers on its own. No restart needed.

Sessions carries its own, smaller set:

- **Claude's context window is the configured/inferred one, not necessarily
  the live one.** It's resolved in tiers — the session's `.claude/settings.json`
  at start time, then a spawned subagent's `resolvedModel` as corroboration,
  then an observed-usage upgrade to 1M once real usage exceeds 200k — but no
  transcript event records a mid-session `/model` switch, so contextPercent
  can be stale until the observed-usage tier catches up. **BLOAT is
  unaffected** — it never touches a window size at all.
- **Codex session matching is start-time proximity, not identity.** A live
  `codex` process is matched to its `state_*.sqlite` thread row by cwd plus
  being within 5 seconds of that thread's `created_at_ms`. A resumed session
  (`codex resume`) falls outside that window and renders labelled
  "(unmatched)" rather than being silently guessed at.
- **Both data sources are undocumented and may change.**
  `~/.claude/sessions/<pid>.json` and the Codex `state_*.sqlite` schema are
  internal details of tools this app doesn't control, not a stable API. Reads
  degrade rather than crash: a missing registry file, a missing table or
  column, or a locked database all resolve to "no sessions from this source,"
  never a fatal error. (The Codex DB filename is itself versioned —
  `state_5.sqlite` today — so the app globs for the newest rather than
  hardcoding a number.)

## Requirements

macOS 13+, Xcode command line tools (for `swiftc`), and a logged-in Claude Code
install. No third-party dependencies.
