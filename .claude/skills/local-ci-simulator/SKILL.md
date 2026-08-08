---
name: local-ci-simulator
description: Forces the agent to proactively discover and run local linters, type checkers, and test suites before executing a git push.
---

# Local CI Simulator Skill

When you are tasked with fixing a CI failure or are preparing to push new commits to a remote branch, you **MUST** run local validation first. Do not rely on GitHub Actions or other remote CI pipelines to act as your compiler or linter.

## Execution Steps

1. **Discover Tooling**: Inspect the repository root for common configuration files that indicate how tests and linters are run (e.g., `package.json`, `tox.ini`, `pytest.ini`, `Makefile`, `Cargo.toml`, `.pre-commit-config.yaml`).
2. **Run Linters and Formatters**: Execute the appropriate commands to check for syntax and style errors (e.g., `npm run lint`, `flake8 .`, `black --check .`, `mypy .`, `cargo clippy`).
3. **Run Tests**: Execute the local test suite (e.g., `npm test`, `pytest`, `cargo test`). If testing the entire suite is too slow, at least run the tests relevant to the files you modified.
4. **Fix Errors Locally**: If any of these local commands fail, read their output, fix the corresponding code, and re-run the commands until they pass.
5. **Commit and Push**: Only once the local checks pass are you permitted to commit your changes and push to the remote branch.
