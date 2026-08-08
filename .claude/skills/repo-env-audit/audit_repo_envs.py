#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ENV_FILE_RE = re.compile(
    r"(^|/)(\.env(?:\.[^/]+)?|[^/]+\.env|env\.example|\.env\.example|\.env\.sample|\.env\.local)$"
)
SECRET_ENV_FILE_RE = re.compile(
    r"(^|/)(\.env(?:\.(?!example|sample)[^/]+)?|[^/]+\.env)$"
)
DOC_ENV_FILE_RE = re.compile(r"(^|/)(env\.example|\.env\.example|\.env\.sample)$")
ASSIGNMENT_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")

ENV_VAR_PATTERNS = [
    re.compile(
        r"""\b(?:os\.getenv|os\.environ\.get|getenv)\(\s*["']([A-Z][A-Z0-9_]+)["']"""
    ),
    re.compile(r"""\b(?:process\.env\.([A-Z][A-Z0-9_]+))\b"""),
    re.compile(r"""\b(?:process\.env\[\s*["']([A-Z][A-Z0-9_]+)["']\s*\])"""),
    re.compile(r"""\b(?:import\.meta\.env\.([A-Z][A-Z0-9_]+))\b"""),
    re.compile(r"""\b(?:ENV\[\s*["']([A-Z][A-Z0-9_]+)["']\s*\])"""),
    re.compile(r"""\$\{([A-Z][A-Z0-9_]+)\}"""),
]

IGNORE_DIRS = {
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".next",
    "dist",
    "build",
    "coverage",
    ".cache",
    ".idea",
    ".vscode",
    "site-packages",
}

TEXT_EXTENSIONS = {
    ".py",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
    ".mjs",
    ".cjs",
    ".sh",
    ".bash",
    ".zsh",
    ".env",
    ".yml",
    ".yaml",
    ".json",
    ".toml",
    ".ini",
    ".cfg",
    ".conf",
    ".md",
}

NOISE_VARS = {
    "PATH",
    "HOME",
    "PWD",
    "SHELL",
    "USER",
    "LOGNAME",
    "LANG",
    "TERM",
    "CI",
    "TZ",
    "NODE_ENV",
    "PYTHONPATH",
    "PORT",
    "HOST",
}


@dataclass
class RepoAudit:
    repo: str
    env_files: list[str]
    local_secret_env_files: list[str]
    doc_env_files: list[str]
    ignored_local_secret_env_files: list[str]
    unignored_local_secret_env_files: list[str]
    tracked_secret_env_files: list[str]
    referenced_vars: list[str]
    local_env_keys: list[str]
    doc_env_keys: list[str]
    missing_from_local_env: list[str]
    missing_from_any_env_doc: list[str]


def is_probably_text(path: Path) -> bool:
    if path.suffix.lower() in TEXT_EXTENSIONS:
        return True
    return path.name.startswith(".env")


def should_skip_file(path: Path) -> bool:
    try:
        if path.stat().st_size > 1_000_000:
            return True
    except OSError:
        return True
    return False


def iter_repos(root: Path) -> list[Path]:
    repos: list[Path] = []
    for child in sorted(root.iterdir()):
        if child.is_dir() and (child / ".git").is_dir():
            repos.append(child)
    if (root / ".git").is_dir():
        repos.append(root)
    return repos


def list_env_files(repo: Path) -> list[Path]:
    files: list[Path] = []
    for current_root, dirs, filenames in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]
        for name in filenames:
            rel = Path(current_root, name).relative_to(repo).as_posix()
            if ENV_FILE_RE.search(rel):
                files.append(repo / rel)
    return sorted(files)


def git_check_ignored(repo: Path, relpath: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), "check-ignore", "-q", relpath],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def git_is_tracked(repo: Path, relpath: str) -> bool:
    """Return True if relpath is tracked by git (committed or staged).

    A file that is gitignored but was committed before the ignore rule
    is still tracked — this is the worst-case env-file leak.
    """
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "--error-unmatch", relpath],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def parse_env_keys(path: Path) -> set[str]:
    keys: set[str] = set()
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return keys
    for line in text.splitlines():
        match = ASSIGNMENT_RE.match(line)
        if match:
            keys.add(match.group(1))
    return keys


