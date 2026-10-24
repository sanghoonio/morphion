#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""The Gu cavity: ding strikes with and without it, next to the recordings.

    uv run scripts/gu_test.py        # writes scripts/renders/gu/

Uses the full D Kurd layout from multi_field.py (cross-field links on) plus
multi_field.Gu. The ding weighs 1.0 and the outer notes 0.15 in how hard they
drive the cavity. The printed numbers are the cavity band's level relative to
the ding fundamental's peak. On the Shaktipan first note the 77 Hz cavity reads
-6 dB at 20 ms, -13 at 100 ms, -23 at 200 ms.

Listen on headphones: 73-85 Hz is below what laptop speakers reproduce.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from bwom_demo import excerpt  # noqa: E402
from multi_field import KURD9, Gu, band_envelope, layout, render  # noqa: E402
from one_field import Strike, note_to_hz, write_wav  # noqa: E402

OUT = Path(__file__).parent / "renders" / "gu"
SR = 48000


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    et = [note_to_hz(n) for n in KURD9]
    freqs, links = layout(et)
    D3, A3, D4, A4 = (KURD9.index(n) for n in ("D3", "A3", "D4", "A4"))
    weights = tuple(1.0 if j == D3 else 0.15 for j in range(len(et)))
    pad = Strike(x=0.0, y=0.05, force=0.7, contact_ms=1.5, radius=0.2)
    tip = Strike(x=0.2, y=0.1, force=0.6)
    ding = [(0.0, D3, pad)]
    phrase = [(0.0, D3, pad), (0.6, A3, tip), (1.2, D4, tip), (1.8, A4, tip), (2.4, D3, pad)]

    items = [
        ("1_ding_no_gu", ding, 2.0, None, "no cavity"),
        ("2_ding_gu_subtle", ding, 2.0, Gu(f=80, couple=0.1, weights=weights), "80 Hz, light coupling"),
        ("3_ding_gu_shaktipan", ding, 2.0, Gu(f=80, couple=0.2, weights=weights),
         "80 Hz, coupling set to match the Shaktipan's cavity envelope"),
        ("4_ding_gu_strong", ding, 2.0, Gu(f=80, couple=0.2, kick=0.6, weights=weights),
         "3 plus a direct kick from the strike: bigger thump"),
        ("5_ding_gu_on_lap", ding, 2.0, Gu(f=73.42, couple=0.2, weights=weights, octave=(D3, 0.05)),
         "73.4 Hz (D2, on the knees), an octave below the ding, with a 1:2 link to it"),
        ("6_phrase_no_gu", phrase, 4.5, None, "D3 A3 D4 A4 D3, no cavity"),
        ("7_phrase_gu_shaktipan", phrase, 4.5, Gu(f=80, couple=0.2, weights=weights), "same phrase with 3's cavity"),
    ]
    clips = []
    times = (5, 20, 40, 60, 100, 160, 200, 300, 500)
    print("cavity band, dB re ding fundamental peak  " + " ".join(f"{t:>4d}" for t in times))
    print(f"{'Shaktipan first note (77 Hz)':41s}  " + " ".join(f"{v:4d}" for v in (-15, -6, -11, -12, -13, -16, -23)))
    for name, strikes, seconds, gu, note in items:
        y = render(freqs, links, strikes, seconds, gu=gu)
        if gu is not None and len(strikes) == 1:
            eg, ed = band_envelope(y, gu.f), band_envelope(y, freqs[D3])
            row = " ".join(f"{20 * math.log10(eg[int(t * SR / 1000)] / ed.max()):4.0f}" for t in times)
        else:
            row = ""
        print(f"{name:41s}  {row}   {note}")
        clips.append((name, y))
    clips.append(("8_reference_shaktipan_first", excerpt("fs493864_shaktipan_csharp.wav", 0.0, 0.6)))
    clips.append(("9_reference_akebono_first", excerpt("fs520472_akebono_dry.wav", 2.02, 1.95)))

    # model clips share one gain so the cavity's added level is audible; references on their own
    peak = max(np.abs(y).max() for name, y in clips if "reference" not in name)
    gap = np.zeros(int(0.6 * SR))
    tour = []
    for name, y in clips:
        y = y * 0.9 / (np.abs(y).max() if "reference" in name else peak)
        write_wav(OUT / f"{name}.wav", y, SR)
        tour += [y, gap]
    write_wav(OUT / "tour.wav", np.concatenate(tour), SR)
    print(f"\nwrote {len(clips)} clips and tour.wav to {OUT}")


if __name__ == "__main__":
    main()
