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


CONCEPTS = {"struck": concept_struck, "bloom": concept_bloom, "touch": concept_touch}


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
