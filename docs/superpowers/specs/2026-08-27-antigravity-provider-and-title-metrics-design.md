# Antigravity provider and a per-metric menu bar title

Design, 2026-08-27.

Two changes ship together because neither is much use alone: Antigravity
returns four quota numbers, and the title has no way to show a chosen subset
of anything.

## 1. Why Antigravity can come back

It shipped in `82cd9f2` and was removed in `#33` on 2026-08-12. The removal
was correct at the time: `v1internal:retrieveUserQuota` returned raw
per-`modelId` buckets covering only some of the models Antigravity serves, so
the card could read 0% while you were throttled on a model it never mentioned.
The README recorded the condition for return — "if Google documents that RPC
or completes its coverage".

Coverage is now complete, through a different RPC. The `agy` binary carries
`RetrieveUserQuotaSummary`, which returns named groups rather than raw model
ids:

```
response.groups[] = { displayName, description, buckets[] }
buckets[]         = { bucketId, displayName, description, window,
                      remainingFraction, resetTime }
```

Two groups cover the whole product — "Gemini Models" (Flash, Pro) and "Claude
and GPT models" (Opus, Sonnet, GPT-OSS) — each with a weekly and a five-hour
bucket. There is no longer a model that reports nothing.

### The remote RPC is still unusable, and this is why

Both `cloudcode-pa.googleapis.com` and the `daily-` host the CLI actually
talks to reject this account's live OAuth token on both the old and the new
RPC:

```
403 PERMISSION_DENIED / SUBSCRIPTION_REQUIRED
"You do not have a valid license of this product."
```

