#!/usr/bin/env python3
"""Badged tray icons: every base state with a failed, busy or unknown badge in its bottom-right corner.

    python3 badges.py <icon dir> <out dir>

proxy-suite-<state>[-symbolic].svg -> proxy-suite-<state>-<badge>[-symbolic].svg, next to copies of the bases.
The shield is cut away around the badge, so it reads on any panel color.
"""

import os
import re
import shutil
import sys

STATES = ("disabled", "zapret", "proxy", "active", "tunnel")
CX, CY = 18.5, 18.5
CUT, DOT = 5.8, 4.8  # radius of the gap in the shield, and of the badge inside it

# badge -> (fill, stroke, glyph drawn in the glyph color)
GLYPHS = {
    "failed": (
        "#D32F2F",
        "#7F0000",
        f'<path d="M {CX} {CY - 2.6} L {CX} {CY + 0.4}" stroke-width="1.5" stroke-linecap="round" fill="none"/>'
        f'<circle cx="{CX}" cy="{CY + 2.4}" r="0.85" stroke="none"/>',
    ),
    "busy": (
        "#FFA000",
        "#8D5A00",
        "".join(f'<circle cx="{CX + dx}" cy="{CY}" r="0.85" stroke="none"/>' for dx in (-2.2, 0, 2.2)),
    ),
    "unknown": (
        "#757575",
        "#424242",
        f'<path d="M {CX - 1.6} {CY - 1.2} C {CX - 1.6} {CY - 3.4} {CX + 1.8} {CY - 3.4} {CX + 1.8} {CY - 1.2} '
        f'C {CX + 1.8} {CY + 0.2} {CX} {CY} {CX} {CY + 1}" stroke-width="1.4" stroke-linecap="round" fill="none"/>'
        f'<circle cx="{CX}" cy="{CY + 2.7}" r="0.8" stroke="none"/>',
    ),
}


def inner(svg):
    return re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1)


def badged(svg, badge, symbolic):
    fill, stroke, glyph = GLYPHS[badge]
    mask = (
        f'<mask id="cut"><rect width="24" height="24" fill="white"/>'
        f'<circle cx="{CX}" cy="{CY}" r="{CUT}" fill="black"/></mask>'
    )
    if symbolic:
        # One color: the badge is a disc with its glyph knocked out.
        mask += (
            f'<mask id="glyph"><rect width="24" height="24" fill="white"/>'
            f'<g stroke="black" fill="black">{glyph}</g></mask>'
        )
        badge_svg = f'<circle cx="{CX}" cy="{CY}" r="{DOT}" fill="currentColor" mask="url(#glyph)"/>'
    else:
        badge_svg = (
            f'<circle cx="{CX}" cy="{CY}" r="{DOT}" fill="{fill}" stroke="{stroke}" stroke-width="0.6"/>'
            f'<g stroke="#FFFFFF" fill="#FFFFFF">{glyph}</g>'
        )
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">\n'
        f"  <defs>{mask}</defs>\n"
        f'  <g mask="url(#cut)">{inner(svg)}</g>\n'
        f"  {badge_svg}\n"
        "</svg>\n"
    )


def main(src, out):
    os.makedirs(out, exist_ok=True)
    for state in STATES:
        for suffix in ("", "-symbolic"):
            base = os.path.join(src, f"proxy-suite-{state}{suffix}.svg")
            shutil.copyfile(base, os.path.join(out, os.path.basename(base)))
            with open(base) as f:
                svg = f.read()
            for badge in GLYPHS:
                with open(os.path.join(out, f"proxy-suite-{state}-{badge}{suffix}.svg"), "w") as f:
                    f.write(badged(svg, badge, bool(suffix)))


if __name__ == "__main__":
    main(*sys.argv[1:3])
