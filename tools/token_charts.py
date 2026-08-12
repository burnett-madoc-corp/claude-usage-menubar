#!/usr/bin/env python3
"""Generate docs/charts/*.svg for docs/token-metering.md from measured sessions.

WHY THIS EXISTS
---------------
The first version of these charts was hand-authored. Their numbers drifted
apart: the cumulative chart said a 100-turn session metered 5M input while the
per-turn chart's own ramp integrated to ~7.4M, a growth annotation claimed 4x
per doubling on points that measured 2.5-2.9x, and a fitted curve missed its
own labelled dot by 10.6%. Every one of those is a consequence of seven files
each carrying their own copy of the numbers.

So the numbers now have exactly one source: this script measures them from the
local Claude Code transcripts and emits all seven charts from that one dataset.
Two charts cannot disagree about a quantity neither of them stores.

USAGE
-----
    python3 tools/token_charts.py            # regenerate docs/charts/*.svg
    python3 tools/token_charts.py --dump     # print the measured dataset only

The transcripts live outside the repo (~/.claude/projects/), so this is a
snapshot tool, not a build step: the committed SVGs are the artefact, and the
doc records the dataset they came from. Re-running on a different machine
measures that machine's sessions and will legitimately produce different
numbers.

HOW A SESSION IS MEASURED
-------------------------
Per-request `usage` records repeat in the JSONL, so they are deduped on
requestId (they inflate ~1.8x otherwise). The context carried into a request
is input_tokens + cache_read_input_tokens + cache_creation_input_tokens; that
sum, not input_tokens alone, is what the window and the bill see.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CHART_DIR = REPO_ROOT / "docs" / "charts"
TRANSCRIPTS = "~/.claude/projects/*/*.jsonl"

# One colour, one meaning -- across the whole set, not per chart.
# Data categories are categorical hues; RED is reserved for limit lines and is
# never a data category, so a reader carrying the legend between charts cannot
# misread a bar as a severity grade.
CARD = "#101014"
TEXT = "#e8e8e8"
MUTED = "#9a9aa2"
GRID = "#26262c"
FLOOR = "#6aa5ff"    # system prompt + tools -- the fixed part of every request
HISTORY = "#ff9f0a"  # earlier turns replayed
NEW = "#32d74b"      # the new message on this turn
OUTPUT = "#bf5af2"   # model output -- distinct from NEW, which it is not
CACHE = "#4a4a54"    # cache read
LIMIT = "#ff453a"    # window / auto-compact lines only

MONO = "ui-monospace,&#39;SF Mono&#39;,Menlo,Consolas,monospace"
W = 860


def esc(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("'", "&#39;")
    )


def text(x, y, s, *, size=11, fill=MUTED, anchor="start", bold=False):
    weight = "bold" if bold else "normal"
    return (
        f'<text x="{x}" y="{y}" font-family="{MONO}" font-size="{size}" '
        f'fill="{fill}" text-anchor="{anchor}" font-weight="{weight}">{esc(s)}</text>'
    )


def rect(x, y, w, h, fill, *, opacity=1.0, rx=3):
    o = "" if opacity == 1.0 else f' opacity="{opacity}"'
    return f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" fill="{fill}"{o} rx="{rx}"></rect>'


def line(x1, y1, x2, y2, stroke, *, dash=None, width=1.0):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return (
        f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}" '
        f'stroke="{stroke}"{d} stroke-width="{width}"></line>'
    )


def svg(height, body) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" '
        f'viewBox="0 0 {W} {height}">'
        f'<rect width="{W}" height="{height}" rx="10" fill="{CARD}"></rect>'
        + "".join(body)
        + "</svg>\n"
    )


def fmt_k(v: float) -> str:
    return f"{v / 1000:.0f}k"


def fmt_m(v: float) -> str:
    m = v / 1e6
    return f"{m:.1f}M" if m < 10 else f"{m:.0f}M"


def nice_top(v: float) -> float:
    """Round an axis maximum up to a 1/2/5 x 10**n step, so gridlines land on
    readable numbers instead of max/4."""
    import math

    step = 10 ** math.floor(math.log10(v / 4))
    for mult in (1, 2, 2.5, 5, 10):
        if step * mult * 4 >= v:
            return step * mult * 4
    return v


# --------------------------------------------------------------------------
# measurement
# --------------------------------------------------------------------------

def measure() -> list[dict]:
    """Return one dict per real session, with per-turn context and totals."""
    sessions = []
    for path in glob.glob(os.path.expanduser(TRANSCRIPTS)):
        if "pytest" in path:
            continue
        seen: set[str] = set()
        ctx: list[int] = []
        cache_read: list[int] = []
        fresh: list[int] = []
        out: list[int] = []
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for raw in fh:
                    if '"usage"' not in raw:
                        continue
                    try:
                        rec = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    msg = rec.get("message") or {}
                    usage = msg.get("usage") or rec.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    rid = rec.get("requestId") or msg.get("id")
                    if not rid or rid in seen:
                        continue
                    seen.add(rid)
                    inp = usage.get("input_tokens") or 0
                    read = usage.get("cache_read_input_tokens") or 0
                    creat = usage.get("cache_creation_input_tokens") or 0
                    total = inp + read + creat
                    if total <= 0:
                        continue
                    ctx.append(total)
                    cache_read.append(read)
                    fresh.append(inp + creat)
                    out.append(usage.get("output_tokens") or 0)
        except OSError:
            continue
        if len(ctx) >= 5:
            sessions.append(
                {
                    "ctx": ctx,
                    "cache_read": cache_read,
                    "fresh": fresh,
                    "out": out,
                    "output": sum(out),
                    "turns": len(ctx),
                    "total": sum(ctx),
                }
            )
    sessions.sort(key=lambda s: s["turns"])
    return sessions


BANDS = [(5, 25), (25, 50), (50, 100), (100, 200), (200, 400), (400, 700), (700, None)]


def band_label(lo, hi) -> str:
    return f"{lo}–{hi}" if hi else f"{lo}+"


def derive(sessions: list[dict]) -> dict:
    """Collapse the sessions into the handful of numbers the charts state."""
    floor = statistics.median(s["ctx"][0] for s in sessions)

    bands = []
    for lo, hi in BANDS:
        grp = [s for s in sessions if lo <= s["turns"] < (hi or 10**9)]
        if not grp:
            continue
        bands.append(
            {
                "label": band_label(lo, hi),
                "n": len(grp),
                "per_turn": statistics.median(s["total"] / s["turns"] for s in grp),
                "total": statistics.median(s["total"] for s in grp),
                "turns": statistics.median(s["turns"] for s in grp),
            }
        )

    # ONE cohort drives charts 01, 02, 03, 05, 06 and 07: sessions that reached
    # 100 turns, measured at each turn index. Restricting to a single cohort is
    # what stops two charts describing different populations of session while
    # appearing to describe the same one -- the subtler form of the drift this
    # script exists to prevent. Chart 04 is the deliberate exception and says so.
    cohort = [s for s in sessions if s["turns"] >= 100]
    med = lambda key, i: statistics.median(s[key][i] for s in cohort)
    ramp = [med("ctx", i) for i in range(100)]
    fresh_ramp = [med("fresh", i) for i in range(100)]
    out_ramp = [med("out", i) for i in range(100)]
    cache_ramp = [med("cache_read", i) for i in range(100)]

    # Cumulative is the median of each session's OWN running total, not the
    # running total of the per-turn medians: medians do not sum, and the
    # difference is exactly the kind of quiet arithmetic slip that put a 5M and
    # a 7.4M claim about the same session into the same document.
    ramp_cum = [
        statistics.median(sum(s["ctx"][: i + 1]) for s in cohort) for i in range(100)
    ]
    out_cum = [
        statistics.median(sum(s["out"][: i + 1]) for s in cohort) for i in range(100)
    ]

    # Three real sessions for the panel mock, so the numbers it shows tally
    # with the band chart instead of being invented plausible-looking ones.
    def xfloor(s):
        first = statistics.median(s["ctx"][:5])
        last = statistics.median(s["ctx"][-5:])
        return last / first if first else 0.0

    picks = sorted(cohort, key=lambda s: s["turns"])
    panel = [
        {
            "turns": s["turns"],
            "input": sum(s["ctx"]),
            "output": sum(s["out"]),
            "xfloor": xfloor(s),
            "context": s["ctx"][-1],
        }
        for s in (picks[len(picks) // 6], picks[len(picks) // 2], picks[-2])
    ] if len(picks) >= 3 else []

    return {
        "sessions": len(sessions),
        "requests": sum(s["turns"] for s in sessions),
        "floor": floor,
        "panel": panel,
        "bands": bands,
        "cohort": len(cohort),
        "ramp": ramp,
        "ramp_cum": ramp_cum,
        "fresh": fresh_ramp,
        "out": out_ramp,
        "out_cum": out_cum,
        "cache": cache_ramp,
    }


def growth_exponent(cum: list[float]) -> tuple[float, float]:
    """Fit cumulative ~ turns**k over the measured curve; and per doubling.

    Computed from the curve the annotation sits on, so the claim cannot drift
    away from the points beneath it.
    """
    import math

    k = math.log(cum[99] / cum[24]) / math.log(100 / 25)
    return k, 2**k


def split(d: dict, i: int) -> tuple[float, float, float]:
    """The measured three-way split of turn i's input.

    fixed   -- median turn-1 context: system prompt + tools + first message.
    history -- everything replayed since, i.e. the rest of the cached prefix.
    new     -- input_tokens + cache_creation_input_tokens, the new material.
    """
    total = d["ramp"][i]
    new = d["fresh"][i]
    fixed = min(d["floor"], total - new)
    return fixed, max(0.0, total - fixed - new), new


# --------------------------------------------------------------------------
# charts
# --------------------------------------------------------------------------

def chart_01(d) -> str:
    """Anatomy of one turn, at the measured mid-session size."""
    fixed, history, new = split(d, 49)
    total = fixed + history + new
    parts = [
        (fixed, FLOOR, "system prompt + tools"),
        (history, HISTORY, "history — every earlier turn, verbatim"),
        (new, NEW, "new this turn"),
    ]
    body = [
        text(32, 40, "Anatomy of one turn", size=16, fill=TEXT, bold=True),
        text(32, 64, "Input metered on a single mid-session request — turn 50, measured"),
    ]
    x, span = 80, 700
    for value, colour, _ in parts:
        w = span * value / total
        body.append(rect(x, 110, w, 44, colour))
        x += w + 2
    body.append(text(x + 12, 138, f"{fmt_k(total)} in", size=12, fill=TEXT))
    # Stacked, not laid out under the segments: the "new this turn" slice is
    # ~1k of 123k and six pixels wide, so a label under it would either collide
    # with its neighbour or point at nothing.
    ly = 190
    for value, colour, label in parts + [(d["out"][49], OUTPUT, "output (not input — shown for scale)")]:
        body.append(rect(80, ly - 11, 14, 14, colour, rx=3))
        body.append(text(102, ly, label, fill=colour))
        body.append(text(560, ly, fmt_k(value), fill=TEXT, anchor="end"))
        ly += 24
    return svg(ly + 8, body)


def chart_02(d) -> str:
    """Cumulative input -- the running sum of the SAME ramp chart 07 splits."""
    cum = d["ramp_cum"]
    max_v = nice_top(cum[-1])
    x0, x1, y0, y1 = 90, 810, 330, 100
    sx = lambda t: x0 + (x1 - x0) * t / 100.0
    sy = lambda v: y1 + (y0 - y1) * (1 - v / max_v)

    body = [
        text(32, 40, "Total input, cumulative", size=16, fill=TEXT, bold=True),
        text(32, 64, f"Median of {d['cohort']} measured sessions that ran past 100 turns"),
    ]
    for i in range(5):
        v = max_v * i / 4
        y = sy(v)
        body.append(line(x0, y, x1, y, GRID))
        body.append(text(x0 - 10, y + 4, fmt_m(v) if v else "0", anchor="end"))
    for t in range(0, 101, 25):
        body.append(text(sx(t), 350, str(t), anchor="middle"))
    body.append(text((x0 + x1) / 2, 370, "turns", anchor="middle"))

    # The polyline IS the data -- every turn, no fit -- so a labelled point
    # cannot sit off the line that annotates it.
    path = " ".join(f"{sx(i + 1):.1f},{sy(v):.1f}" for i, v in enumerate(cum))
    body.append(
        f'<polyline points="{path}" fill="none" stroke="{HISTORY}" stroke-width="2"></polyline>'
    )
    for t in (25, 50, 100):
        v = cum[t - 1]
        body.append(
            f'<circle cx="{sx(t):.1f}" cy="{sy(v):.1f}" r="4" fill="{HISTORY}"></circle>'
        )
        # Above-and-left of the dot: the curve rises left-to-right, so that
        # quadrant is the one guaranteed clear of it. Enforced by
        # tools/check_charts.py, which is how the original set's struck-through
        # labels would have been caught.
        body.append(text(sx(t) - 10, sy(v) - 12, fmt_m(v), fill=TEXT, anchor="end"))

    k, per_doubling = growth_exponent(cum)
    body.append(
        text(120, 126,
             f"2× the turns ≈ {per_doubling:.1f}× the input — "
             f"measured exponent {k:.2f}", size=12)
    )
    return svg(390, body)


def chart_03(d) -> str:
    """Context filling. Window is stated as this model's, not the window."""
    ramp = d["ramp"]
    window = 200_000
    x0, x1, y0 = 90, 810, 330
    top = 97.62
    sy = lambda v: y0 - (y0 - top) * v / window
    sx = lambda i: x0 + (x1 - x0) * i / (len(ramp) - 1)

    body = [text(32, 40, "The context window filling up", size=16, fill=TEXT, bold=True)]
    for i in range(5):
        v = window * i / 4
        y = sy(v)
        body.append(line(x0, y, x1, y, GRID))
        body.append(text(x0 - 10, y + 4, fmt_k(v) if v else "0", anchor="end"))
    for i in range(0, 101, 25):
        body.append(text(sx(i), 350, str(i), anchor="middle"))
    body.append(text((x0 + x1) / 2, 370, "turns", anchor="middle"))

    floor_y = sy(d["floor"])
    pts = [(sx(i), sy(v)) for i, v in enumerate(ramp)]
    path = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    body.append(
        f'<polygon points="{path} {x1},{y0} {x0},{y0}" fill="{HISTORY}" opacity="0.45"></polygon>'
    )
    body.append(
        f'<polyline points="{path}" fill="none" stroke="{HISTORY}" stroke-width="2"></polyline>'
    )
    # After the area, not before: drawn underneath, the orange fill tints the
    # floor band brown and blue stops meaning "the fixed part".
    body.append(rect(x0, floor_y, x1 - x0, y0 - floor_y, FLOOR, opacity=0.55, rx=0))
    body.append(line(x0, sy(window), x1, sy(window), LIMIT, dash="6 4", width=1.5))
    body.append(
        text(x1, sy(window) - 8, "window: 200k on this model — 1M on others",
             fill=LIMIT, anchor="end")
    )
    body.append(line(x0, sy(window * 0.8), x1, sy(window * 0.8), HISTORY, dash="3 4"))
    # Left end, not right: the curve reaches this line near the right edge, so
    # a right-anchored label here is exactly the struck-through case.
    body.append(
        text(x0 + 8, sy(window * 0.8) - 8, "80% — auto-compact", fill=HISTORY)
    )
    body.append(text(x0 + 14, y0 - 8, "fixed floor: system prompt + tools", fill=FLOOR))
    # Placed high and left where the band is tall; clearance is checked by
    # tools/check_charts.py rather than by eye.
    body.append(text(x0 + 30, sy(window * 0.62), "history + tool-result bloat", fill=HISTORY))
    return svg(390, body)


