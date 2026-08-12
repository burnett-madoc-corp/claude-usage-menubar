#!/usr/bin/env python3
"""Structural checks for docs/charts/*.svg.

WHY THIS EXISTS
---------------
A previous set of these charts shipped with a plotted curve striking through
its own label, a growth annotation its own points disproved, and two charts
disagreeing about what a 100-turn session costs. None of that is visible in a
diff, and none of it is caught by any other check in this repo. Reading the XML
does not catch it either -- the label cleared the curve at its anchor and was
struck through 70px later, because the curve had moved.

So the geometry is checked as arithmetic:

1. Nothing overflows the viewBox.
2. No text is crossed by a plotted polyline anywhere across the label's whole
   x-span -- not just at its anchor.
3. Charts that state the same quantity state the same number.

Run:  python3 tools/check_charts.py
"""
from __future__ import annotations

import html
import re
import sys
from pathlib import Path

CHART_DIR = Path(__file__).resolve().parents[1] / "docs" / "charts"

# Rough advance width of the mono face used by the charts, as a fraction of
# font-size. Deliberately generous: a false positive costs a look, a false
# negative ships a struck-through label.
ADVANCE = 0.62

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)
    print(f"FAIL: {msg}")


def texts(src: str) -> list[dict]:
    out = []
    for m in re.finditer(r"<text([^>]*)>(.*?)</text>", src, re.S):
        attrs, body = m.group(1), html.unescape(re.sub(r"<[^>]+>", "", m.group(2)))
        get = lambda k, d=None: (
            re.search(k + r'="([^"]*)"', attrs).group(1)
            if re.search(k + r'="([^"]*)"', attrs)
            else d
        )
        size = float(get("font-size", "12"))
        width = ADVANCE * size * len(body)
        anchor = get("text-anchor", "start")
        x = float(get("x", "0"))
        x0 = x if anchor == "start" else (x - width if anchor == "end" else x - width / 2)
        y = float(get("y", "0"))
        out.append(
            {
                "s": body,
                "x0": x0,
                "x1": x0 + width,
                "top": y - size * 0.74,
                "bot": y + size * 0.22,
            }
        )
    return out


def polylines(src: str) -> list[list[tuple[float, float]]]:
    out = []
    for m in re.finditer(r'<(?:polyline|polygon)[^>]*points="([^"]*)"', src):
        pts = [
            (float(a), float(b))
            for a, b in re.findall(r"(-?[\d.]+),(-?[\d.]+)", m.group(1))
        ]
        if len(pts) > 2:
            out.append(pts)
    return out


def y_at(pts, x):
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        if x1 <= x <= x2 and x2 != x1:
            return y1 + (y2 - y1) * (x - x1) / (x2 - x1)
    return None


def check_file(path: Path) -> None:
    src = path.read_text(encoding="utf-8")
    m = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', src)
    if not m:
        fail(f"{path.name}: no viewBox")
        return
    vw, vh = float(m.group(1)), float(m.group(2))
    lines = polylines(src)

    for t in texts(src):
        if t["x0"] < 0 or t["x1"] > vw:
            fail(
                f"{path.name}: text {t['s']!r} spans x[{t['x0']:.0f},{t['x1']:.0f}] "
                f"outside viewBox width {vw:.0f}"
            )
        if t["bot"] > vh:
            fail(f"{path.name}: text {t['s']!r} below viewBox height {vh:.0f}")
        for pts in lines:
            hits = [
                x
                for x in range(int(t["x0"]), int(t["x1"]) + 1, 2)
                if (y := y_at(pts, x)) is not None and t["top"] <= y <= t["bot"]
            ]
            if hits:
                fail(
                    f"{path.name}: curve strikes through text {t['s']!r} "
                    f"between x={hits[0]} and x={hits[-1]}"
                )

    for m2 in re.finditer(r'<rect[^>]*x="([\d.]+)"[^>]*width="([\d.]+)"', src):
        right = float(m2.group(1)) + float(m2.group(2))
        if right > vw + 0.5:
            fail(f"{path.name}: rect right edge {right:.0f} past viewBox {vw:.0f}")

    # Text against text. A value label running into the column beside it is the
    # same defect as a curve through a label, and just as invisible in a diff.
    items = texts(src)
    for i, a in enumerate(items):
        for b in items[i + 1:]:
            if a["x0"] < b["x1"] and b["x0"] < a["x1"] and a["top"] < b["bot"] and b["top"] < a["bot"]:
                fail(f"{path.name}: text {a['s']!r} overlaps {b['s']!r}")


