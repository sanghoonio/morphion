#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "scipy"]
# ///
"""Reverb prototype: the engine's stereo phrase, dry and in a few rooms.

    uv run scripts/reverb_demo.py        # writes scripts/renders/reverb/

The reverb is a feedback delay network: 8 delay lines (lengths scaled by room size) fed
back through a Householder matrix, each line losing level per pass so the tail falls
60 dB in t60 seconds, through a one-pole low-pass so highs die faster (damping). Early
reflections are a few taps in the first ~30 ms, after a short pre-delay. Left- and
right-column notes enter the network from their own side. The dry signal stays at full
level; `wet` is how much room is added.

All clips share one gain, so the rooms' added level is audible. Listen on headphones.
"""

from __future__ import annotations

import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import lfilter

ROOT = Path(__file__).parent.parent
OUT = Path(__file__).parent / "renders" / "reverb"
SR = 48000

BASE_MS = np.array([29.7, 37.1, 41.1, 43.7, 53.1, 59.3, 67.9, 73.3])   # mutually prime-ish
ER_MS = [(7.0, 0.55, 0), (11.3, 0.45, 1), (16.9, 0.38, 0), (23.1, 0.30, 1), (29.6, 0.24, 0), (31.7, 0.22, 1)]


@dataclass
class Room:
    t60: float          # tail decay, seconds
    size: float         # scales the delay lengths (and early reflections)
    wet: float          # added room level
    damp: float         # 0 bright .. 0.6 dull: one-pole coefficient in each line
    predelay_ms: float = 12.0


def fdn(x: np.ndarray, room: Room) -> np.ndarray:
    """x: (n, 2) stereo in; returns the (n, 2) wet signal (early + late)."""
    n = len(x)
    pre = int(room.predelay_ms * 1e-3 * SR)
    xin = np.zeros_like(x)
    xin[pre:] = x[: n - pre]

    # early reflections: taps, alternating sides
    er = np.zeros_like(x)
    for ms, g, side in ER_MS:
        d = int(ms * room.size * 1e-3 * SR)
        er[d:, side] += g * xin[: n - d, side]
        er[d:, 1 - side] += 0.3 * g * xin[: n - d, 1 - side]

    # late tail
    d = np.round(BASE_MS * room.size * 1e-3 * SR).astype(int)
    N = len(d)
    g = 10.0 ** (-3.0 * d / (room.t60 * SR))           # level per pass for the t60
    A = np.eye(N) - 2.0 / N * np.ones((N, N))          # Householder: lossless, every line feeds every line
    b = np.zeros((N, 2))
    b[0::2, 0] = 1.0
    b[1::2, 1] = 1.0                                   # even lines hear the left, odd the right
    cL = np.array([1, -1, 1, -1, 1, -1, 1, -1])         # different signs per side: a wide, uncorrelated tail
    cR = np.array([1, 1, -1, -1, 1, 1, -1, -1])
    s = np.zeros((N, n))                               # what enters each line
    zi = np.zeros((N, 1))                              # one-pole filter states
    B = int(d.min())                                   # a block never reads its own output
    a = room.damp
    for t in range(0, n, B):
        m = min(B, n - t)
        o = np.zeros((N, m))
        for i in range(N):
            lo = t - d[i]
            if lo + m > 0:
                src = s[i, max(lo, 0): lo + m]
                o[i, m - len(src):] = src
            o[i], zi[i] = lfilter([g[i] * (1 - a)], [1, -a], o[i], zi=zi[i])
        s[:, t: t + m] = A @ o + b @ xin[t: t + m].T
    out = np.zeros_like(x)
    tail = np.stack([cL @ s, cR @ s], axis=1) / np.sqrt(N)
    # read the tail one line-length late, as heard from the lines' outputs
    out[B:] = tail[:-B]
    return er + out


def phrase() -> np.ndarray:
    """The engine's stereo phrase (render_test --stereo, width 0.5), with 3 s of silence for tails."""
    subprocess.run(["make", "-s", "-C", str(ROOT / "engine")], check=True)
    wav = OUT / "_engine_phrase.wav"
    subprocess.run([str(ROOT / "engine/build/render_test"), "--stereo", str(wav), "0.5"], check=True,
                   stdout=subprocess.DEVNULL)
    sr, y = wavfile.read(wav)
    wav.unlink()
    assert sr == SR
    y = y.astype(np.float64) / 32768.0
    return np.concatenate([y, np.zeros((3 * SR, 2))])


def write(path: Path, y: np.ndarray):
    wavfile.write(path, SR, (np.clip(y, -1, 1) * 32767).astype(np.int16))


ROOMS = [
    ("1_dry", None, "as the app plays now"),
    ("2_small_room", Room(t60=0.5, size=0.6, wet=0.30, damp=0.35), "a small, soft room: just air around the notes"),
    ("3_medium_room", Room(t60=1.0, size=1.0, wet=0.30, damp=0.30), "a living room / studio"),
    ("4_hall", Room(t60=2.2, size=1.6, wet=0.32, damp=0.25), "a hall: long, smooth tail"),
    ("5_stairwell", Room(t60=3.0, size=1.2, wet=0.38, damp=0.10), "a stairwell: hard walls, bright and long"),
]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    dry = phrase()
    clips = []
    for name, room, note in ROOMS:
        y = dry if room is None else dry + room.wet * fdn(dry, room)
        clips.append((name, y, note))
    peak = max(np.abs(y).max() for _, y, _ in clips)
    gap = np.zeros((int(0.8 * SR), 2))
    tour = []
    for name, y, note in clips:
        y = y * 0.9 / peak
        write(OUT / f"{name}.wav", y)
        tour += [y, gap]
        print(f"{name:16s} {note}")
    write(OUT / "tour.wav", np.concatenate(tour))
    print(f"\nwrote {len(clips)} clips and tour.wav to {OUT}")


if __name__ == "__main__":
    sys.exit(main())
