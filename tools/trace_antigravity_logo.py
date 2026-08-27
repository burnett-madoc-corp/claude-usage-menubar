#!/usr/bin/env python3
"""Trace antigravity.google's favicon into a monochrome menu bar template.

The Antigravity mark is a Google-gradient arch — an "A" with no crossbar and
outward-flared feet. Simple Icons has no entry for it, and the marketing site
renders its logo in JavaScript with no inline SVG, so the favicon is the only
vector-able source we have.

This walks the alpha channel of the favicon's largest layer and emits a single
path in the same shape as claude-template.svg and codex-template.svg: a
`0 0 24 24` viewBox, `role="img"`, one `<path>`, and no fill attribute
(UsageMenuBar.logoImage fills the glyph itself).

Regenerate with:
    curl -sL --compressed https://antigravity.google/favicon.ico -o /tmp/ag.ico
    python3 tools/trace_antigravity_logo.py /tmp/ag.ico Resources/antigravity-template.svg

Requires Pillow, which is not a runtime dependency of the app — this script
runs by hand when the brand changes, not during the build.
"""
import sys

from PIL import Image

# The mark is drawn with soft anti-aliased edges. Half-alpha is the midpoint
# of that ramp and keeps the arch's stroke at its drawn weight; pushing it
# lower fattens the glyph, higher eats the thin apex.
ALPHA_THRESHOLD = 128

# The favicon is only 48px square, so tracing its pixel grid directly yields a
# visibly stair-stepped outline. Upsampling the ALPHA channel first recovers
# the true edge: anti-aliasing already encodes where the boundary really falls
# between pixels, so a smooth resample followed by a threshold lands much
# closer to the drawn curve than the raw grid does.
SUPERSAMPLE = 4

# Douglas-Peucker tolerance, in output (24-unit) coordinates. Large enough to
# collapse the residual staircase, small enough to keep the flared feet and
# the notch under the apex.
SIMPLIFY_TOLERANCE = 0.12


def largest_layer(path):
    """The .ico holds 16/32/48px layers; take the biggest for the most detail."""
    image = Image.open(path)
    best = None
    for size in sorted(image.info.get("sizes", [image.size])):
        image.size = size
        candidate = image.copy().convert("RGBA")
        if best is None or candidate.width > best.width:
            best = candidate
    return best


def alpha_mask(image):
    """Boolean grid of ink, padded by one cell so edge pixels have a boundary."""
    alpha_channel = image.getchannel("A")
    if SUPERSAMPLE > 1:
        alpha_channel = alpha_channel.resize(
            (image.width * SUPERSAMPLE, image.height * SUPERSAMPLE), Image.LANCZOS
        )
    w, h = alpha_channel.size
    alpha = alpha_channel.load()
    return [[0] * (w + 2)] + [
        [0] + [1 if alpha[x, y] >= ALPHA_THRESHOLD else 0 for x in range(w)] + [0]
        for y in range(h)
    ] + [[0] * (w + 2)]


def trace_contours(mask):
    """Walk every boundary between ink and background as a closed loop.

    Each unit cell edge that separates an ink cell from a non-ink cell is one
    segment; chaining segments end-to-end yields the outlines. This is exact
    for a pixel grid — no curve fitting, so nothing is invented that the
    favicon did not contain.
    """
    h, w = len(mask), len(mask[0])
    edges = {}

    def add(a, b):
        edges.setdefault(a, []).append(b)

    for y in range(h - 1):
        for x in range(w - 1):
            here = mask[y][x]
            # Walk boundaries counter-clockwise around ink so outer contours
            # and holes wind oppositely, which is what makes the even-odd
            # fill in the emitted path behave.
            if here != mask[y][x + 1]:
                add((x + 1, y), (x + 1, y + 1)) if here else add((x + 1, y + 1), (x + 1, y))
            if here != mask[y + 1][x]:
                add((x + 1, y + 1), (x, y + 1)) if here else add((x, y + 1), (x + 1, y + 1))

    loops = []
    while edges:
        start = next(iter(edges))
        loop = [start]
        node = start
        while True:
            following = edges.get(node)
            if not following:
                break
            nxt = following.pop()
            if not following:
                del edges[node]
            if nxt == start:
                break
            loop.append(nxt)
            node = nxt
        if len(loop) > 2:
            loops.append(loop)
    return loops


def drop_collinear(loop):
    """Collapse straight runs to their endpoints."""
    out = []
    n = len(loop)
    for i in range(n):
        ax, ay = loop[i - 1]
        bx, by = loop[i]
        cx, cy = loop[(i + 1) % n]
        if (bx - ax) * (cy - by) != (by - ay) * (cx - bx):
            out.append((bx, by))
    return out


def _douglas_peucker(points, tolerance):
    if len(points) < 3:
        return points
    ax, ay = points[0]
    cx, cy = points[-1]
    span = max(((cx - ax) ** 2 + (cy - ay) ** 2) ** 0.5, 1e-9)
    worst, index = 0.0, 0
    for i in range(1, len(points) - 1):
        bx, by = points[i]
        distance = abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) / span
        if distance > worst:
            worst, index = distance, i
    if worst <= tolerance:
        return [points[0], points[-1]]
    left = _douglas_peucker(points[: index + 1], tolerance)
    right = _douglas_peucker(points[index:], tolerance)
    return left[:-1] + right


def simplify(loop, tolerance):
    """Douglas-Peucker over a closed loop.

    A per-vertex filter cannot do this job: every corner of a pixel staircase
    has the same deviation ratio, so any threshold either keeps all of them or
    deletes the real corners too. Douglas-Peucker judges each point against
    the chord it actually strays from, which is what distinguishes a stair
    step from the tip of a foot.
    """
    if len(loop) < 4:
        return loop
    # Split at the two extremes so the closed loop becomes two open chains
    # neither of which can be collapsed to a single degenerate segment.
    start = min(range(len(loop)), key=lambda i: (loop[i][1], loop[i][0]))
    rotated = loop[start:] + loop[:start]
    half = len(rotated) // 2
    first = _douglas_peucker(rotated[: half + 1], tolerance)
    second = _douglas_peucker(rotated[half:] + [rotated[0]], tolerance)
    out = first[:-1] + second[:-1]
    return out if len(out) > 2 else loop


def to_path(loops, source_size, box=24.0):
    """source_size is the supersampled grid width, not the favicon's."""
    scale = box / source_size
    parts = []
    for loop in loops:
        points = [(round((x - 1) * scale, 4), round((y - 1) * scale, 4)) for x, y in loop]
        head = "M{} {}".format(*points[0])
        rest = "".join("L{} {}".format(x, y) for x, y in points[1:])
        parts.append(head + rest + "Z")
    return "".join(parts)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    source, destination = sys.argv[1], sys.argv[2]

    image = largest_layer(source)
    mask = alpha_mask(image)
    grid = image.width * SUPERSAMPLE
    loops = [simplify(drop_collinear(loop), SIMPLIFY_TOLERANCE * grid / 24.0)
             for loop in trace_contours(mask)]
    loops = [loop for loop in loops if len(loop) > 2]
    if not loops:
        sys.exit("no contours found — is ALPHA_THRESHOLD too high?")

    path = to_path(loops, grid)
    svg = (
        '<svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">\n'
        "  <title>Google Antigravity</title>\n"
        f'  <path d="{path}"/>\n'
        "</svg>\n"
    )
    with open(destination, "w") as handle:
        handle.write(svg)
    print(f"{destination}: {len(loops)} contour(s), {len(path)} chars of path data")


if __name__ == "__main__":
    main()
