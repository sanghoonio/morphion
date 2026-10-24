#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""How to get the 250 ms swell on an equal-tempered pad: three options, rendered.

    uv run scripts/tuning_options.py        # writes scripts/renders/tuning_options/

D Kurd pair: the D3 ding (146.83 Hz) drives A4 at its 3rd harmonic (440.49 Hz)
through the fund x octave chain from scripts/sympathetic_test.py (3c settings).
The swell's timing is set by how far the listening resonator sits from 3 x f0;
3c used 1.86 Hz. Equal temperament puts A4 only 0.49 Hz away.

  a_equal_tempered     A4 at 440.00 is the listener. Nothing adjusted: 0.49 Hz
                       off, so the swell comes late and keeps going.
  b_in_tune_offset     A4 stays at 440.00 when struck; the swell rings in a
                       separate sympathetic resonator at 3 x f0 - 1.86 Hz.
  c_detuned_a4         A4 itself retuned to 3 x f0 - 1.86 Hz (438.63, 5 cents
                       flat): one field does both, as on a real pan.

Each file is the same phrase: ding, A4 at 1.3 s, ding at 2.6 s. b and c should
sound alike on the ding strikes; they differ when A4 is struck (pitch, and how
it beats against the still-ringing ding).
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from one_field import LN1000, Params, Strike, default_modes, lerp_register, write_wav  # noqa: E402

OUT = Path(__file__).parent / "renders" / "tuning_options"
SR = 48000
DING = 146.83
A4 = 440.00
OFFSET_HZ = 1.86   # listener below 3 x f0, from 3c (C#3 ding, G#4 at 415.25)
KAPPA = 0.025      # in-field fund -> octave -> twelfth, 3c
C12 = 0.116        # ding fund x octave -> listener, 3c's 0.058 doubled because the listener
                   # radiates at 1.0 here (a normal field), not 3c's 2.0


class Osc:
    """A bank of damped oscillators stepped with the exact propagator."""

    def __init__(self, freqs, t60s, outs):
        dt = 1.0 / SR
        self.n = len(freqs)
        self.omega = [2 * math.pi * f for f in freqs]
        self.out = list(outs)
        self.prop = []
        for w, t in zip(self.omega, t60s):
            s = LN1000 / t
            d = math.sqrt(w * w - s * s)
            e, c, sn = math.exp(-s * dt), math.cos(d * dt), math.sin(d * dt)
            self.prop.append((e * (c + s / d * sn), e * sn / d, -e * w * w / d * sn, e * (c - s / d * sn)))
        self.q = [0.0] * self.n
        self.v = [0.0] * self.n


def field(f0):
    modes = default_modes(f0)
    return Osc([f0 * m.ratio for m in modes], [m.t60 for m in modes], [m.out for m in modes]), modes


def strike_events(bank, modes, strike, onset_s):
    """Per-sample (drive per mode, damping per mode) for one strike, as one_field.render."""
    dt = 1.0 / SR
    w1 = bank.omega[0]
    tau = strike.contact_ms / 1000.0 * (max(strike.force, 0.05) / 0.7) ** -0.2
    length = max(2, int(round(tau * SR)))
    phi = [m.shape(strike.x, strike.y, strike.radius) for m in modes]
    g = [math.exp(-0.5 * ((i + 0.5 - length / 2) / (length / 6)) ** 2) for i in range(length)]
    pulse = [strike.force * w1 * v / (sum(g) * dt) for v in g]
    c = Params.contact_damping * (strike.radius / 0.2) ** 2
    damp = [math.exp(-2.0 * c * p * p * dt) for p in phi]
    start = int(onset_s * SR)
    return {start + i: ([p * pulse[i] for p in phi], damp) for i in range(length)}


