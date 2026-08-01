# Claude Usage — macOS menu bar

A tiny native menu bar app showing your Claude rate-limit usage: the **5-hour**
session window, the **weekly** window, and per-model weekly windows such as
**Fable**.

```
5h 17%  wk 85%          ← menu bar title (tinted by severity)

  5-hour   ██░░░░░░░░   17%   resets in 3h 23m
  Weekly   █████████░   85%   resets in 1d 15h
  Fable    ████░░░░░░   37%   resets in 1d 15h
```

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

Polls `GET https://api.anthropic.com/api/oauth/usage` every 60 seconds — the
same endpoint Claude Code's own `/usage` command uses — authenticated with the
OAuth token from your login Keychain (`Claude Code-credentials`).

The response's `limits` array is the authoritative source: `kind: "session"` is
the 5-hour window, `kind: "weekly_all"` the weekly one, and `kind:
"weekly_scoped"` entries carry a `scope.model.display_name` like `Fable`. Any
scoped window the API returns is displayed, so if per-model caps are added for
other models they appear automatically with no code change.

## A deliberate limitation

The app **only ever reads** the Keychain; it never writes and never redeems the
refresh token. Anthropic rotates refresh tokens on use, so redeeming one here
would invalidate the token Claude Code itself holds and break its login.

The trade-off: if the access token expires while you are not using Claude Code,
the app shows *"Token expired — run `claude` to refresh"*. Running `claude` once
refreshes it, and since the Keychain is re-read on every poll the app recovers
on its own within a minute. No restart needed.

## Requirements

macOS 13+, Xcode command line tools (for `swiftc`), and a logged-in Claude Code
install. No third-party dependencies.