def chart_04(d) -> str:
    """Per-turn cost by band. One hue: length is not a severity grade."""
    bands = d["bands"]
    floor = d["floor"]
    top = max(b["per_turn"] for b in bands)
    labels = [f"{fmt_k(b['per_turn'])} · {b['per_turn'] / floor:.1f}× floor" for b in bands]
    # Carry n per band: 5-25 and 700+ rest on a single session each, and a bar
    # that thin should not look as solid as one backed by sixteen.
    totals = [f"{fmt_m(b['total'])} · n={b['n']}" for b in bands]
    # Size the bars from the widest label so the value text cannot run into the
    # session-total column. Measuring what fits beats a width-per-character
    # guess; 0.62em is the mono advance the checker also assumes.
    lab_w = max(len(s) for s in labels) * 0.62 * 12
    tot_w = max(len(s) for s in totals) * 0.62 * 12
    x0 = 230
    span = (828 - tot_w - 24) - lab_w - 12 - x0
    body = [
        text(32, 40, "Average input per turn, by session length", size=16, fill=TEXT, bold=True),
        text(32, 64, f"Median across {d['sessions']} measured sessions — every "
                     f"session length, unlike the other charts' 100-turn cohort"),
    ]
    body.append(text(828, 96, "session total", anchor="end"))
    fx = x0 + span * floor / top
    body.append(line(fx, 110, fx, 108 + 40 * len(bands), FLOOR, dash="4 4"))
    body.append(text(fx + 6, 100, f"floor ≈ {fmt_k(floor)}/turn", fill=FLOOR))
    y = 116
    for i, b in enumerate(bands):
        w = span * b["per_turn"] / top
        body.append(text(216, y + 18, b["label"], size=12, fill=TEXT, anchor="end"))
        body.append(rect(x0, y, w, 26, HISTORY, opacity=0.85))
        body.append(text(x0 + w + 12, y + 18, labels[i], size=12, fill=HISTORY))
        body.append(text(828, y + 18, totals[i], size=12, anchor="end"))
        y += 40
    return svg(y + 24, body)


