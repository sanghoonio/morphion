#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""One handpan tone field as a modal model, rendered to WAV.

Parameter sources and reasoning: docs/handpan-acoustics.md.

    uv run scripts/one_field.py                      # demo set for D4
    uv run scripts/one_field.py --note A3            # demo set for another note
    uv run scripts/one_field.py --strike 0.4,0.1 --force 0.8 --contact-ms 3

Model
-----
Each mode n is a damped oscillator

    q_n'' + 2 sigma_n q_n' + omega_n^2 q_n = phi_n(x, y) F(t) - dV/dq_n

- phi_n is the mode shape at the strike point, so strike position sets how
  hard each mode is driven. Field coordinates are normalised so the elliptical
  field is the unit disc, x along the long axis.
- F(t) is a Gaussian contact pulse of length tau (sd tau/6). Its impulse
  scales with force; tau sets brightness (long contact low-passes the strike).
  tau shortens slightly with force (Hertz).
- While the finger touches, each mode gets extra damping proportional to
  phi_n^2 at the contact (the finger is a dashpot).
- V = k1 q1^2 q2 + k2 q1 q2 q3 couples fundamental -> octave -> twelfth
  (the 1:2 and 1:2:3 internal resonances in Monteil/Touze/Thomas). This makes
  the upper partials bloom in after the fundamental, more so on harder strikes,
  and lets a dead-centre strike (where the octave and twelfth shapes are zero)
  still grow them.

