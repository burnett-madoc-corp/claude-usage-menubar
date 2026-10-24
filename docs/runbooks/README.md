# Operational runbooks

Repository-specific procedures grounded in source, configuration, and available operational history. Each runbook records its evidence snapshot, applicability, expected outcomes, and verification limits.

| Procedure | Use it to |
| --- | --- |
| [Deployment](deployment.md) | Release the intended revision, verify it, and recover from failure. |
| [Local testing](local-testing.md) | Set up an isolated environment and run meaningful checks. |
| [Passing CI](passing-ci.md) | Reproduce and diagnose the actual PR checks. |
| [Production testing](production-testing.md) | Check the deployed outcome within the documented safety boundary. |

Evidence reviewed on 2026-10-24. A historical successful deployment is not current-state proof; consult each procedure before acting. Cross-repository research and review are tracked in [ai-plans PR #144](https://github.com/burnett-madoc-corp/ai-plans/pull/144).