def chart_05(d) -> str:
    """Cache vs fresh, on the same turn scale as every other chart."""
    cache = list(zip(d["cache"][:10], d["fresh"][:10]))
    top = nice_top(max(r + f for r, f in cache) * 1.15)
    x0, y0, ytop = 90, 300, 90
    sy = lambda v: y0 - (y0 - ytop) * v / top
    body = [text(32, 40, "Cache reads vs fresh input", size=16, fill=TEXT, bold=True)]
    body.append(rect(120, 54, 12, 12, CACHE, rx=2))
    body.append(text(140, 65, "cache read, ~10× cheaper"))
    body.append(rect(410, 54, 12, 12, NEW, rx=2))
    body.append(text(430, 65, "fresh input"))
    for i in range(4):
        v = top * i / 3
        body.append(line(x0, sy(v), 810, sy(v), GRID))
        body.append(text(x0 - 10, sy(v) + 4, fmt_k(v) if v else "0", anchor="end"))
    bw, gap = 44, 68
    for i, (read, fresh) in enumerate(cache):
        x = 120 + i * gap
        body.append(rect(x, sy(read), bw, y0 - sy(read), CACHE, rx=2))
        body.append(rect(x, sy(read + fresh), bw, sy(read) - sy(read + fresh), NEW, rx=2))
        body.append(text(x + bw / 2, y0 + 20, str(i + 1), anchor="middle"))
    body.append(text((x0 + 810) / 2, y0 + 40, "turn", anchor="middle"))
    # Turn 1 is a cold cache by definition, so quoting the range from it reads
    # as "0% cached" rather than as the cold start it is. State the steady
    # state and name the cold turn separately.
    shares = [r / (r + f) for r, f in cache]
    body.append(
        text(120, sy(top) + 14,
             f"turn 1 is a cold start; {max(shares) * 100:.0f}% cached by turn "
             f"{len(cache)} — if the prefix stays byte-stable", size=12)
    )
    return svg(370, body)