def number_after(src: str, needle: str) -> str | None:
    """First number-ish token in a text element containing `needle`."""
    for t in texts(src):
        if needle in t["s"]:
            m = re.search(r"[\d.]+[kM]", t["s"])
            if m:
                return m.group(0)
    return None


def check_cross_chart() -> None:
    """Quantities restated across charts must match."""
    src = {p.name: p.read_text(encoding="utf-8") for p in CHART_DIR.glob("*.svg")}

    def all_text(name):
        return " | ".join(t["s"] for t in texts(src[name]))

    # The cumulative total at turn 100 appears in chart 02 (its last labelled
    # dot) and chart 06 (the input bar). They must agree.
    c02 = re.findall(r"([\d.]+M)", all_text("02-cumulative-input.svg"))
    c06 = re.findall(r"([\d.]+M)", all_text("06-output-vs-input.svg"))
    if c02 and c06 and c02[-1] != c06[0]:
        fail(
            f"charts 02 and 06 disagree on a 100-turn session's input: "
            f"{c02[-1]} vs {c06[0]}"
        )

    # The fixed floor appears in chart 04's reference line and chart 07's
    # legend. They must agree.
    f04 = number_after(src["04-input-per-turn-by-band.svg"], "floor ≈")
    f07 = number_after(src["07-input-composition-by-turn.svg"], "system + tools")
    if f04 and f07 and f04 != f07:
        fail(f"charts 04 and 07 disagree on the floor: {f04} vs {f07}")


def check_doc() -> None:
    """The prose restates a few chart numbers; hold it to them.

    docs/token-metering.md quotes the floor and the growth exponent in words.
    Those are live measurements that move whenever the charts are regenerated,
    so left unchecked the prose drifts away from the images beside it -- the
    same failure as two charts disagreeing, one step removed.
    """
    doc_path = CHART_DIR.parent / "token-metering.md"
    if not doc_path.exists():
        return
    doc = doc_path.read_text(encoding="utf-8")
    charts = {p.name: p.read_text(encoding="utf-8") for p in CHART_DIR.glob("*.svg")}

    floor_chart = number_after(charts["04-input-per-turn-by-band.svg"], "floor ≈")
    m = re.search(r"floor is ~(\d+k) input tokens/turn", doc)
    if floor_chart and m and m.group(1) != floor_chart:
        fail(f"doc says the floor is {m.group(1)}, chart 04 says {floor_chart}")

    exp_chart = re.search(
        r"measured exponent ([\d.]+)",
        " ".join(t["s"] for t in texts(charts["02-cumulative-input.svg"])),
    )
    m = re.search(r"the exponent is ([\d.]+)", doc)
    if exp_chart and m and m.group(1) != exp_chart.group(1):
        fail(
            f"doc says the exponent is {m.group(1)}, "
            f"chart 02 says {exp_chart.group(1)}"
        )

    dbl_chart = re.search(
        r"≈ ([\d.]+)× the input",
        " ".join(t["s"] for t in texts(charts["02-cumulative-input.svg"])),
    )
    m = re.search(r"\*\*([\d.]+)× the input for 2× the turns\*\*", doc)
    if dbl_chart and m and m.group(1) != dbl_chart.group(1):
        fail(
            f"doc says {m.group(1)}× per doubling, "
            f"chart 02 says {dbl_chart.group(1)}×"
        )


def main() -> int:
    files = sorted(CHART_DIR.glob("*.svg"))
    if not files:
        print(f"no charts found in {CHART_DIR}")
        return 1
    for path in files:
        check_file(path)
    check_cross_chart()
    check_doc()
    if failures:
        print(f"\n{len(failures)} problem(s) in {len(files)} charts")
        return 1
    print(f"OK: {len(files)} charts, no overflow, no struck-through labels, "
          f"cross-chart numbers agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
