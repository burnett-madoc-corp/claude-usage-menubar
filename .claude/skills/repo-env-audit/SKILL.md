---
name: repo-env-audit
description: Audit one repository or a directory of repositories for env-file hygiene, missing .gitignore rules, and variable coverage. Use when asked to check if local env files are protected, whether the env files present define the variables the code expects, or which variables are referenced by code but missing from local env files.
---

# Repo Env Audit

Use this skill when the user wants to audit one repository or a directory of repositories for:
- whether local env files are protected by `.gitignore`
- whether the env files present appear to define the variables the code expects
- which variables are referenced by code but missing from local env files

## Goals

Produce a practical audit without exposing secret values.

The audit should:
- inventory repos
- detect env-like files such as `.env`, `.env.local`, `.env.development`, `.env.production`, `*.env`, `.env.example`, and `.env.sample`
- check whether sensitive local env files are ignored by git
- extract referenced environment variable names from common patterns
- compare referenced names against keys present in local env files and example files
- report findings by repo, highlighting missing ignore rules and likely missing secrets

## Safety

- Never print secret values.
- Only report variable names, file paths, and counts.
- Treat example/sample env files as documentation, not proof that a working secret exists locally.

## Workflow

1. Run the helper script from this skill directory:

```bash
python3 audit_repo_envs.py /path/to/root
```

If no root is supplied, default to the current working directory.

2. Review each repo result:
- `missing_ignore_rules` means the repo has env-like files that do not match `.gitignore` patterns.
- `missing_from_local_env` means code references variables not found in local secret-bearing env files.
- `missing_from_any_env_doc` means code references variables not found even in example/sample env files.

3. Sanity-check noisy repos:
- generated files or vendored code can cause false positives
- CI-only variables may be intentionally absent from local env files
- some repos use secret managers instead of dotenv files

4. Report findings concisely:
- findings first
- then assumptions or false-positive risk
- then short remediation advice if useful

## Notes

- Prefer this skill over ad hoc shell one-liners when the request is specifically about env-file hygiene or secret coverage across repos.
- If the user wants fixes, add or update `.gitignore` patterns and example env files separately after the audit.

5. Before finishing, run the appropriate status command for every repo changed (`jj status` for Jujutsu repos, `git status --short` for Git-only repos). Remove accidental audit artifacts and do not leave repos dirty unless the user explicitly requested local fixes; if dirty files remain, name them and explain why.