def chart_06(d) -> str:
    """Output vs input, for the SAME cohort chart 02 and 07 describe."""
    turns = 100
    total_in = d["ramp_cum"][turns - 1]
    total_out = d["out_cum"][turns - 1]
    x0, span = 200, 600
    body = [
        text(32, 40, f"Output vs input, one {turns}-turn session", size=16, fill=TEXT, bold=True),
        # Thinking tokens are billed as output but are not written to the
        # transcript, so the recorded figure is a floor. Saying so on the chart
        # keeps the multiple from reading as more precise than it is.
        text(32, 64, "output_tokens as recorded — extended thinking is not in the "
                     "transcript, so output is understated"),
    ]
    body.append(text(180, 124, "input", size=12, fill=TEXT, anchor="end"))
    body.append(rect(x0, 104, span, 30, HISTORY, opacity=0.85))
    body.append(text(x0 + span - 12, 124, fmt_m(total_in), size=12, fill=CARD, bold=True, anchor="end"))
    ow = max(6, span * total_out / total_in)
    body.append(text(180, 174, "output", size=12, fill=TEXT, anchor="end"))
    body.append(rect(x0, 154, ow, 30, OUTPUT))
    body.append(
        text(x0 + ow + 14, 174,
             f"{fmt_k(total_out)} — {total_in / total_out:.0f}× less",
             size=12, fill=OUTPUT)
    )
    return svg(230, body)


