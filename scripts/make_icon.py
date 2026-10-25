#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""App icon for morphion, drawn in the app's own style: dark ground, rounded-rectangle
note outlines, amber for a struck note.

    uv run scripts/make_icon.py concepts       # mac/icon/concept_*.png (1024 px) to choose from
    uv run scripts/make_icon.py build NAME     # mac/icon/AppIcon.icns from concept NAME

Shapes follow macOS's icon grid: a 1024 canvas with an 824 px rounded square centred in it.
Drawn 4x larger and scaled down for smooth edges.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import math

from PIL import Image, ImageDraw

OUT = Path(__file__).parent.parent / "mac" / "icon"
S = 4                       # supersampling
INK = (18, 18, 19)          # the app's background
LINE = (158, 153, 148)      # note outline
AMBER = (255, 194, 102)     # struck note
AMBER_DIM = (122, 94, 52)   # a note swelling in sympathy (amber at ~45% over ink)


def base():
    img = Image.new("RGBA", (1024 * S, 1024 * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = 100 * S
    d.rounded_rectangle([m, m, 1024 * S - m, 1024 * S - m], radius=185 * S, fill=INK)
    return img, d


def grid_cells(cols=3, rows=3):
    """Note rectangles inside the icon square, laid out like the app's grid (trackpad proportions)."""
    x0, x1 = 200 * S, 824 * S
    h = (x1 - x0) / 1.6                 # trackpad-ish aspect
    y0 = 512 * S - h / 2
    cw, ch = (x1 - x0) / cols, h / rows
    inset = min(cw, ch) * 0.08
    cells = []
    for r in range(rows):
        for c in range(cols):
            cells.append([x0 + c * cw + inset, y0 + r * ch + inset, x0 + (c + 1) * cw - inset, y0 + (r + 1) * ch - inset])
    return cells


def note(d, box, fill=None, outline=LINE, width=7):
    rad = min(box[2] - box[0], box[3] - box[1]) * 0.24
    d.rounded_rectangle(box, radius=rad, fill=fill, outline=outline, width=width * S)


def concept_struck():
    img, d = base()
    for i, box in enumerate(grid_cells()):
        note(d, box, fill=AMBER if i == 4 else None, outline=AMBER if i == 4 else LINE)
    return img


def concept_bloom():
    img, d = base()
    for i, box in enumerate(grid_cells()):
        if i == 4:
            note(d, box, fill=AMBER, outline=AMBER)
        elif i in (1, 3):               # A4 and D4: the notes that swell when the ding is struck
            note(d, box, fill=AMBER_DIM, outline=AMBER_DIM)
        else:
            note(d, box)
    return img


def concept_touch():
    img, d = base()
    box = [230 * S, 300 * S, 794 * S, 724 * S]
    note(d, box, width=9)
    cx, cy = 560 * S, 540 * S
    d.ellipse([cx - 80 * S, cy - 110 * S, cx + 80 * S, cy + 110 * S], fill=AMBER)
    return img


def superellipse(cx, cy, rx, ry, n, steps=720):
    """Points of |x/rx|^n + |y/ry|^n = 1: n=2 is an ellipse, larger n squares it off."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + rx * math.copysign(abs(c) ** (2 / n), c), cy + ry * math.copysign(abs(s) ** (2 / n), s)))
    return pts


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def concept_ripple():
    """A fingertip on a note, the vibration spreading out and squaring off into the note's shape."""
    img, d = base()
    cx, cy = 512 * S, 520 * S
    for i, k in enumerate(range(5, 0, -1)):
        t = k / 5
        n = 2 + 4 * t ** 1.5
        rx, ry = (95 + 200 * t) * S, (125 + 140 * t) * S
        col = mix(AMBER, LINE, t) if k < 5 else LINE
        d.line(superellipse(cx, cy, rx, ry, n) + [superellipse(cx, cy, rx, ry, n)[0]], fill=col, width=round((9 - 4 * t) * S))
    d.ellipse([cx - 70 * S, cy - 95 * S, cx + 70 * S, cy + 95 * S], fill=AMBER)
    return img


def concept_morph():
    """Pan to trackpad: a circle squaring off into a rounded rectangle, the last one struck."""
    img, d = base()
    cy = 512 * S
    sizes = [(290, 72, 2.0, LINE), (488, 86, 3.2, LINE), (712, 104, 5.5, AMBER)]
    for x, r, n, col in sizes:
        pts = superellipse(x * S, cy, r * S, r * S * (1 - 0.25 * (n - 2) / 3.5), n)
        if col == AMBER:
            d.polygon(pts, fill=AMBER)
        else:
            d.line(pts + [pts[0]], fill=col, width=8 * S)
    return img


def concept_nodes():
    """A tone field ringing in its octave mode: two antinodes in opposite phase across a nodal line."""
    img, d = base()
    box = [212 * S, 322 * S, 812 * S, 702 * S]
    note(d, box, width=9)
    gap = 18 * S
    cx, cy = 512 * S, 512 * S
    d.rounded_rectangle([262 * S, 372 * S, cx - gap, 652 * S], radius=110 * S, fill=AMBER)
    d.rounded_rectangle([cx + gap, 372 * S, 762 * S, 652 * S], radius=110 * S, fill=AMBER_DIM)
    return img


def concept_ring():
    """A handpan from above in the app's style: the ding struck in the middle, eight notes round it."""
    img, d = base()
    cx, cy = 512 * S, 512 * S
    d.ellipse([cx - 340 * S, cy - 340 * S, cx + 340 * S, cy + 340 * S], outline=LINE, width=7 * S)
    w, h = 150 * S, 96 * S
    for i in range(8):
        a = math.pi / 2 + i * math.pi / 4
        tile = Image.new("RGBA", (w + 40 * S, h + 40 * S), (0, 0, 0, 0))
        note(ImageDraw.Draw(tile), [20 * S, 20 * S, 20 * S + w, 20 * S + h], width=7)
        tile = tile.rotate(math.degrees(-a) + 90, resample=Image.BICUBIC, expand=True)
        x, y = cx + 235 * S * math.cos(a), cy + 235 * S * math.sin(a)
        img.alpha_composite(tile, (round(x - tile.width / 2), round(y - tile.height / 2)))
    d = ImageDraw.Draw(img)
    note(d, [cx - 105 * S, cy - 75 * S, cx + 105 * S, cy + 75 * S], fill=AMBER, outline=AMBER)
    return img


CONCEPTS = {"struck": concept_struck, "bloom": concept_bloom, "touch": concept_touch,
            "ripple": concept_ripple, "morph": concept_morph, "nodes": concept_nodes, "ring": concept_ring}


def render(name, size=1024):
    return CONCEPTS[name]().resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if len(sys.argv) < 2 or sys.argv[1] == "concepts":
        for name in CONCEPTS:
            render(name).save(OUT / f"concept_{name}.png")
        print(f"wrote {', '.join('concept_' + n + '.png' for n in CONCEPTS)} to {OUT}")
        return
    if sys.argv[1] == "build":
        name = sys.argv[2]
        full = CONCEPTS[name]()
        with tempfile.TemporaryDirectory() as tmp:
            iconset = Path(tmp) / "AppIcon.iconset"
            iconset.mkdir()
            for pt in (16, 32, 128, 256, 512):
                for scale in (1, 2):
                    px = pt * scale
                    suffix = "" if scale == 1 else "@2x"
                    full.resize((px, px), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}{suffix}.png")
            subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")], check=True)
        render(name).save(OUT / "AppIcon.png")
        print(f"wrote {OUT / 'AppIcon.icns'} (and AppIcon.png) from '{name}'")


if __name__ == "__main__":
    main()
