# Deployment runbook

## Applicability and prerequisites

This repository installs a per-Mac application at commit
`b34ed94fbd12dfa8036e78bae580071b2500cd4a`. The authoritative [installer](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/install.sh)
builds `ClaudeUsage.app`, replaces `/Applications/ClaudeUsage.app`, installs
`~/Library/LaunchAgents/local.claude-usage-menubar.plist`, and bootstraps it.
Prerequisites are a supported macOS/Xcode toolchain, write permission to
`/Applications`, and a clean checkout at an explicitly reviewed SHA.

## Release and verification

Back up the existing app and plist to an operator-chosen timestamped directory
before release; the installer overwrites in place and has no automatic rollback.
Then, from inside the reviewed checkout:

```bash
cd "$(git rev-parse --show-toplevel)"
approved_sha='<reviewed-40-character-sha>'
test "$(git rev-parse HEAD)" = "$approved_sha"
test -z "$(git status --porcelain)"
./install.sh
launchctl print "gui/$UID/local.claude-usage-menubar"
pgrep -x ClaudeUsage
```

Require positive `merge-gate`. Expected: installer exits zero, launchd job is
loaded and the exact process is running. Complete acceptance in the GUI: menu
item visible, usage refresh succeeds, values are plausible, and login relaunch
works. No live install was run during this research. The app bundle does not
embed the Git SHA, so retain the reviewed SHA and hash the built executable for
identity.

## Rollback and stop conditions

On failure, boot out the job, restore both saved app bundle and plist, bootstrap
the restored plist, and repeat process/GUI checks. If no known-good backup
exists, stop; rebuilding an old SHA is a new deployment and requires review.
Do not use the installer's printed uninstall command as rollback because it
deletes both artifacts.

- `launchctl kickstart` does not restart the app because the job launches
  `/usr/bin/open`; kill the exact app process and let KeepAlive relaunch it, as
  explained in [install.sh](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/install.sh).
- macOS may block the menu item even while launchd/process checks pass; the
  same [installer](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/install.sh)
  names the System Settings recovery.

Research covered source, installer, 160 commits, 100 merged PRs and three failed
runs. No macOS application or launch agent was changed.