def chart_07(d) -> str:
    """Composition per turn -- same ramp chart 02's totals integrate from."""
    body = [
        text(32, 40, "What each turn’s input is made of", size=16, fill=TEXT, bold=True),
        text(32, 64, "Share of input per request — history crowds out everything else"),
    ]
    for sx, colour, label in (
        (280, FLOOR, f"system + tools {fmt_k(d['floor'])}"),
        (520, HISTORY, "history"),
        (700, NEW, "new this turn"),
    ):
        body.append(rect(sx, 88, 12, 12, colour, rx=2))
        body.append(text(sx + 20, 99, label))
    x0, span = 140, 600
    y = 118
    for n in range(10, 101, 10):
        fixed, hist, new = split(d, n - 1)
        total = fixed + hist + new
        body.append(text(126, y + 18, f"turn {n}", size=12, fill=TEXT, anchor="end"))
        x = x0
        for value, colour in ((fixed, FLOOR), (hist, HISTORY), (new, NEW)):
            w = span * value / total
            body.append(rect(x, y, w, 26, colour, rx=2))
            share = 100 * value / total
            if w > 34:
                body.append(
                    text(x + w / 2, y + 18, f"{share:.0f}%", size=12, fill=CARD,
                         anchor="middle", bold=True)
                )
            x += w
        body.append(text(x0 + span + 14, y + 18, fmt_k(total), size=12))
        y += 34
    return svg(y + 20, body)