def extract_referenced_vars(repo: Path) -> set[str]:
    found: set[str] = set()
    for current_root, dirs, filenames in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]
        for name in filenames:
            path = Path(current_root, name)
            if not is_probably_text(path):
                continue
            if should_skip_file(path):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for pattern in ENV_VAR_PATTERNS:
                for match in pattern.finditer(text):
                    value = match.group(1)
                    if value and value not in NOISE_VARS:
                        found.add(value)
    return found


def audit_repo(repo: Path) -> RepoAudit:
    env_files = list_env_files(repo)
    doc_env_files = [
        p for p in env_files if DOC_ENV_FILE_RE.search(p.relative_to(repo).as_posix())
    ]
    local_secret_env_files = [
        p
        for p in env_files
        if SECRET_ENV_FILE_RE.search(p.relative_to(repo).as_posix())
        and p not in doc_env_files
    ]

    ignored_local_secret_env_files: list[str] = []
    unignored_local_secret_env_files: list[str] = []
    tracked_secret_env_files: list[str] = []
    for path in local_secret_env_files:
        rel = path.relative_to(repo).as_posix()
        if git_check_ignored(repo, rel):
            ignored_local_secret_env_files.append(rel)
        else:
            unignored_local_secret_env_files.append(rel)
        if git_is_tracked(repo, rel):
            tracked_secret_env_files.append(rel)

    local_env_keys: set[str] = set()
    for path in local_secret_env_files:
        local_env_keys |= parse_env_keys(path)

    doc_env_keys: set[str] = set()
    for path in doc_env_files:
        doc_env_keys |= parse_env_keys(path)

    referenced_vars = extract_referenced_vars(repo)

    missing_from_local_env = sorted(
        var for var in referenced_vars if var not in local_env_keys
    )
    missing_from_any_env_doc = sorted(
        var for var in referenced_vars if var not in (local_env_keys | doc_env_keys)
    )

    return RepoAudit(
        repo=repo.name,
        env_files=[p.relative_to(repo).as_posix() for p in env_files],
        local_secret_env_files=[
            p.relative_to(repo).as_posix() for p in local_secret_env_files
        ],
        doc_env_files=[p.relative_to(repo).as_posix() for p in doc_env_files],
        ignored_local_secret_env_files=sorted(ignored_local_secret_env_files),
        unignored_local_secret_env_files=sorted(unignored_local_secret_env_files),
        tracked_secret_env_files=sorted(tracked_secret_env_files),
        referenced_vars=sorted(referenced_vars),
        local_env_keys=sorted(local_env_keys),
        doc_env_keys=sorted(doc_env_keys),
        missing_from_local_env=missing_from_local_env,
        missing_from_any_env_doc=missing_from_any_env_doc,
    )


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd().resolve()
    repos = iter_repos(root)
    audits = [audit_repo(repo) for repo in repos]
    result = {
        "root": str(root),
        "repo_count": len(audits),
        "repos": [
            {
                "repo": audit.repo,
                "env_files": audit.env_files,
                "local_secret_env_files": audit.local_secret_env_files,
                "doc_env_files": audit.doc_env_files,
                "ignored_local_secret_env_files": audit.ignored_local_secret_env_files,
                "unignored_local_secret_env_files": audit.unignored_local_secret_env_files,
                "tracked_secret_env_files": audit.tracked_secret_env_files,
                "referenced_var_count": len(audit.referenced_vars),
                "local_env_key_count": len(audit.local_env_keys),
                "doc_env_key_count": len(audit.doc_env_keys),
                "missing_from_local_env": audit.missing_from_local_env,
                "missing_from_any_env_doc": audit.missing_from_any_env_doc,
            }
            for audit in audits
        ],
    }
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
