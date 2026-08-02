# Codex Menu-Bar Headline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display Claude and Codex usage percentages, identified by compact provider marks, directly in the macOS menu bar.

**Architecture:** Add a small shared headline snapshot model, populate Codex's snapshot while parsing its existing local rate-limit payload, and render both provider groups independently in the status item. Keep deterministic extraction and display-state checks behind a `--self-test` command so the dependency-free `swiftc` project can test its pure logic without adding a package manager.

**Tech Stack:** Swift 5, AppKit, Foundation, macOS 13+, existing shell build scripts.

## Global Constraints

- The menu-bar headline contains Claude first and Codex second.
- Codex shows only its weekly percentage; reset countdowns and freshness remain in the dropdown.
- Antigravity, OpenRouter, and Grok remain click-only providers.
- Provider marks must remain legible in light and dark menu bars.
- Missing data uses an em dash and does not remove or reorder a provider group.
- No new third-party dependencies.

---

### Task 1: Codex Weekly Headline State

**Files:**
- Modify: `Sources/Providers.swift:89-177`
- Modify: `Sources/main.swift:386-404`

**Interfaces:**
- Consumes: Codex `rate_limits` dictionaries with `primary` and `secondary` windows.
- Produces: `CodexProvider.headline.value: HeadlineValue?`, where `HeadlineValue` contains `percent: Int` and `severity: String`; `CodexProvider.extractWeeklyHeadline(from:) -> HeadlineValue?`; executable option `--self-test`.

- [ ] **Step 1: Add a failing Codex extraction self-test**

Add a `runSelfTests()` branch before the app entry point in `Sources/main.swift`. Construct rate limits in which `primary` is a 300-minute window at 12% and `secondary` is a 10080-minute window at 63%, call `CodexProvider.extractWeeklyHeadline(from:)`, and assert that the result is 63% with normal severity. Add a second assertion that 96% maps to critical severity.

```swift
let limits: [String: Any] = [
    "primary": ["window_minutes": 300, "used_percent": 12.0],
    "secondary": ["window_minutes": 10080, "used_percent": 63.0],
]
precondition(CodexProvider.extractWeeklyHeadline(from: limits)?.percent == 63)
precondition(CodexProvider.extractWeeklyHeadline(from: limits)?.severity == "normal")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`

Expected: compilation fails because `extractWeeklyHeadline` is not defined.

- [ ] **Step 3: Implement the shared headline value and Codex extraction**

Add a thread-safe headline holder following `ClaudeProvider.Headline`. Make `extractWeeklyHeadline(from:)` scan both source windows and select the dictionary whose `window_minutes` equals `10080`. Round `used_percent` to an integer and derive severity with the existing thresholds: critical at 95 or above, warning at 80 or above, normal otherwise. Set the value when `card(from:timestamp:)` parses a usable weekly window; clear it only when no recent Codex sessions or no usable rate-limit payload exists, while preserving it for transient read errors.

```swift
struct HeadlineValue {
    let percent: Int
    let severity: String
}

static func extractWeeklyHeadline(from limits: [String: Any]) -> HeadlineValue? {
    for key in ["primary", "secondary"] {
        guard let window = limits[key] as? [String: Any],
              (window["window_minutes"] as? NSNumber)?.intValue == 10080,
              let used = (window["used_percent"] as? NSNumber)?.doubleValue
        else { continue }
        let percent = Int(used.rounded())
        return HeadlineValue(percent: percent,
                             severity: percent >= 95 ? "critical" : percent >= 80 ? "warning" : "normal")
    }
    return nil
}
```

- [ ] **Step 4: Run the self-test and headless provider output**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once`

Expected: self-test prints `Self-tests passed`; headless output still contains Claude and Codex sections.

- [ ] **Step 5: Commit the state change**

```bash
git add Sources/Providers.swift Sources/main.swift
git commit -m "Add Codex weekly headline state"
```

### Task 2: Provider-Identified Menu-Bar Rendering

**Files:**
- Create: `Resources/claude-template.svg`
- Create: `Resources/codex-template.svg`
- Modify: `build.sh:8-18`
- Modify: `Sources/main.swift:224-238`
- Modify: `README.md:7-20`

**Interfaces:**
- Consumes: `ClaudeProvider.headline.value` and `CodexProvider.headline.value`.
- Produces: `UsageMenuBar.headlineText(claude:codex:) -> String` for deterministic layout checks and an attributed status-item title with template-image provider logos and severity colours.

- [ ] **Step 1: Add failing display-state self-tests**

Extend `runSelfTests()` to verify the plain-text representation for all availability states.

```swift
precondition(UsageMenuBar.headlineText(claude: (17, 85), codex: 42) == "Claude 5h 17% wk 85%   Codex 42%")
precondition(UsageMenuBar.headlineText(claude: nil, codex: 42) == "Claude 5h — wk —   Codex 42%")
precondition(UsageMenuBar.headlineText(claude: (17, 85), codex: nil) == "Claude 5h 17% wk 85%   Codex —")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`

Expected: compilation fails because `headlineText(claude:codex:)` is not defined.

- [ ] **Step 3: Implement stable provider groups**

Create compact official-shape monochrome SVG marks for Claude and Codex/OpenAI, copy them into `Contents/Resources` in `build.sh`, and load them as `NSImage` template images so macOS supplies light/dark contrast. Extract a pure `headlineText` helper for accessibility and deterministic state tests, then update `renderTitle()` so it always emits the Claude and Codex groups in the same order using `NSTextAttachment` logos. Give each percentage its provider severity colour and render an em dash when a snapshot is unavailable. Do not gate the whole title on Claude availability. If an image cannot load, substitute the readable text labels `Claude` or `Codex`.

The attributed title must conceptually render:

```text
[Claude logo] 5h 17% wk 85%   [Codex logo] 42%
```

- [ ] **Step 4: Update documentation**

Change the README headline description and example to show Claude and Codex in the menu bar. State explicitly that Codex's displayed number is weekly usage and the remaining providers stay in the dropdown.

- [ ] **Step 5: Run deterministic and build verification**

Run: `./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test`

Expected: build succeeds and prints `Self-tests passed`.

- [ ] **Step 6: Commit the rendering change**

```bash
git add Resources/claude-template.svg Resources/codex-template.svg build.sh Sources/main.swift README.md
git commit -m "Show Codex weekly usage in menu bar"
```

### Task 3: Installed-App Verification

**Files:**
- Modify: none expected

**Interfaces:**
- Consumes: the built `build/ClaudeUsage.app` bundle.
- Produces: verified live menu-bar behavior.

- [ ] **Step 1: Run source and repository checks**

Run: `git diff --check && ./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once`

Expected: no whitespace errors; build and self-tests pass; live provider output includes Codex Weekly.

- [ ] **Step 2: Install and restart the LaunchAgent**

Run: `./install.sh`

Expected: `/Applications/ClaudeUsage.app` is replaced by the verified build and `local.claude-usage-menubar` starts successfully.

- [ ] **Step 3: Verify the running process and visual headline**

Run: `pgrep -fl '/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage'`

Expected: exactly one installed-app process. Visually confirm the menu bar shows Claude `5h` and `wk` percentages followed by the Codex weekly percentage without opening the dropdown.

- [ ] **Step 4: Review the complete change**

Run: `git status --short --branch && git log -3 --oneline && git diff origin/main...HEAD --check && git diff origin/main...HEAD -- Sources/Providers.swift Sources/main.swift README.md docs/superpowers`

Expected: only the approved feature, its tests, documentation, spec, and plan are present; no credentials or unrelated files are included.
