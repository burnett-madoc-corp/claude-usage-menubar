---
name: correction-prompt-handling
description: Forces the agent to explicitly state why a previous attempt failed, analyze logs, and distill findings into deterministic hooks or probabilistic skills.
---

# Correction Prompt Handling & Learning Distillation Skill

When an orchestrator script, background daemon, CI check, or user explicitly notifies you of a failure, friction point, or unexpected error, you must break out of the failure loop by performing root-cause analysis and distilling the resolution into persistent memory.

## Execution Steps

### 1. Halt Code Generation
DO NOT immediately start modifying code, reverting changes, or blindly retrying the same command.

### 2. Gather Empirical Evidence
Retrieve full, un-truncated error logs, stack traces, or CI output traces. If not provided in the prompt, inspect log files directly using `view_file` or query `gh pr checks` / background task logs.

### 3. Explicit Root Cause Analysis
State the root cause explicitly in your output before taking action (e.g., *"The log output shows DuckDB LEAST(1.0, confidence) evaluated to 1.0 when confidence was NULL, masking missing data"*).

### 4. Formulate & Verify a Targeted Fix
Design a minimal fix addressing the exact root cause. Verify locally using unit tests, smoke scripts, or linters before pushing.

### 5. Learning & Hook Distillation (Friction-Point Memory Protocol)
Once the fix is verified, classify the friction point into durable memory artifacts:

```
                          ┌─────────────────────────────────────────┐
                          │         Friction Point Resolved         │
                          └────────────────────┬────────────────────┘
                                               │
                 ┌─────────────────────────────┴─────────────────────────────┐
                 ▼                                                           ▼
  ┌─────────────────────────────┐                             ┌─────────────────────────────┐
  │     DETERMINISTIC HOOK      │                             │     PROBABILISTIC SKILL     │
  │ Static invariant, path rule,│                             │ LLM reasoning heuristic,    │
  │ lint check, AST validator   │                             │ boundary rule, workflow guide│
  └──────────────┬──────────────┘                             └──────────────┬──────────────┘
                 │                                                           │
  • Write pre-commit / CI script                              • Create/update .claude/skills/
  • Add bash guard or test fixture                            • Append to learnings/YYYY-MM-DD
```

1. **Deterministic Hook**: If the failure is caused by a static invariant, path misconfiguration, missing registration, or broken permission, write or update an automated script (`scripts/check_*.py` or pre-commit hook).
2. **Probabilistic Skill**: If the failure is caused by a design heuristic, boundary misinterpretation, or LLM reasoning mistake, update or create a `SKILL.md` under `.claude/skills/`.
3. **Persist Memory**: Append the entry to `learnings/YYYY-MM-DD-<slug>.md` (if in a repo with a learnings store) or `.agent_plans/` / `MEMORY.md`.
4. **Mirror Parity**: Run `python3 tests/check_skill_symlinks.py` to ensure `.codex/skills/` and `.gemini/skills/` mirrors remain in 100% sync.