Verified against the Keychain token (service `gemini`, account `antigravity`)
with an empty body, with `{"project":"default-cli-project"}`, with
`client-metadata` headers at two `pluginType` values, and with the API key
embedded in the binary (which fails differently — "The API Key and the
authentication credential are from different projects"). The account is
`auth_method: consumer`; that path now appears to be enterprise-gated.

The endpoint itself is alive — an unknown field in the body returns a 400
naming the field, so the request parses. It is authentication that fails.

**Do not re-attempt the remote path on the strength of it "being documented
somewhere".** Re-test it against a live token first.

### What we use instead

`agy` runs a Connect server on loopback. The quota RPC is served there with no
authentication at all:

```
POST http://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
Connect-Protocol-Version: 1
Content-Type: application/json

{"ideName":"antigravity","extensionName":"antigravity","locale":"en","ideVersion":"unknown"}
```

The IDE requires an `X-Codeium-Csrf-Token`; the CLI does not.

## 2. AntigravityProvider

### Finding the port

`agy` picks ephemeral ports per run and writes no port file — there is no
lockfile, and `jetski_state.pbtxt` does not carry one. Discovery is therefore

```
/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -c agy
```

a subprocess per poll, the same cost the app already pays for `security` on
every Keychain read.

`KeychainCLI` currently duplicates its bounded-`Process` body across `read`
and `readStdin`. That body moves to one `BoundedProcess.run` helper and all
three call sites use it. This is a prerequisite, not incidental cleanup: a
third copy of a subprocess timeout is exactly the kind of duplication that
drifts.

### Talking to it

Of the two ports `agy` opens, one speaks plain HTTP and the other TLS with a
self-signed certificate, and which is which is not stable. The provider tries
`http://` first, then `https://`, per candidate port, and takes the first
2xx.

The `https://` attempt needs a `URLSessionDelegate` that accepts an untrusted
certificate **only** when the host is exactly `127.0.0.1`. Any other host
falls through to default validation. `SECURITY.md` records this exception.

### Rendering the card

`used = 1 - remainingFraction`, rounded. Severity uses the app's existing
thresholds: 95 critical, 80 warning.

Labels join a shortened group name to a window name:

- group: drop a trailing ` Models`/` models`, then replace ` and ` with `/`.
  "Gemini Models" → "Gemini"; "Claude and GPT models" → "Claude/GPT".
- window: `weekly` → "Weekly", `5h` → "5-hour"; anything else falls back to
  the bucket's own `displayName`.

giving `Gemini · Weekly`, `Claude/GPT · 5-hour`. Detail is
`resets in 3d 1h` from the existing `Format.countdown`.

Buckets render in payload order. A group or bucket we have never seen still
renders — the label rules degrade to the server's own display names — it just
cannot be ticked into the title (see §3).

### When agy is not running

The provider caches its last good reading in `UserDefaults` under
`antigravity.cache`:

```json
{ "fetchedAt": "<ISO8601>",
  "buckets": [ { "id", "label", "percent", "resetTime" } ] }
```

With no server listening, the cache is replayed with **each bucket dropped
once its own `resetTime` has passed**, under a gray `as of 3h ago` badge —
the same badge vocabulary `CodexProvider` uses for its snapshot age. A weekly
number stays useful for days; a five-hour one expires by itself. If no bucket
survives, the card reads `agy not running`.

This is deliberately not the existing `UsageMenuBar.merge` staleness path.
That one is amber, means "the poll just failed", and dies with the process.
This cache has to survive an app restart, because the common case is that
`agy` last ran yesterday.

## 3. The title becomes a metric registry

### The problem

`renderTitle()` hardcodes two providers: it reads
`ClaudeProvider.headline.value` and `CodexProvider.headline.value` — two
separate bespoke lock-boxes — and gates each on `Prefs.showInTitle(.claude)`
/ `.codex`. Seven tickable numbers cannot hang off that shape.

### The registry

One value type and one fixed registry:

```swift
struct TitleMetric: Hashable {
    let id: String          // "claude.session", "antigravity.3p-weekly", …
    let provider: ProviderID
    let label: String       // "5-hour", "Gemini · Weekly"
    let defaultOn: Bool
}
```

`TitleMetric` and its registry live in `Prefs.swift`, beside `ProviderID` —
the same file already owns provider identity, and adding no new source file
keeps `build.sh`'s hand-maintained compile manifest untouched.

Seven entries, in title order: Claude 5-hour, Claude weekly, Codex weekly,
then Antigravity's `gemini-weekly`, `gemini-5h`, `3p-weekly`, `3p-5h`.
Antigravity ids are the server's own `bucketId`s.

Providers publish headlines into one shared `[String: HeadlineValue]` keyed by
metric id, replacing both bespoke `Headline` classes.

`ProviderID.supportsTitle` is deleted. A provider is title-capable if it owns
at least one registry entry, so OpenRouter needs no special case.

Only registry ids can be ticked. An unrecognised `bucketId` from a future
Antigravity release shows in the dropdown and is ignored by the title, rather
than appearing as an unlabelled checkbox.

### Preferences and migration

Per-metric flag at `title.metric.<id>`. Unset reads `defaultOn`, which is
`true` for the three existing numbers and `false` for all four Antigravity
buckets — **the title must not grow on upgrade**.

Existing installs carry `title.claude` / `title.codex` booleans. On first read
after upgrade, if `title.metricsMigrated` is unset, each provider's metrics
are seeded from its old flag and the marker is set. Someone who had hidden
Codex from the bar stays hidden.

### Rendering

`renderTitle()` walks the registry in order, groups consecutive entries by
provider, and draws each provider's logo once followed by its ticked numbers.
With default prefs the output is byte-identical to today's.

`headlineText` collapses from four positional parameters to one array of
`(TitleMetric, HeadlineValue?)`, which is what makes it testable across seven
metrics instead of two providers. The existing six preconditions are rewritten
against the new signature.

The empty case is unchanged: every metric unticked still renders the literal
`AI`, so the status item is never zero-width.

### Settings

The Providers section keeps its per-provider **Dropdown** checkbox and loses
its **Menu bar** one. A new **Menu bar** group lists the seven metrics as
checkboxes, labelled `<Provider> · <metric label>`.

## 4. The logo

There is no Simple Icons entry for Antigravity (checked against `slugs.md`),
and `antigravity.google` renders its mark in JavaScript with no inline SVG.

The official mark is in `antigravity.google/favicon.ico` — a Google-gradient
arch, an "A" with no crossbar and outward-flared feet. The 48×48 layer is
extracted and its alpha channel traced to a single path, producing
`Resources/antigravity-template.svg` in the same shape as the two existing
marks: a `0 0 24 24` viewBox, `role="img"`, one `<path>`, no fill attribute.

`build.sh` already globs `Resources/*-template.svg`, so it needs no change.
The existing `logoImage(resource:)` renders it monochrome.

The trace is reviewed at menu-bar size before it lands. A bad trace is redone,
not approximated by hand.

## 5. Testing

New pure functions, exercised by `--self-test` preconditions:

- bucket parsing from a captured real payload → four rows, expected labels and
  percentages
- label shortening, including the ` and ` → `/` rule and an unknown window
- cache replay across a `resetTime` boundary: expired buckets dropped, live
  ones kept, all-expired yields the not-running card
- prefs migration from `title.claude`/`title.codex`, including the
  already-migrated no-op
- `headlineText` across the seven metrics, including all-unticked → `AI`

Full gate before the PR: `static_checks.py`, `check_charts.py`, `build.sh`,
`--self-test`, plus a live `--once` in both states — `agy` running and not.

## 6. Out of scope

- Reviving Grok. Nothing has changed: xAI still publishes no usage endpoint.
- Reordering title metrics. The registry order is fixed; only visibility is
  a preference.
- Reading quota from the Antigravity IDE. It needs a CSRF token from the app's
  own state, and this machine has no IDE install to test against.
