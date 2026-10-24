#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""One struck note plus one listening note: is the bwom sympathetic resonance?

    uv run scripts/sympathetic_test.py        # writes scripts/renders/sympathetic/

Matches the Shaktipan first note (reference/recordings/fs493864, 0.0 s): a C#3
ding is struck; a G#4 field tuned to the ding's 3rd partial (6 cents flat, as
measured) is never touched. Its octave rides along at 6 x the ding, as in the
recording. The ding is the one_field model; the listener has no strike.

Three ways the ding can drive the listener, each a coupling strength:
- g:   linear, the ding's own twelfth mode <-> listener (V = -g w_a w_b q_a q_b).
       Pure sympathetic resonance. Too weak on its own: the ding's twelfth
       holds too little energy to bring the listener near the fundamental.
- c3:  ding fundamental cubed -> listener (V = -k3 q1^3 l1). Peaks too early
       (~150 ms): it follows the fundamental, which is already fading.
- c12: ding fundamental x ding octave -> listener (V = -k12 q1 q2 l1). Two steps
       (fund -> octave -> 3 x f0), so it builds more slowly and peaks at
       200-300 ms like the recording. The shell's own nonlinearity makes the
       3 x f0 motion; the G#4 field is what stores and radiates it.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from bwom_demo import excerpt  # noqa: E402
from one_field import LN1000, Params, Strike, default_modes, lerp_register, write_wav  # noqa: E402

OUT = Path(__file__).parent / "renders" / "sympathetic"
SR = 48000
DING = 139.04      # measured, fs493864 first note
LISTENER = 415.70  # measured G#4 field, fs493864 strike at 2.52 s


