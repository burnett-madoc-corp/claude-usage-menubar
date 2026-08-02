# Codex Menu-Bar Headline Design

## Goal

Show Codex weekly usage directly in the macOS menu bar so it is visible without opening the dropdown.

## Display

The menu-bar headline contains two compact provider groups in this order:

1. A white Claude logo followed by its existing `5h` and `wk` percentages.
2. A white Codex logo followed by `wk` and the Codex weekly percentage.

Conceptually:

```text
[Claude] 5h 17% wk 85%   [Codex] wk 42%
```

Reset countdowns, freshness notes, plan details, and all other providers remain in the click-open dropdown. Antigravity, OpenRouter, and Grok are not added to the menu-bar headline.

The provider logos render white for strong contrast on the dark menu bar. Percentages use RAG colours: green below 80%, amber from 80% through 94%, and red from 95% upward. Missing provider data displays an em dash in that provider's position instead of removing the group and causing the headline layout to jump.

## Data Flow

`CodexProvider` publishes a thread-safe headline value containing the weekly percentage and severity as a side effect of its normal load. `UsageMenuBar.renderTitle()` reads both the Claude and Codex headline values after each refresh and composes the provider logos and text into the status-item button.

The Codex headline uses the window identified as weekly by its duration (`10080` minutes), not its source key name. A failed transient refresh retains the last good value through the app's existing stale-card merge behaviour. A genuine absence of usable Codex rate-limit data produces the missing-data state.

## Error Handling

- Claude unavailable: show its logo and placeholders while continuing to show Codex if available.
- Codex unavailable: show its logo and an em dash while continuing to show Claude.
- Transient provider error after a successful load: keep the last known headline value.
- Provider logo cannot load: retain readable provider-specific fallback text so usage remains identifiable.

## Verification

- Unit-test headline extraction to confirm Codex selects the weekly window rather than the 5-hour window.
- Verify rendering states for both providers available, either provider unavailable, and severity colouring.
- Build the app with the existing build script.
- Run headless provider output to ensure the dropdown data path remains intact.
- Launch the app and visually confirm both provider groups fit and remain legible in the macOS menu bar without clicking.
