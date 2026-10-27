#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "scipy", "matplotlib"]
# ///
"""Waveform and spectrum of one ding strike, rendered by the C++ engine (the app's sound,
attack and limiter included).

    uv run scripts/plot_ding.py             # writes scripts/renders/ding_plot.png

Panels: the whole waveform, the first 40 ms (strike), a spectrogram, and the spectrum
of the first second with the main partials labeled.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from scipy.io import wavfile  # noqa: E402
from scipy.signal import spectrogram  # noqa: E402

ROOT = Path(__file__).parent.parent
OUT = Path(__file__).parent / "renders"
SECONDS = 8.0
T0 = 0.02  # strike time in render_test's ding mode

INK, LINE, AMBER = "#121213", "#9e9994", "#ffc266"


def render():
    subprocess.run(["make", "-s", "-C", str(ROOT / "engine")], check=True)
    wav = OUT / "ding_plot.wav"
    subprocess.run([str(ROOT / "engine/build/render_test"), "--attack", str(wav), "1", "ding", str(SECONDS)],
                   check=True, stdout=subprocess.DEVNULL)
    sr, y = wavfile.read(wav)
    y = y.astype(np.float64)
    if y.ndim > 1:
        y = y.mean(axis=1)
    if np.issubdtype(wavfile.read(wav)[1].dtype, np.integer):
        y /= 32768.0
    return sr, y


def style(ax):
    ax.set_facecolor(INK)
    for s in ax.spines.values():
        s.set_color("#444")
    ax.tick_params(colors=LINE, labelsize=8)
    ax.xaxis.label.set_color(LINE)
    ax.yaxis.label.set_color(LINE)
    ax.title.set_color("#ddd")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sr, y = render()
    t = np.arange(len(y)) / sr - T0

    fig = plt.figure(figsize=(13, 9), facecolor=INK)
    gs = fig.add_gridspec(3, 2, height_ratios=[1, 1.4, 1.2], hspace=0.45, wspace=0.18)

    ax = fig.add_subplot(gs[0, 0])
    ax.plot(t, y, color=AMBER, lw=0.4)
    ax.set(xlim=(-0.02, SECONDS - T0), title="Waveform", xlabel="s")
    style(ax)

    ax = fig.add_subplot(gs[0, 1])
    m = (t > -0.002) & (t < 0.04)
    ax.plot(t[m] * 1000, y[m], color=AMBER, lw=0.8)
    ax.set(title="Strike, first 40 ms", xlabel="ms")
    style(ax)

    ax = fig.add_subplot(gs[1, :])
    f, ts, S = spectrogram(y, sr, nperseg=8192, noverlap=8192 - 512, window="hann")
    db = 10 * np.log10(S + 1e-14)
    db -= db.max()
    ax.pcolormesh(ts - T0, f, db, vmin=-90, vmax=0, cmap="inferno", shading="auto")
    ax.set_yscale("log")
    ax.set(ylim=(50, 12000), title="Spectrogram (dB)", xlabel="s", ylabel="Hz")
    style(ax)

    ax = fig.add_subplot(gs[2, :])
    seg = y[int(T0 * sr):int((T0 + 1.0) * sr)]
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), n=1 << 18))
    fr = np.fft.rfftfreq(1 << 18, 1 / sr)
    sdb = 20 * np.log10(spec / spec.max() + 1e-12)
    ax.plot(fr, sdb, color=AMBER, lw=0.6)
    ax.set_xscale("log")
    ax.set(xlim=(50, 12000), ylim=(-100, 5), title="Spectrum, first second (dB)", xlabel="Hz")
    # label the strongest peaks below 2 kHz
    band = (fr > 60) & (fr < 2000)
    idx = np.where(band)[0]
    peaks = [i for i in idx[1:-1] if sdb[i] > sdb[i - 1] and sdb[i] >= sdb[i + 1] and sdb[i] > -55]
    peaks = sorted(peaks, key=lambda i: -sdb[i])
    kept = []
    for i in peaks:
        if all(abs(np.log2(fr[i] / fr[k])) > 0.08 for k in kept):
            kept.append(i)
        if len(kept) == 8:
            break
    for i in kept:
        ax.annotate(f"{fr[i]:.1f}", (fr[i], sdb[i]), xytext=(0, 6), textcoords="offset points",
                    ha="center", fontsize=7, color="#ddd")
    style(ax)

    fig.suptitle("D3 ding, engine render (force 0.7, attack 1.0, Gu and sympathetic links on)",
                 color="#ddd", fontsize=11)
    png = OUT / "ding_plot.png"
    fig.savefig(png, dpi=130, facecolor=INK)
    print(f"wrote {png}")


if __name__ == "__main__":
    main()