def chart_08(d) -> str:
    """Where tokens come from.

    Coloured from the shared palette rather than input=green/output=red: in the
    rest of the set green means "new this turn" and red means a window limit, so
    a green "conversation history" box contradicts three other charts at once.
    """
    body = [
        text(32, 40, "Where tokens come from", size=16, fill=TEXT, bold=True),
        text(60, 96, "INPUT — re-sent every turn", fill=HISTORY, bold=True),
        text(840, 96, "OUTPUT — generated fresh", fill=OUTPUT, bold=True,
             anchor="end"),
    ]
    IN_X, IN_W = 60, 300
    MID_X, MID_W = 420, 180
    OUT_X, OUT_W = 660, 170
    inputs = [
        ("your prompt", NEW),
        ("files read", HISTORY),
        ("conversation history", HISTORY),
        ("tool results", HISTORY),
    ]
    y = 130
    for label, colour in inputs:
        body.append(
            f'<rect x="{IN_X}" y="{y}" width="{IN_W}" height="56" rx="8" '
            f'fill="#1a1a20" stroke="{colour}" stroke-width="1.5"></rect>'
        )
        body.append(text(IN_X + IN_W / 2, y + 34, label, size=12, fill=colour,
                         anchor="middle", bold=True))
        y += 72
    bottom = y - 16
    mid_y = (130 + bottom) / 2

    body.append(line(IN_X + IN_W, mid_y, MID_X, mid_y, GRID))
    body.append(
        f'<rect x="{MID_X}" y="{mid_y - 38}" width="{MID_W}" height="76" rx="8" '
        f'fill="#1a1a20" stroke="{MUTED}" stroke-width="1.5"></rect>'
    )
    body.append(text(MID_X + MID_W / 2, mid_y - 4, "Claude", size=13, fill=TEXT,
                     anchor="middle", bold=True))
    body.append(text(MID_X + MID_W / 2, mid_y + 18, "processes it all",
                     anchor="middle"))
    body.append(line(MID_X + MID_W, mid_y, OUT_X, mid_y, GRID))

    for i, (label, sub) in enumerate((("the reply", "code, text, edits"),
                                      ("thinking", "billed as output"))):
        by = mid_y - 84 + i * 96
        body.append(
            f'<rect x="{OUT_X}" y="{by}" width="{OUT_W}" height="72" rx="8" '
            f'fill="#1a1a20" stroke="{OUTPUT}" stroke-width="1.5"></rect>'
        )
        body.append(text(OUT_X + OUT_W / 2, by + 30, label, size=12, fill=OUTPUT,
                         anchor="middle", bold=True))
        body.append(text(OUT_X + OUT_W / 2, by + 52, sub, anchor="middle"))
    body.append(
        text(W / 2, bottom + 44,
             "Input is the bulk of long-session usage — output is priced higher "
             "per token", size=12, anchor="middle")
    )
    return svg(bottom + 72, body)


