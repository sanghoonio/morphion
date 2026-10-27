#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""Bom vs bwom: model renders next to reference strikes, to agree on what the words mean.

    uv run scripts/bwom_demo.py        # writes scripts/renders/bwom/

"Bwom" is the octave starting well below the fundamental and swelling in over
the first few hundred ms; "bom" is the octave there from the start and then
fading. The printed numbers are octave level minus fundamental level (dB) at
50 and 400 ms, from the model's mode envelopes. Every file is peak-normalized
on its own, so compare character, not loudness.

The "swell" renders (08-11) push the octave harder: stronger coupling so the
octave grows in tens of ms, not hundreds, and a higher octave radiation weight
so it can reach the fundamental's level. Coupling moves energy, it doesn't add
it, so the fundamental sinks while the octave rises, and at the top two settings
the energy swings back into the fundamental a few hundred ms later.
"""

from __future__ import annotations

import math
import sys
import wave
from dataclasses import replace
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from one_field import Params, Strike, default_modes, note_to_hz, render, write_wav  # noqa: E402

ROOT = Path(__file__).parent.parent
REC = ROOT / "reference" / "recordings"
OUT = Path(__file__).parent / "renders" / "bwom"
SR = 48000


PAD = Strike(x=0.0, y=0.05, force=0.9, contact_ms=2.5, radius=0.25)


def model_items():
    """(name, strike, kappa, octave overrides, description)."""
    return [
        ("01_model_bom", Strike(x=0.45, y=0.0, contact_ms=0.8, radius=0.1), 0.002, dict(t60=1.5),
         "octave spot, short contact, almost no coupling, octave decays faster than the fundamental"),
        ("02_model_mild_bwom", Strike(x=0.2, y=0.1), 0.008, {},
         "fingertip, a little off center, coupling 0.008"),
        ("03_model_strong_bwom", PAD, 0.025, {},
         "near center, soft finger pad, firmer strike, coupling x3"),
        ("04_model_overshoot", Strike(x=0.0, y=0.05), 0.04, {},
         "the old coupling (0.04): octave swells past the fundamental, too much"),
        ("08_model_swell_x5", PAD, 0.04, dict(out=0.8),
         "03 with coupling x5, octave louder: peaks ~-7 dB at 80 ms"),
        ("09_model_swell_x6", PAD, 0.05, dict(out=1.0),
         "coupling x6: octave peaks ~-4 dB at 100 ms"),
        ("10_model_swell_x9", PAD, 0.07, dict(out=1.0),
         "coupling x9: octave peaks ~-3 dB at 80 ms, fundamental swings back at 300 ms"),
        ("11_model_swell_x12", PAD, 0.1, dict(out=1.2),
         "coupling x12: octave near the fundamental's level by 40 ms, energy sloshes back and forth"),
    ]


# (name, file, onset s, length s, description) -- onsets as measured earlier
REFERENCES = [
    ("05_ref_strong_bwom_A#3", "fs426794_handpan.wav", 1.65, 1.5, "scale walk A#3: octave -14 -> +1 dB"),
    ("06_ref_bom_D4", "fs426794_handpan.wav", 4.80, 1.5, "scale walk D4: octave -10 -> -17 dB (knuckle-ish strike)"),
    ("07_ref_gentle_bwom_G#4", "fs493864_shaktipan_csharp.wav", 2.53, 1.45, "Shaktipan G#4: octave -25 -> -16.5 dB, finger pad"),
]


# First notes with the bwom, and the partials that swell in them (Hz, from tracking each
# partial's envelope: these start 20-45 dB down and rise 15-35 dB to peak at 300-400 ms).
# (prefix, file, onset s, length s, swelling partials, description)
ISOLATE = [
    ("12_shaktipan_first", "fs493864_shaktipan_csharp.wav", 0.0, 0.6, [418.2, 556.5, 833.7],
     "C#3 ding; swell at 3x, 4x, 6x (= the G#4, C#5, G#5 fields)"),
    ("13_akebono_first", "fs520472_akebono_dry.wav", 2.02, 1.95, [166.2, 248.3],
     "E note, 82 Hz lowest; swell at 166 and 248 Hz (E3, B3)"),
]


def split_partials(y, freqs, width_hz=5.0):
    """(y without the given partials, the partials alone), by Gaussian notches in one FFT."""
    Y = np.fft.rfft(y)
    f = np.fft.rfftfreq(len(y), 1 / SR)
    keep = np.ones_like(f)
    for fc in freqs:
        keep *= 1 - np.exp(-0.5 * ((f - fc) / width_hz) ** 2)
    without = np.fft.irfft(Y * keep, len(y))
    return without, y - without


def read_wav(path):
    with wave.open(str(path)) as w:
        assert w.getsampwidth() == 2
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(float) / 32768
        return x.reshape(-1, w.getnchannels()).mean(axis=1), w.getframerate()


def resample(x, sr_in, sr_out):
    t_out = np.arange(int(len(x) * sr_out / sr_in)) / sr_out
    return np.interp(t_out, np.arange(len(x)) / sr_in, x)


def excerpt(file, onset, length):
    x, sr = read_wav(REC / file)
    a = max(0, int((onset - 0.05) * sr))
    seg = x[a:a + int(length * sr)].copy()
    fade = int(0.05 * sr)  # the next strike follows soon after, so fade the end
    seg[-fade:] *= np.linspace(1, 0, fade)
    return resample(seg, sr, SR)


def db(a, b):
    return 20 * math.log10(a / b)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    f0 = note_to_hz("D4")
    clips = []

    print("model, D4                       oct-fund @50ms  @400ms")
    for name, strike, kappa, octave, note in model_items():
        modes = default_modes(f0)
        modes[1] = replace(modes[1], **octave)
        y, env = render(f0, modes, [strike], Params(sr=SR, kappa_oct=kappa, kappa_12=kappa, tail=3.0))
        print(f"{name:32s} {db(env[1, 50], env[0, 50]):+6.1f}  {db(env[1, 400], env[0, 400]):+6.1f}   {note}")
        clips.append((name, y))

    print("\nreferences (measured earlier)")
    for name, file, onset, length, note in REFERENCES:
        print(f"{name:32s} {note}")
        clips.append((name, excerpt(file, onset, length)))

    print("\nfirst notes split into the swelling partials and the rest")
    for prefix, file, onset, length, freqs, note in ISOLATE:
        y = excerpt(file, onset, length)
        without, swell = split_partials(y, freqs)
        print(f"{prefix:32s} {note}")
        clips += [(f"{prefix}_a_original", y), (f"{prefix}_b_without_swell", without),
                  (f"{prefix}_c_swell_only", swell)]

    gap = np.zeros(int(0.6 * SR))
    tour = []
    for name, y in sorted(clips):
        y = y * 0.9 / np.abs(y).max()
        write_wav(OUT / f"{name}.wav", y, SR)
        tour += [y, gap]
    write_wav(OUT / "tour.wav", np.concatenate(tour), SR)
    print(f"\nwrote {len(clips)} clips and tour.wav to {OUT}")


if __name__ == "__main__":
    main()
