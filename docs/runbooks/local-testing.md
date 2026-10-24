# Local testing

Each command block may be started from anywhere inside the owned checkout; its first command resolves that checkout root with Git and fails outside a Git working tree.

This is a dependency-free Swift/AppKit menu-bar application. Its authoritative automated test is the built binary's `--self-test` mode; Python scripts add repository and SVG-chart checks. The supported build host is macOS only.

## Prerequisites and clean setup

- macOS 13 or later and Xcode command-line tools (`xcode-select -p`, or install them with `xcode-select --install`).
- Python 3 for the two static check scripts.
- No package-manager install is required; `Package.swift` has no external dependencies ([contributor prerequisites](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/CONTRIBUTING.md#prerequisites)).

From the repository root, verify tools without changing the installed app:

```bash
cd "$(git rev-parse --show-toplevel)"
set -euo pipefail
sw_vers -productVersion
xcode-select -p
swift --version
python3 --version
git status --short
```

Do not run `install.sh` for local testing: it copies into `/Applications` and registers a LaunchAgent. `build.sh` writes only repository-local `.build/` and `build/` artifacts.

## Complete offline gate

```bash
cd "$(git rev-parse --show-toplevel)"
set -euo pipefail
python3 .github/scripts/static_checks.py
python3 tools/check_charts.py
./build.sh
build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test
```

Expected result: each command exits `0`, `build.sh` ends with `Built build/ClaudeUsage.app`, and the binary prints `Self-tests passed`. This sequence matches [CONTRIBUTING.md](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/CONTRIBUTING.md#build-and-test) and [CI](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/.github/workflows/ci.yml#L27-L39).

The self-test uses in-memory/static fixtures and a dedicated `UserDefaults` suite. A gated Keychain round-trip uses the throwaway account `selftest_key`, cleans it up, and skips when Keychain is unavailable ([self-test implementation](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/Sources/main.swift#L1878-L1912)). It must never read or overwrite real provider keys.

For a manual parser smoke check after automated tests, run:

```bash
cd "$(git rev-parse --show-toplevel)"
set -euo pipefail
build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once
```

This may read local client state and attempt provider access, so it is not an offline fixture and its output depends on the host. Never paste tokens or credential-bearing paths into test evidence. A blank/unavailable provider is not an automated-test failure.

## Common failures

- **Source-derived:** a new `Sources/*.swift` file is ignored or symbols are missing: add the file to `build.sh`; its source list is explicit and static checks only prove listed files exist ([documented build trap](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/b34ed94fbd12dfa8036e78bae580071b2500cd4a/CONTRIBUTING.md#adding-a-source-file)).
- **Source-derived:** `lipo`, `codesign`, AppKit, or SDK errors: this is not a supported Linux build. Verify macOS 13+, the active developer directory, and Xcode command-line tools before editing source.
- **Source-derived:** `--self-test` traps with no pytest-style report: self-tests are Swift `precondition` calls; use the last printed section and the crash backtrace to identify the failing assertion.
- **Source-derived:** Keychain round-trip says `skipped`: this is expected on a locked/headless Keychain. It is explicitly a skipped integration probe, not proof that Keychain behavior passed.
- **Observed history:** [PR #71](https://github.com/burnett-madoc-corp/claude-usage-menubar/pull/71) fixed authenticated Antigravity refresh behavior and the README warns to test it with a live token. Automated offline self-tests do not establish that provider authentication works; perform that optional live check only on an authorized developer Mac, never in shared evidence.
- **History limit:** the three failed runs returned by the bounded query were PR-title-lint runs, not build/self-test failures; no recent historical build failure is claimed.

## Stop conditions and recovery

Stop if a command would install/launch the app, alter the user's real provider credentials, prompt for an unapproved Keychain item, or make a network call during the offline gate. Stop if the test account is not exactly the dedicated self-test account.

Recover build artifacts without touching the installed application: preserve any useful compiler logs, then move repository-local `build/` and `.build/` aside if their owner agrees they are disposable, and rerun `./build.sh`. If `selftest_key` remains after an interrupted test, remove only that account from service `local.claude-usage-menubar`; do not reset the whole Keychain.

## Verification provenance

Statically verified against default branch `main` at `b34ed94fbd12dfa8036e78bae580071b2500cd4a`. The authoring host was Linux, so macOS build and self-test commands were not executed. Review covered five commits, five merged PRs and three failed workflow records.