def chart_09(d) -> str:
    """The Sessions panel, drawn with the app's real semantics.

    The supplied mock described CONTEXT as a share of "the 200k window" beside
    rows reading `opus-5 (1m)`, and BLOAT as input/turn against a 40k floor.
    Both are wrong about this app: the window is per-session, and xFloor is
    median(last 5 turns) / median(first 5) of that same session.
    """
    rows = d["panel"]
    body = [
        text(32, 40, "Live sessions in the menu bar", size=16, fill=TEXT, bold=True),
        text(32, 64, "Every metric above, per running Claude Code session"),
    ]
    # Explicit positions in the 860 viewBox, and a dense single-line row: the
    # supplied mock laid its columns out on a wider imagined canvas, so IN/OUT
    # ran 49px past the right edge and was clipped in the render.
    NAME_X, MODEL_X, BAR_X, BAR_W = 60, 292, 430, 150
    BLOAT_X, TURNS_X, IO_X = 652, 722, 828
    y = 108
    for x, label, anc in ((NAME_X, "SESSION", "start"), (MODEL_X, "MODEL", "start"),
                          (BAR_X, "CONTEXT", "start"), (BLOAT_X, "BLOAT", "end"),
                          (TURNS_X, "TURNS", "end"), (IO_X, "IN/OUT", "end")):
        body.append(text(x, y, label, size=10, anchor=anc))
    y += 30
    names = ["Update readme wi…", "Prepare repository…", "Review charts in R…"]
    for i, r in enumerate(rows):
        sev = HISTORY if r["xfloor"] >= 4 else "#ffd60a"
        body.append(f'<circle cx="44" cy="{y - 4}" r="4" fill="{sev}"></circle>')
        body.append(text(NAME_X, y, names[i], size=12, fill=TEXT, bold=True))
        body.append(text(MODEL_X, y, "opus-5 (1m)", size=12, fill=HISTORY))
        frac = min(1.0, r["context"] / 1_000_000)
        body.append(rect(BAR_X, y - 11, BAR_W, 12, GRID, rx=6))
        body.append(rect(BAR_X, y - 11, max(8, BAR_W * frac), 12, sev, rx=6))
        body.append(text(BLOAT_X, y, f"{r['xfloor']:.1f}×", size=12, fill=sev,
                         bold=True, anchor="end"))
        body.append(text(TURNS_X, y, str(r["turns"]), size=12, fill=NEW, anchor="end"))
        body.append(text(IO_X, y, f"{fmt_m(r['input'])} / {fmt_k(r['output'])}",
                         size=12, fill=TEXT, anchor="end"))
        y += 34
    y += 10
    for note in (
        "context — share of this model's window, 1M here (200k on many models)",
        "bloat — the session's recent turns vs its own first five, not a fixed floor",
        "turns — API requests this session",
        "in/out — total input vs output tokens metered",
    ):
        body.append(text(44, y, note))
        y += 20
    return svg(y + 12, body)