def render(option, seconds=4.6):
    dt = 1.0 / SR
    harmonic = 3 * DING
    a4_freq = harmonic - OFFSET_HZ if option == "c" else A4
    ding, ding_modes = field(DING)
    a4, a4_modes = field(a4_freq)
    banks = [ding, a4]
    if option == "b":
        f = harmonic - OFFSET_HZ
        t = lerp_register(f, 3.2, 2.5)
        res = Osc([f, 2 * f], [t, t * 0.8], [1.0, 0.5])
        banks.append(res)
        listener = res
    else:
        listener = a4

    pad = Strike(x=0.0, y=0.05, force=0.7, contact_ms=1.5, radius=0.2)
    tip = Strike(x=0.2, y=0.1, force=0.6)
    events = [(ding, strike_events(ding, ding_modes, pad, 0.0)),
              (a4, strike_events(a4, a4_modes, tip, 1.3)),
              (ding, strike_events(ding, ding_modes, pad, 2.6))]

    k_ding = KAPPA * ding.omega[0] ** 2
    k_a4 = KAPPA * a4.omega[0] ** 2
    k_res = KAPPA * listener.omega[0] ** 2
    k12 = C12 * ding.omega[0] ** 2
    w_ref = ding.omega[0]

    total = int(seconds * SR)
    y = np.zeros(total)
    for i in range(total):
        forces = []
        for bank, k in ((ding, k_ding), (a4, k_a4)):
            q1, q2, q3 = bank.q[0], bank.q[1], bank.q[2]
            f = [0.0] * bank.n
            f[0] = -(2 * k * q1 * q2 + k * q2 * q3)
            f[1] = -(k * q1 * q1 + k * q1 * q3)
            f[2] = -(k * q1 * q2)
            forces.append(f)
        if listener is not a4:
            l1, l2 = listener.q[0], listener.q[1]
            forces.append([-2 * k_res * l1 * l2, -k_res * l1 * l1])
        # chain: V = -k12 q1 q2 l1 between the ding's fund/octave and the listener's fundamental
        d1, d2, l1 = ding.q[0], ding.q[1], listener.q[0]
        fd = forces[0]
        fl = forces[banks.index(listener)]
        fd[0] += k12 * d2 * l1
        fd[1] += k12 * d1 * l1
        fl[0] += k12 * d1 * d2

        for bank, f in zip(banks, forces):
            ev = [e[i] for b, e in events if b is bank and i in e]
            for m in range(bank.n):
                a, b_, c_, d = bank.prop[m]
                qm, vm = a * bank.q[m] + b_ * bank.v[m], c_ * bank.q[m] + d * bank.v[m]
                fm = f[m]
                for drive, damp in ev:
                    fm += drive[m]
                    vm *= damp[m]
                vm += fm * dt
                bank.q[m], bank.v[m] = qm, vm
        y[i] = sum(bk.out[m] * bk.v[m] for bk in banks for m in range(bk.n)) / w_ref
    return y, a4_freq


def swell_peak(y, f, seconds=1.2):
    """Peak time (ms) and level (dB re the overall peak) of the band at f, first strike only."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    z = y[:n] * np.exp(-2j * np.pi * f * t)
    k = SR // 25
    env = np.abs(np.convolve(z, np.ones(k) / k, "same"))
    i = int(np.argmax(env[int(0.05 * SR):])) + int(0.05 * SR)
    return 1000 * i / SR, 20 * math.log10(env[i] / np.abs(y[:n]).max())


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    items = [("a_equal_tempered", "a"), ("b_in_tune_offset", "b"), ("c_detuned_a4", "c")]
    clips = []
    for name, opt in items:
        y, a4_freq = render(opt)
        ms, lvl = swell_peak(y, 3 * DING)
        cents = 1200 * math.log2(a4_freq / A4)
        print(f"{name:20s} A4 struck at {a4_freq:.2f} Hz ({cents:+.1f} c)   swell peak {ms:4.0f} ms at {lvl:+.0f} dB")
        clips.append((name, y))

    peak = max(np.abs(y).max() for _, y in clips)
    gap = np.zeros(int(0.6 * SR))
    tour = []
    for name, y in clips:
        y = y * 0.9 / peak
        write_wav(OUT / f"{name}.wav", y, SR)
        tour += [y, gap]
    write_wav(OUT / "tour.wav", np.concatenate(tour), SR)
    print(f"\nwrote {len(clips)} clips and tour.wav to {OUT} (one gain for all three)")


if __name__ == "__main__":
    main()
