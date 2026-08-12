# Contributing

Contributions are welcome — bug reports, fixes, new providers, and docs alike.
This is a small, dependency-free Swift/AppKit app, so the loop is short.

## Prerequisites

- macOS 13 or later
- Xcode command line tools (`xcode-select --install`) for `swiftc`
- Python 3 for the static checks

There are no third-party dependencies and no package manager. `build.sh` calls
`swiftc` directly.

## Build and test

```bash
./build.sh
build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test
```

`--self-test` is the test suite. `--once` prints a headless dump of everything
the app would show, which is the fastest way to eyeball provider parsing without
launching the menu bar item.

Run everything CI runs, in order:

```bash
python3 .github/scripts/static_checks.py
python3 tools/check_charts.py
./build.sh
build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test
```

## How tests work

There is no test framework, deliberately. Tests are `precondition` calls
gathered under `runSelfTests()`, invoked by the `--self-test` flag. A failed
precondition traps and the binary exits non-zero, which is all CI needs.

To keep logic testable, put pure logic in `nonisolated static func`s — free of
`@MainActor`, the network, and the filesystem — and call those from the self
tests. Anything that needs real I/O gets a protocol and a fake, the way
`KeyStore` does.

## Adding a source file

`build.sh` lists every source file explicitly on its `swiftc` line. A new
`Sources/*.swift` that is not added there will not be compiled, and the static
checks will not notice it is missing from the build — they only verify that
every file `build.sh` names exists, not the reverse. Add it to `build.sh` in the
same commit.

## Pull requests

Branch off `main` — do not commit to `main` directly. If you don't have push
access to this repo, fork it, branch off `main` in your fork, and open the PR
from there — the rest of this section is the same either way.

PR titles follow `[type][scope] imperative summary` and must be 72 characters or
fewer. CI enforces this. Validate before you push:

```bash
python3 .github/scripts/validate_pr_title.py "[fix][product] correct weekly reset rollover"
python3 .github/scripts/validate_pr_title.py --list   # allowed types and scopes
```

Pick whichever scope actually describes the change: `[product]` for app
behaviour or UI, `[ci]` for workflow/pipeline changes, `[docs]` for
documentation, `[security]` for anything touching credentials or the
Keychain boundary — e.g. `[fix][security] delete stale xai_key on save`.
`validate_pr_title.py --list` above is the source of truth for the full
type/scope list; check there if none of these fit.

In the PR body, say what changed, why, and how you verified it. For anything
touching provider parsing or the menu bar title, paste the relevant
`--self-test` or `--once` output.

CI runs the static checks, the chart checks, a real `swiftc` build, and
`--self-test` on a hosted macOS runner. `merge-gate` and `pr-title-lint` are
both required checks — a title that fails validation blocks the merge just
like a failing build does.

## Style

Match the surrounding code. A few house rules the static checks enforce:

- UTF-8, no BOM, LF line endings.
- No `NSLog(`, `debugPrint(`, `print("DEBUG`, `// DEBUG:` or `raise(SIGTRAP)`
  left in the sources.

Comments explain *why*, not *what*. The existing sources lean on this heavily —
particularly around the undocumented data formats the app reads, where the
reason a fallback exists is not recoverable from the code alone.

## Scope

The app reads usage signals from tools you already have logged in. It never
writes credentials and never redeems a refresh token — see
[SECURITY.md](SECURITY.md) for why that boundary matters. Contributions that
cross it will not be merged.
