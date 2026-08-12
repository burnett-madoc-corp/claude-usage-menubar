#!/usr/bin/env python3
"""Validate a pull request title against the [type][scope] naming convention.

Grammar::

    [type][scope] imperative summary
    [type][scope][scope] imperative summary

Usage::

    python validate_pr_title.py "[feat][ai] add PR-raising skill"
    echo "[fix][data] correct FX conversion" | python validate_pr_title.py
    python validate_pr_title.py --list

Exit 0 when the title conforms (warnings do not fail), 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

TYPES = {
    "feat": "New capability a user or downstream system can observe",
    "fix": "Bug fix — behaviour was wrong, now it is right",
    "chore": "Dependencies, config, housekeeping, version bumps",
    "docs": "Documentation only — no code behaviour change",
    "refactor": "Behaviour-preserving restructure",
    "test": "Tests only — no production code change",
    "ci": "Pipelines, workflows, runners, automation plumbing",
    "perf": "Speed, cost, or resource wins with no behaviour change",
}

SCOPES = {
    "product": "User-facing app, features, UI, product surface",
    "infrastructure": "Deploy, hosting, IaC, runners, networking, servers",
    "ai": "Prompts, models, skills, agents, LLM tooling",
    "data": "Models, pipelines, warehouse, transformations, ingestion",
    "ci": "Workflows, checks, PR automation, merge gates",
    "docs": "Readmes, plans, guides, purpose files",
    "security": "Secrets, auth, permissions, access control",
}

MAX_LENGTH = 72
MIN_SUMMARY_LENGTH = 3
MAX_SCOPES = 2

TITLE_RE = re.compile(r"^((?:\[[^\[\]]*\])+)\s*(.*)$")
TAG_RE = re.compile(r"\[([^\[\]]*)\]")

# Common past-tense / third-person openers that are not imperative mood.
NON_IMPERATIVE_RE = re.compile(
    r"^(added|adds|adding|fixed|fixes|fixing|updated|updates|updating|"
    r"removed|removes|removing|changed|changes|changing|created|creates|"
    r"creating|bumped|bumps|refactored|refactors|implemented|implements)\b",
    re.IGNORECASE,
)


def validate(title: str) -> tuple[list[str], list[str], dict[str, object]]:
    """Return (errors, warnings, parsed) for a candidate PR title."""
    errors: list[str] = []
    warnings: list[str] = []
    parsed: dict[str, object] = {"type": None, "scopes": [], "summary": None}

    title = title.strip()
    if not title:
        return ["title is empty"], warnings, parsed

    # A draft marker is added by GitHub's UI, not the title itself; tolerate it.
    stripped = re.sub(r"^(WIP|DRAFT)\s*[:\-]\s*", "", title, flags=re.IGNORECASE)
    if stripped != title:
        warnings.append(
            "drop the WIP/DRAFT prefix — use `gh pr create --draft` instead"
        )
        title = stripped

    match = TITLE_RE.match(title)
    if not match:
        errors.append(
            "must start with bracket tags, e.g. `[feat][product] add saved-view switcher`"
        )
        return errors, warnings, parsed

    tags = TAG_RE.findall(match.group(1))
    summary = match.group(2)

    if not title.startswith("["):
        errors.append("title must start with `[` — no text before the tags")

    if len(tags) < 2:
        errors.append(
            f"need a type and at least one scope, got {len(tags)} tag(s): "
            f"{''.join(f'[{t}]' for t in tags)}"
        )
        return errors, warnings, parsed

    change_type, scopes = tags[0], tags[1:]
    parsed["type"] = change_type
    parsed["scopes"] = scopes
    parsed["summary"] = summary

    if change_type != change_type.strip():
        errors.append(
            f"type `[{change_type}]` has stray whitespace inside the brackets"
        )
    if change_type.lower() != change_type:
        errors.append(f"type `[{change_type}]` must be lowercase")
    if change_type.strip().lower() not in TYPES:
        errors.append(
            f"unknown type `[{change_type}]` — allowed: {', '.join(sorted(TYPES))}"
        )

    if len(scopes) > MAX_SCOPES:
        errors.append(
            f"at most {MAX_SCOPES} scopes, got {len(scopes)}: "
            f"{''.join(f'[{s}]' for s in scopes)}"
        )

    for scope in scopes:
        if scope != scope.strip():
            errors.append(f"scope `[{scope}]` has stray whitespace inside the brackets")
        if scope.lower() != scope:
            errors.append(f"scope `[{scope}]` must be lowercase")
        if scope.strip().lower() not in SCOPES:
            errors.append(
                f"unknown scope `[{scope}]` — allowed: {', '.join(sorted(SCOPES))}"
            )

    if len(set(scopes)) != len(scopes):
        errors.append("duplicate scope tags")

    # Summary checks.
    separator = title[len(match.group(1)) : len(title) - len(summary)]
    if summary and separator != " ":
        warnings.append("use exactly one space between the last `]` and the summary")

    if len(summary.strip()) < MIN_SUMMARY_LENGTH:
        errors.append("summary is missing or too short — describe the change")
    else:
        if summary.endswith("."):
            errors.append("summary must not end with a full stop")
        if summary[0].isupper() and not summary.split()[0].isupper():
            warnings.append("summary should start lowercase")
        if NON_IMPERATIVE_RE.match(summary):
            warnings.append(
                "summary should use imperative mood (`add`, not `added`/`adds`)"
            )

    if len(title) > MAX_LENGTH:
        errors.append(f"title is {len(title)} chars, limit is {MAX_LENGTH}")

    return errors, warnings, parsed


def _print_reference() -> None:
    print("Types:")
    for name, desc in TYPES.items():
        print(f"  [{name}]{' ' * (10 - len(name))} {desc}")
    print("\nScopes:")
    for name, desc in SCOPES.items():
        print(f"  [{name}]{' ' * (16 - len(name))} {desc}")
    print("\nGrammar: [type][scope] imperative summary")
    print("Example: [feat][product] add saved-view switcher to the cockpit header")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("title", nargs="?", help="PR title (defaults to stdin)")
    parser.add_argument(
        "--list", action="store_true", help="print allowed types and scopes, then exit"
    )
    parser.add_argument("--json", action="store_true", help="emit a JSON result")
    args = parser.parse_args(argv)

    if args.list:
        _print_reference()
        return 0

    title = args.title if args.title is not None else sys.stdin.read()
    errors, warnings, parsed = validate(title)

    if args.json:
        print(
            json.dumps(
                {
                    "title": title.strip(),
                    "ok": not errors,
                    "errors": errors,
                    "warnings": warnings,
                    **parsed,
                },
                indent=2,
            )
        )
        return 1 if errors else 0

    for warning in warnings:
        print(f"WARN: {warning}")
    for error in errors:
        print(f"FAIL: {error}")

    if errors:
        print(f"\nInvalid title: {title.strip()!r}")
        print("Expected: [type][scope] imperative summary")
        print("Run with --list to see allowed types and scopes.")
        return 1

    scopes = "".join(f"[{s}]" for s in parsed["scopes"])
    print(f"OK: type=[{parsed['type']}] scopes={scopes} summary={parsed['summary']!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