CHARTS = [
    ("01-anatomy-of-a-turn.svg", chart_01),
    ("02-cumulative-input.svg", chart_02),
    ("03-context-window.svg", chart_03),
    ("04-input-per-turn-by-band.svg", chart_04),
    ("05-cache-vs-fresh.svg", chart_05),
    ("06-output-vs-input.svg", chart_06),
    ("07-input-composition-by-turn.svg", chart_07),
    ("08-token-flow.svg", chart_08),
    ("09-sessions-panel.svg", chart_09),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", action="store_true", help="print the dataset, write nothing")
    args = ap.parse_args()

    sessions = measure()
    if not sessions:
        print("no transcripts found under " + TRANSCRIPTS)
        return 1
    d = derive(sessions)

    k, per_doubling = growth_exponent(d["ramp_cum"])
    print(f"sessions={d['sessions']} requests={d['requests']} cohort(>=100 turns)={d['cohort']}")
    print(f"floor(median turn-1 context)={d['floor'] / 1000:.0f}k")
    print(f"growth: cumulative ~ turns^{k:.2f}  ({per_doubling:.1f}x per doubling)")
    for b in d["bands"]:
        print(
            f"  {b['label']:>8} n={b['n']:<3} {b['per_turn'] / 1000:6.0f}k/turn "
            f"{b['total'] / 1e6:7.2f}M  ({b['per_turn'] / d['floor']:.1f}x floor)"
        )
    for n in (1, 10, 50, 100):
        fixed, hist, new = split(d, n - 1)
        print(f"  turn {n:>3}: {d['ramp'][n - 1] / 1000:6.0f}k = fixed {fixed / 1000:.0f}k"
              f" + history {hist / 1000:.0f}k + new {new / 1000:.1f}k"
              f"   cum {d['ramp_cum'][n - 1] / 1e6:.2f}M")
    print(f"out/in over 100 turns: {d['out_cum'][99] / 1000:.0f}k out vs "
          f"{d['ramp_cum'][99] / 1e6:.2f}M in")
    if args.dump:
        return 0

    CHART_DIR.mkdir(parents=True, exist_ok=True)
    for name, fn in CHARTS:
        with open(CHART_DIR / name, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(fn(d))
        print(f"wrote docs/charts/{name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
