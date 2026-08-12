#!/usr/bin/env python3
"""Structural/hygiene checks that a Swift compile does not cover.

WHY THIS EXISTS
----------------
CI builds the app with `swiftc` and runs `--self-test` on a hosted macOS
runner, so compilation and behaviour are genuinely verified there. This
script covers the things a compiler has no opinion about: file encoding,
leftover debug instrumentation, and whether build.sh's hand-maintained
file list still matches the tree.

This repo has no Package.swift -- build.sh names every source file
explicitly on its `swiftc` line -- which makes that last check load
bearing. It runs in a second on any machine with Python 3 and no
third-party packages, so it is also worth running locally before pushing.

WHAT THIS VERIFIES
-------------------
1. Every git-tracked text file is valid UTF-8 with no BOM and no CRLF
   line endings.
2. No unresolved git merge-conflict markers anywhere in the tree.
3. No obvious debugger/debug-logging leftovers in the Swift sources
   (NSLog, debugPrint, ad-hoc "DEBUG" prints, SIGTRAP breakpoints).
4. build.sh's own references are internally consistent: every Sources/
   file and Resources/*-template.svg it compiles/copies actually exists,
   and the Info.plist it generates is well-formed XML.
5. Resources/*.svg are well-formed XML.

Note that it only inspects git-tracked files, so `git add` a new source
before relying on a green run here.
"""
from __future__ import annotations

import re
import subprocess
import sys
import xml.dom.minidom as minidom
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

DEBUG_LEFTOVER_PATTERNS = [
    re.compile(r"\bNSLog\("),
    re.compile(r"\bdebugPrint\("),
    re.compile(r'print\(\s*"DEBUG'),
    re.compile(r"//\s*DEBUG:"),
    re.compile(r"raise\(SIGTRAP\)"),
]

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)
    print(f"FAIL: {msg}")


def tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=REPO_ROOT, check=True, capture_output=True, text=True
    ).stdout
    return [REPO_ROOT / line for line in out.splitlines() if line]


def check_encoding_and_line_endings(files: list[Path]) -> None:
    for f in files:
        raw = f.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            fail(f"{f.relative_to(REPO_ROOT)}: has a UTF-8 BOM")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as e:
            fail(f"{f.relative_to(REPO_ROOT)}: not valid UTF-8 ({e})")
            continue
        if "\r\n" in text or "\r" in text:
            fail(f"{f.relative_to(REPO_ROOT)}: contains CRLF/CR line endings")


def check_no_conflict_markers(files: list[Path]) -> None:
    marker_re = re.compile(r"^(<{7}(?!=)|={7}$|>{7} )", re.MULTILINE)
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue  # already reported above
        if marker_re.search(text):
            fail(f"{f.relative_to(REPO_ROOT)}: contains an unresolved merge-conflict marker")


def check_no_debug_leftovers(swift_files: list[Path]) -> None:
    for f in swift_files:
        text = f.read_text(encoding="utf-8")
        for lineno, line in enumerate(text.splitlines(), start=1):
            for pat in DEBUG_LEFTOVER_PATTERNS:
                if pat.search(line):
                    fail(f"{f.relative_to(REPO_ROOT)}:{lineno}: debug leftover matches {pat.pattern!r}")


def check_not_empty(swift_files: list[Path]) -> None:
    for f in swift_files:
        if not f.read_text(encoding="utf-8").strip():
            fail(f"{f.relative_to(REPO_ROOT)}: file is empty")


def check_build_sh_manifest(build_sh: Path) -> None:
    text = build_sh.read_text(encoding="utf-8")

    for m in re.finditer(r"Sources/[\w.]+\.swift", text):
        p = REPO_ROOT / m.group(0)
        if not p.is_file():
            fail(f"build.sh references {m.group(0)} which does not exist")

    for m in re.finditer(r"Resources/\*-template\.svg", text):
        matches = list((REPO_ROOT / "Resources").glob("*-template.svg"))
        if not matches:
            fail(f"build.sh references {m.group(0)} but no matching files exist")

    plist_match = re.search(r"<<'PLIST'\n(.*?)\nPLIST\n", text, re.DOTALL)
    if plist_match is None:
        fail("build.sh: could not find the embedded Info.plist heredoc to validate")
    else:
        plist_xml = plist_match.group(1)
        try:
            minidom.parseString(plist_xml)
        except Exception as e:  # noqa: BLE001 - report any parse failure
            fail(f"build.sh: embedded Info.plist is not well-formed XML ({e})")


def check_svg_well_formed(svg_files: list[Path]) -> None:
    for f in svg_files:
        try:
            minidom.parse(str(f))
        except Exception as e:  # noqa: BLE001
            fail(f"{f.relative_to(REPO_ROOT)}: not well-formed XML/SVG ({e})")


def main() -> int:
    files = tracked_files()
    swift_files = [f for f in files if f.suffix == ".swift"]
    svg_files = [f for f in files if f.suffix == ".svg"]
    build_sh = REPO_ROOT / "build.sh"

    check_encoding_and_line_endings(files)
    check_no_conflict_markers(files)
    check_no_debug_leftovers(swift_files)
    check_not_empty(swift_files)
    if build_sh.is_file():
        check_build_sh_manifest(build_sh)
    check_svg_well_formed(svg_files)

    if failures:
        print(f"\n{len(failures)} static check(s) failed.")
        return 1
    print(f"All static checks passed ({len(files)} tracked files, {len(swift_files)} Swift sources).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
