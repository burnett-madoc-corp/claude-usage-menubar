<!--
Title: [type][scope] imperative summary, 72 chars or fewer.
Validate: python3 .github/scripts/validate_pr_title.py "<title>"
-->

## What changed and why

<!-- The behaviour before and after. If this fixes a bug, what the wrong
     behaviour was, not just which function moved. -->

## Verification

<!-- CI builds and runs --self-test on macOS. Paste anything CI cannot show:
     --once output for provider parsing, a screenshot for menu bar rendering. -->

```
./build.sh && build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --self-test
```

## Checklist

- [ ] New `Sources/*.swift` files are added to `build.sh`'s `swiftc` line
- [ ] New pure logic is covered by a `precondition` in `runSelfTests()`
- [ ] No credential is written, redeemed, or transmitted that this app did not
      create itself (see [SECURITY.md](https://github.com/burnett-madoc-corp/claude-usage-menubar/blob/main/SECURITY.md))