def render(g, strike, seconds=3.0, listener_out=1.0, kappa=Params.kappa_oct, c3=0.0, c12=0.0, listener=LISTENER):
    """Ding (6 modes, one_field physics) + G#4 listener (fundamental, octave), linearly coupled.

    Returns the mix and per-component envelopes (1 ms): ding fund, ding 3x, listener fund.
    """
    dt = 1.0 / SR
    modes = default_modes(DING)
    t_l = lerp_register(listener, 3.2, 2.5)
    # listener: (freq Hz, T60, radiation weight); its octave is driven by its own fundamental
    # through the same quadratic coupling the struck field uses
    lst = [(listener, t_l, listener_out), (2 * listener, t_l * 0.8, 0.5 * listener_out)]

    freqs = [DING * m.ratio for m in modes] + [f for f, _, _ in lst]
    t60s = [m.t60 for m in modes] + [t for _, t, _ in lst]
    outs = [m.out for m in modes] + [o for _, _, o in lst]
    n = len(freqs)
    omega = [2 * math.pi * f for f in freqs]
    sigma = [LN1000 / t for t in t60s]
    prop = []
    for w, s in zip(omega, sigma):
        d = math.sqrt(w * w - s * s)
        e, c, sn = math.exp(-s * dt), math.cos(d * dt), math.sin(d * dt)
        prop.append((e * (c + s / d * sn), e * sn / d, -e * w * w / d * sn, e * (c - s / d * sn)))

    # strike on the ding (Gaussian pulse, contact damping), as one_field.render
    tau = strike.contact_ms / 1000.0 * (max(strike.force, 0.05) / 0.7) ** -0.2
    length = max(2, int(round(tau * SR)))
    phi = [m.shape(strike.x, strike.y, strike.radius) for m in modes] + [0.0, 0.0]
    w1 = omega[0]
    gs = [math.exp(-0.5 * ((i + 0.5 - length / 2) / (length / 6)) ** 2) for i in range(length)]
    pulse = [strike.force * w1 * v / (sum(gs) * dt) for v in gs]
    cdamp = Params.contact_damping * (strike.radius / 0.2) ** 2
    damp = [math.exp(-2.0 * cdamp * p * p * dt) for p in phi]

    k1 = kappa * w1 * w1
    k2 = kappa * w1 * w1
    kl = kappa * omega[6] ** 2               # listener fund -> its octave, same strength
    gc = g * omega[2] * omega[6]             # ding twelfth <-> listener fundamental
    k3 = c3 * omega[6] ** 2                  # ding fundamental^3 -> listener (V = -k3 q1^3 l1)
    k12 = c12 * w1 * w1                      # ding fund x octave -> listener (V = -k12 q1 q2 l1)

    q = [0.0] * n
    v = [0.0] * n
    total = int(seconds * SR)
    y = np.zeros(total)
    env = np.zeros((3, total // 48 + 1))
    for i in range(total):
        q1, q2, q3, l1, l2 = q[0], q[1], q[2], q[6], q[7]
        f = [0.0] * n
        f[0] = -(2 * k1 * q1 * q2 + k2 * q2 * q3) + 3 * k3 * q1 * q1 * l1 + k12 * q2 * l1
        f[1] = -(k1 * q1 * q1 + k2 * q1 * q3) + k12 * q1 * l1
        f[2] = -(k2 * q1 * q2) + gc * l1
        f[6] = gc * q3 + k3 * q1 * q1 * q1 + k12 * q1 * q2 - 2 * kl * l1 * l2
        f[7] = -kl * l1 * l1
        on = i < length
        acc = 0.0
        for m in range(n):
            a, b, c_, d = prop[m]
            qm, vm = a * q[m] + b * v[m], c_ * q[m] + d * v[m]
            fm = f[m]
            if on:
                fm += phi[m] * pulse[i]
                vm *= damp[m]
            vm += fm * dt
            q[m], v[m] = qm, vm
            acc += outs[m] * vm
        y[i] = acc / w1
        if i % 48 == 0:
            k = i // 48
            for j, m in enumerate((0, 2, 6)):
                env[j, k] = outs[m] * math.hypot(v[m], omega[m] * q[m]) / w1
    return y, env


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    strike = Strike(x=0.0, y=0.05, force=0.7, contact_ms=1.5, radius=0.2)
    # listener_out 2: the G#4 field radiates twice as strongly as the ding fundamental (a guess;
    # needed to reach the recording's level)
    items = [
        ("1_ding_alone", dict(kappa=0.025), "the ding by itself, no listener"),
        ("2_linear_only", dict(kappa=0.025, g=0.008, listener_out=2.0), "plain sympathetic resonance via the ding's twelfth"),
        ("3_chain", dict(kappa=0.025, c12=0.15, listener_out=2.0), "fund x octave -> G#4: closest to the recording"),
        ("3a_chain_weak", dict(kappa=0.025, c12=0.08, listener_out=2.0), "chain at half strength"),
        ("3b_chain_weaker_peak280", dict(kappa=0.025, c12=0.05, listener_out=2.0), "chain at a third strength"),
        ("3c_chain_weaker_peak250", dict(kappa=0.025, c12=0.058, listener_out=2.0, listener=415.25),
         "3b with the G#4 a further 1.9 cents flat (2.0 Hz off), coupling nudged to keep the level"),
        ("4_chain_strong", dict(kappa=0.04, c12=0.2, listener_out=2.0), "same, stronger and faster"),
    ]
    clips = []
    times = (20, 60, 100, 150, 200, 300, 400, 600)
    print("dB re ding fundamental peak    " + " ".join(f"{t:>5d}" for t in times))
    print(f"{'5_reference (418 Hz band)':30s} " + " ".join(f"{v:5d}" for v in (-33, -28, -22, -12, -8, -4, -7, -14)))
    for name, kw, note in items:
        g = kw.pop("g", 0.0)
        y, env = render(g, strike, **kw)
        ref = env[0].max()
        row = " ".join(f"{20 * math.log10(max(env[2][t], 1e-12) / ref):5.0f}" for t in times)
        pk = int(np.argmax(env[2][50:700])) + 50
        peak = f"peak {pk:3d} ms" if env[2][pk] > 1e-9 else " " * 11
        print(f"{name:30s} {row}  {peak}   {note}")
        clips.append((name, y))
    clips.append(("5_reference_shaktipan_first", excerpt("fs493864_shaktipan_csharp.wav", 0.0, 0.6)))

    gap = np.zeros(int(0.6 * SR))
    tour = []
    for name, y in clips:
        y = y * 0.9 / np.abs(y).max()
        write_wav(OUT / f"{name}.wav", y, SR)
        tour += [y, gap]
    write_wav(OUT / "tour.wav", np.concatenate(tour), SR)
    print(f"\nwrote {len(clips)} clips and tour.wav to {OUT}")


if __name__ == "__main__":
    main()