The nonlinear part is time-stepped per sample for the strikes plus a window
after the last one, then each mode continues in closed form. Modal state is
never reset between strikes (Wessel et al. 2008).
"""

from __future__ import annotations

import argparse
import math
import re
import time
import wave
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np

LN1000 = math.log(1000.0)


# ---------------------------------------------------------------- modes

def shape_fund(x, y, a):
    # (0,1): whole field in phase. 1 - r^2 averaged over a contact disc of radius a.
    return max(0.0, 1.0 - x * x - y * y - 0.5 * a * a)


def shape_octave(x, y, a):
    # (1,1)a: nodal line across the long axis
    return x


def shape_twelfth(x, y, a):
    # (1,1)b: nodal line along the long axis
    return y


def shape_upper_a(x, y, a):
    return x * x - y * y


def shape_upper_b(x, y, a):
    return 2.0 * x * y


def shape_upper_axi(x, y, a):
    # axisymmetric upper mode, non-zero at the centre so centre strikes keep some attack
    return 1.0 - 3.0 * (x * x + y * y) - 1.5 * a * a


@dataclass
class Mode:
    name: str
    ratio: float      # frequency / f0
    t60: float        # seconds
    shape: object     # (x, y, contact_radius) -> modal amplitude
    out: float        # radiation weight


def lerp_register(f0, low, high, f_low=123.0, f_high=523.0):
    """Interpolate a value from B2 (low) to C5 (high), clamped."""
    t = (math.log(f0) - math.log(f_low)) / (math.log(f_high) - math.log(f_low))
    t = min(1.0, max(0.0, t))
    return low + (high - low) * t


def default_modes(f0, octave_cents=0.0, twelfth_cents=0.0):
    t_fund = lerp_register(f0, 3.2, 2.5)  # Alon 2015 register means
    return [
        Mode("fund", 1.0, t_fund, shape_fund, 1.0),
        Mode("octave", 2.0 * 2 ** (octave_cents / 1200), t_fund * lerp_register(f0, 1.0, 0.8), shape_octave, 0.5),
        Mode("twelfth", 3.0 * 2 ** (twelfth_cents / 1200), t_fund * lerp_register(f0, 0.9, 0.45), shape_twelfth, 0.35),
        Mode("upper_a", 7.5, 0.6, shape_upper_a, 0.25),
        Mode("upper_b", 8.2, 0.5, shape_upper_b, 0.25),
        Mode("upper_axi", 9.1, 0.4, shape_upper_axi, 0.2),
    ]


# ---------------------------------------------------------------- strikes

@dataclass
class Strike:
    t: float = 0.0            # onset, seconds
    x: float = 0.0            # field coords, unit disc
    y: float = 0.0
    force: float = 0.7        # 0..1, scales the impulse
    contact_ms: float = 1.2   # tau at force 0.7: ~0.4 nail, ~1.2 fingertip, ~2.5 thumb, ~5 palm
    radius: float = 0.15      # contact radius in field units


@dataclass
class Params:
    sr: int = 48000
    kappa_oct: float = 0.025  # fund^2 -> octave coupling, in units of omega_1^2
    kappa_12: float = 0.025   # fund*octave -> twelfth coupling
    contact_damping: float = 60.0  # extra sigma (1/s) at phi=1 for a 0.2-radius contact
    nl_window: float = 0.8    # seconds of nonlinear stepping after the last strike's onset
    tail: float = 4.0         # seconds rendered after the last strike


def render(f0, modes, strikes, p: Params):
    """Return (signal, per-mode amplitude envelopes at 1 ms, envelope rate)."""
    sr = p.sr
    dt = 1.0 / sr
    n_modes = len(modes)
    t_last = max(s.t for s in strikes)
    n_total = int((t_last + p.tail) * sr)
    n_nl = min(n_total, int((t_last + p.nl_window) * sr))

    w1 = 2 * math.pi * f0
    omega = [2 * math.pi * f0 * m.ratio for m in modes]
    sigma = [LN1000 / m.t60 for m in modes]
    wd = [math.sqrt(w * w - s * s) for w, s in zip(omega, sigma)]

    # exact one-step propagator for each free damped oscillator
    prop = []
    for w, s, d in zip(omega, sigma, wd):
        e, c, sn = math.exp(-s * dt), math.cos(d * dt), math.sin(d * dt)
        prop.append((e * (c + s / d * sn), e * sn / d, -e * w * w / d * sn, e * (c - s / d * sn)))

    # per-strike precomputation: start/end sample, drive gains, contact damping factors
    events = []
    for s in strikes:
        # Hertzian contact: harder strikes compress faster, tau ~ v^(-1/5)
        tau = s.contact_ms / 1000.0 * (max(s.force, 0.05) / 0.7) ** -0.2
        start = int(s.t * sr)
        length = max(2, int(round(tau * sr)))
        phi = [m.shape(s.x, s.y, s.radius) for m in modes]
        impulse = s.force * w1  # so the fundamental reaches amplitude ~force at the centre
        c = p.contact_damping * (s.radius / 0.2) ** 2
        damp = [math.exp(-2.0 * c * ph * ph * dt) for ph in phi]
        # Gaussian pulse (sd tau/6) normalised to the impulse; unlike a raised cosine it has no
        # spectral nulls, which otherwise land on individual modes and notch them out
        g = [math.exp(-0.5 * ((i + 0.5 - length / 2) / (length / 6)) ** 2) for i in range(length)]
        pulse = [impulse * gi / (sum(g) * dt) for gi in g]
        events.append((start, length, phi, damp, pulse))

    k1 = p.kappa_oct * w1 * w1
    k2 = p.kappa_12 * w1 * w1
    out_w = [m.out for m in modes]

    q = [0.0] * n_modes
    v = [0.0] * n_modes
    y = np.zeros(n_total)
    env_step = sr // 1000
    env = np.zeros((n_modes, n_nl // env_step + 1))

    for i in range(n_nl):
        # nonlinear coupling forces, -dV/dq
        q1, q2, q3 = q[0], q[1], q[2]
        fnl = [0.0] * n_modes
        fnl[0] = -(2 * k1 * q1 * q2 + k2 * q2 * q3)
        fnl[1] = -(k1 * q1 * q1 + k2 * q1 * q3)
        fnl[2] = -(k2 * q1 * q2)

        drive = None
        damp = None
        for start, length, phi, dmp, pulse in events:
            j = i - start
            if 0 <= j < length:
                f = pulse[j]
                if drive is None:
                    drive = [0.0] * n_modes
                    damp = [1.0] * n_modes
                for n in range(n_modes):
                    drive[n] += phi[n] * f
                    damp[n] *= dmp[n]

        acc = 0.0
        for n in range(n_modes):
            a, b, c_, d = prop[n]
            qn, vn = q[n], v[n]
            qn, vn = a * qn + b * vn, c_ * qn + d * vn
            f = fnl[n] if n < 3 else 0.0
            if drive is not None:
                f += drive[n]
                vn *= damp[n]
            vn += f * dt
            q[n], v[n] = qn, vn
            acc += out_w[n] * vn
        y[i] = acc / w1

        if i % env_step == 0:
            k = i // env_step
            for n in range(n_modes):
                env[n, k] = out_w[n] * math.sqrt(v[n] ** 2 + (omega[n] * q[n]) ** 2) / w1

    # closed-form linear continuation
    if n_total > n_nl:
        t = np.arange(1, n_total - n_nl + 1) * dt
        tail = np.zeros_like(t)
        for n in range(n_modes):
            s_, d_, w_ = sigma[n], wd[n], omega[n]
            q0, v0 = q[n], v[n]
            e = np.exp(-s_ * t)
            c, sn = np.cos(d_ * t), np.sin(d_ * t)
            vel = e * (v0 * (c - s_ / d_ * sn) - q0 * (w_ * w_ / d_) * sn)
            tail += out_w[n] * vel
        y[n_nl:] = tail / w1

    return y, env


# ---------------------------------------------------------------- io and reporting

def note_to_hz(name):
    m = re.fullmatch(r"([A-Ga-g])([#b]?)(-?\d)", name.strip())
    if not m:
        raise ValueError(f"bad note name: {name}")
    pc = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}[m.group(1).upper()]
    pc += {"#": 1, "b": -1, "": 0}[m.group(2)]
    midi = 12 * (int(m.group(3)) + 1) + pc
    return 440.0 * 2 ** ((midi - 69) / 12)


def write_wav(path, y, sr):
    pcm = np.clip(y, -1, 1)
    pcm = (pcm * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def describe(modes, env, skip_ms=10):
    """Peak level (dB re fundamental peak) and peak time (ms) for each mode.

    The first skip_ms are ignored: mid-contact a mode can swing harder than it
    ends up ringing, which would overstate the upper modes on long contacts.
    """
    env = env[:, skip_ms:]
    ref = env[0].max() or 1.0
    parts = []
    for n, m in enumerate(modes):
        pk = env[n].max()
        db = 20 * math.log10(pk / ref) if pk > 0 else -120
        parts.append(f"{m.name} {db:+6.1f}dB@{int(env[n].argmax()) + skip_ms:4d}ms")
    return "  ".join(parts)


def demo_set():
    """(filename, strikes, note) for each render in the demo."""
    off = dict(x=0.2, y=0.1)
    items = [
        ("01_pos_centre", [Strike(x=0.0, y=0.0)], "dead centre: fundamental, octave/twelfth only via coupling"),
        ("02_pos_octave_spot", [Strike(x=0.5, y=0.0)], "on the long axis: octave up"),
        ("03_pos_fifth_spot", [Strike(x=0.0, y=0.5)], "on the short axis: twelfth up"),
        ("04_pos_diagonal", [Strike(x=0.35, y=0.35)], "between: both, plus upper_b"),
        ("05_pos_near_edge", [Strike(x=0.8, y=0.0)], "near the rim: weak fundamental"),
        ("06_contact_nail", [Strike(**off, contact_ms=0.4, radius=0.08)], "nail: very short contact, bright"),
        ("07_contact_fingertip", [Strike(**off, contact_ms=1.2, radius=0.15)], "fingertip"),
        ("08_contact_thumb", [Strike(**off, contact_ms=2.5, radius=0.3)], "thumb: longer, darker"),
        ("09_contact_palm", [Strike(**off, contact_ms=5.0, radius=0.7)], "palm: long and broad, thuddy"),
        ("10_force_soft", [Strike(**off, force=0.25)], "soft: little bloom"),
        ("11_force_medium", [Strike(**off, force=0.5)], "medium"),
        ("12_force_hard", [Strike(**off, force=1.0)], "hard: more bloom and upper partials"),
    ]
    spots = [(0.2, 0.1), (0.45, -0.05), (-0.1, 0.4), (0.3, 0.3), (0.0, 0.05), (0.5, 0.1), (-0.05, -0.45), (0.25, 0.15)]
    roll = [Strike(t=0.17 * i, x=x, y=y, force=0.45 + 0.1 * (i % 3)) for i, (x, y) in enumerate(spots)]
    items.append(("13_roll", roll, "eight strikes, state carried between them"))
    return items


def jitter(strikes, amount, rng):
    if amount <= 0:
        return strikes
    return [replace(s, x=s.x + rng.normal(0, amount), y=s.y + rng.normal(0, amount),
                    force=s.force * (1 + rng.normal(0, amount))) for s in strikes]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--note", default="D4")
    ap.add_argument("--out", type=Path, default=Path(__file__).parent / "renders")
    ap.add_argument("--sr", type=int, default=48000)
    ap.add_argument("--kappa-oct", type=float, default=Params.kappa_oct)
    ap.add_argument("--kappa-12", type=float, default=Params.kappa_12)
    ap.add_argument("--octave-cents", type=float, default=0.0, help="detune of the octave partial")
    ap.add_argument("--twelfth-cents", type=float, default=0.0, help="detune of the twelfth partial")
    ap.add_argument("--jitter", type=float, default=0.0, help="random spread of strike position/force (e.g. 0.03)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--strike", help="x,y in field coords: render one strike instead of the demo set")
    ap.add_argument("--force", type=float, default=0.7)
    ap.add_argument("--contact-ms", type=float, default=Strike.contact_ms)
    ap.add_argument("--radius", type=float, default=Strike.radius)
    args = ap.parse_args()

    f0 = note_to_hz(args.note)
    modes = default_modes(f0, args.octave_cents, args.twelfth_cents)
    p = Params(sr=args.sr, kappa_oct=args.kappa_oct, kappa_12=args.kappa_12)
    rng = np.random.default_rng(args.seed)

    if args.strike:
        x, y = (float(v) for v in args.strike.split(","))
        items = [("strike", [Strike(x=x, y=y, force=args.force, contact_ms=args.contact_ms, radius=args.radius)], "")]
    else:
        items = demo_set()

    out_dir = args.out / args.note
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"{args.note} = {f0:.2f} Hz   modes: " + ", ".join(f"{m.name} {m.ratio * f0:.0f}Hz T60 {m.t60:.1f}s" for m in modes))

    t0 = time.time()
    rendered = []
    for name, strikes, note in items:
        y, env = render(f0, modes, jitter(strikes, args.jitter, rng), p)
        rendered.append((name, y))
        print(f"{name:22s} {describe(modes, env)}   {note}")

    # one gain for the whole set so loudness differences between renders are real
    peak = max(np.abs(y).max() for _, y in rendered)
    gain = 0.9 / peak
    gap = np.zeros(int(0.4 * args.sr))
    tour = []
    for name, y in rendered:
        write_wav(out_dir / f"{name}.wav", y * gain, args.sr)
        tour += [y * gain, gap]
    if len(rendered) > 1:
        write_wav(out_dir / "tour.wav", np.concatenate(tour), args.sr)
    print(f"\nwrote {len(rendered)} file(s) to {out_dir}  ({time.time() - t0:.1f}s)")


if __name__ == "__main__":
    main()
