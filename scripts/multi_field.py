#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""Several tone fields with cross-field coupling: the reference for the engine's links.

    uv run scripts/multi_field.py              # A/B set, writes scripts/renders/multi_field/
    uv run scripts/multi_field.py --check      # parity checks against one_field / tuning_options

Each field is the one_field model. Where a field's fundamental sits within
TOL_CENTS of a lower field's 2nd or 3rd harmonic, the two are linked and the
listener is retuned to (harmonic - gap), so a strike on the lower field makes
the listener swell in and peak after about 1 / (2 gap) (plans/2026-10-24-cross-field-coupling.md):

- 3x: V = -k3x q1 q2 l1, the source's fund x octave drives the listener's fundamental
      (the chain from scripts/sympathetic_test.py, 3c).
- 2x: V = -k2x q1^2 l1, the source's fundamental squared drives it directly.

k3x and k2x are in units of the source's omega_1^2. Back-reaction on the source
is included, so the links move energy without adding it. Each field's output is
divided by omega_1^(1 - RADIATION_TILT) * omega_ref^RADIATION_TILT, as in the
engine: tilt 0 makes every struck note equally loud in level; a negative tilt
makes lower fields louder, so they sound as loud as the higher ones (the ear is
less sensitive at the ding's pitch). The tilt also scales each listener's
sympathetic swell against the ding's level, so K3X is raised to compensate.
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from one_field import LN1000, Params, Strike, default_modes, note_to_hz, write_wav

OUT = Path(__file__).parent / "renders" / "multi_field"
TOL_CENTS = 30.0
GAP_HZ = 1.3       # 3x listener below the harmonic (A4 -3.2 c): swell peaks ~230 ms with K3X 0.2
GAP_2X_HZ = 0.45   # 2x listener (D4): 2.7 cents flat, swell peaks ~430 ms; chosen by ear
K3X = 0.2          # raised from 3c's level (0.116) to keep the A4 swell at ~-30 dB with the tilt below
K2X = 0.02         # 2x: D4 swell ~ -20 dB at ~290 ms after a ding strike; untested by ear

RADIATION_TILT = -0.1  # lower fields slightly louder (D3 +0.9 dB vs G4), set by ear on headphones
TILT_REF_HZ = 293.66   # D4 is unchanged by the tilt

KURD9 = ["F4", "A4", "G4", "D4", "D3", "E4", "Bb3", "A3", "C4"]   # app grid order


@dataclass
class Gu:
    """The air cavity under the Gu hole: one Helmholtz resonator shared by all fields.

    Each field's fundamental pushes air through it. A strike kicks it directly
    (kick: Gu amplitude per unit field amplitude) and it is linearly coupled both
    ways to every fundamental (couple: V = -g w_h w_1 q_h q_1). weights scales both
    per field (the ding moves far more air than the outer notes). octave: optional
    1:2 link to one field, V = -k w_h^2 q_h^2 q_1, for a Gu tuned an octave below the ding.
    Nothing here is measured beyond the frequency (73-85 Hz): all set by ear.
    """
    f: float = 80.0
    t60: float = 0.5         # Q ~ 18
    out: float = 1.0
    kick: float = 0.0
    couple: float = 0.0
    weights: tuple = ()      # per field; default 1.0
    octave: tuple = ()       # (field index, k)


def gu_detune(freqs, gu, iterations=20):
    """Nominal (uncoupled) field and cavity frequencies that land on freqs and gu.f once
    coupled, as a tuner would tune the assembled pan.

    The coupled system is an arrowhead matrix (fields on the diagonal, the cavity in
    the last row and column), so its frequencies are the roots of
    F(l) = l - w_h^2 - sum_j c_j^2 / (l - w_j^2), c_j = couple * weight_j * w_h * w_j.
    The cavity is the root below the lowest field; field j is the root just above
    w_j^2. Fixed-point iteration on the nominal values. Mirrored in the engine.
    """
    wt = [2 * math.pi * f for f in freqs]
    wht = 2 * math.pi * gu.f
    w = list(wt)
    wh = wht
    n = len(freqs)
    wts = [gu.weights[j] if j < len(gu.weights) else 1.0 for j in range(n)]
    order = sorted(range(n), key=lambda j: w[j])

    def root(lo, hi, c2, wh2, poles):
        for _ in range(100):
            mid = 0.5 * (lo + hi)
            fv = mid - wh2 - sum(cc / (mid - pp) for cc, pp in zip(c2, poles))
            lo, hi = (mid, hi) if fv < 0 else (lo, mid)
        return 0.5 * (lo + hi)

    for _ in range(iterations):
        poles = [w[j] ** 2 for j in range(n)]
        c2 = [(gu.couple * wts[j] * wh * w[j]) ** 2 for j in range(n)]
        sp = [poles[j] for j in order]
        lam_h = root(0.0, sp[0], c2, wh * wh, poles)
        lam = [0.0] * n
        for k, j in enumerate(order):
            hi = sp[k + 1] if k + 1 < n else sp[k] * 4.0 + 4.0 * wh * wh
            lam[j] = root(poles[j], hi, c2, wh * wh, poles)
        wh *= wht / math.sqrt(lam_h)
        w = [w[j] * wt[j] / math.sqrt(lam[j]) for j in range(n)]
    return [x / (2 * math.pi) for x in w], wh / (2 * math.pi)


def default_gu(freqs):
    """The chosen cavity (scripts/renders/gu/3_ding_gu_shaktipan.wav): 80 Hz, coupling 0.2,
    the lowest field (the ding) weighted 1.0 and the rest 0.15."""
    ding = freqs.index(min(freqs))
    return Gu(f=80.0, couple=0.2, weights=tuple(1.0 if j == ding else 0.15 for j in range(len(freqs))))


@dataclass
class Link:
    src: int
    dst: int
    order: int       # 2 or 3
    k: float         # units of the source's omega_1^2


def layout(freqs, gap_hz=GAP_HZ, gap_2x_hz=GAP_2X_HZ, k3x=K3X, k2x=K2X, tol_cents=TOL_CENTS):
    """Find harmonic pairs, retune listeners, return (tuned freqs, links).

    A listener with several sources is tuned to the lowest one; the others get
    whatever gap results.
    """
    gap = {2: gap_2x_hz, 3: gap_hz}
    strength = {2: k2x, 3: k3x}
    tuned = list(freqs)
    links = []
    for j, fj in enumerate(freqs):
        pairs = []
        for i, fi in enumerate(freqs):
            for n in (2, 3):
                if fi < fj and abs(1200 * math.log2(fj / (n * fi))) < tol_cents:
                    pairs.append((fi, i, n))
        if not pairs:
            continue
        fi, i, n = min(pairs)
        tuned[j] = n * fi - gap[n]
        links += [Link(i, j, n, strength[n]) for _, i, n in pairs if strength[n] > 0]
    return tuned, links


def render(freqs, links, strikes, seconds, p: Params = Params(), out_omega=None, tilt=None, gu: Gu | None = None,
           gu_tune=True):
    """strikes: [(onset s, field index, Strike)]. Returns the mono mix.

    gu_tune: detune fields and cavity (gu_detune) so they sound at freqs and gu.f with
    the coupling in place. Without it the cavity pulls the ding ~14 cents sharp.

    out_omega: divide every field's output by this instead of its own omega_1
    (only to compare with tuning_options.py, which used the ding's).
    """
    sr = p.sr
    dt = 1.0 / sr
    nf = len(freqs)
    # cents to add to each field's octave and twelfth so they stay at 2x and 3x the
    # pitch heard (only the fundamental feels the cavity)
    keep = [0.0] * nf
    if gu is not None and gu_tune and gu.couple > 0:
        heard = freqs
        freqs, gu_f = gu_detune(freqs, gu)
        keep = [1200 * math.log2(h / f) for h, f in zip(heard, freqs)]
        gu = Gu(**{**gu.__dict__, "f": gu_f})
    tilt = RADIATION_TILT if tilt is None else tilt
    w_ref = 2 * math.pi * TILT_REF_HZ
    fields = []
    for f0, cents in zip(freqs, keep):
        modes = default_modes(f0, cents, cents)
        omega = [2 * math.pi * f0 * m.ratio for m in modes]
        prop = []
        for m, w in zip(modes, omega):
            s = LN1000 / m.t60
            d = math.sqrt(w * w - s * s)
            e, c, sn = math.exp(-s * dt), math.cos(d * dt), math.sin(d * dt)
            prop.append((e * (c + s / d * sn), e * sn / d, -e * w * w / d * sn, e * (c - s / d * sn)))
        w1 = omega[0]
        fields.append(dict(modes=modes, prop=prop, w1=w1, out=[m.out for m in modes],
                           norm=1.0 / (out_omega or w1 ** (1 - tilt) * w_ref ** tilt), k1=p.kappa_oct * w1 * w1, k2=p.kappa_12 * w1 * w1,
                           q=[0.0] * 6, v=[0.0] * 6, active=False))

    # strike pulses, keyed by sample index per field (as one_field.render)
    pulses = [dict() for _ in range(nf)]
    for onset, fi, s in strikes:
        fd = fields[fi]
        tau = s.contact_ms / 1000.0 * (max(s.force, 0.05) / 0.7) ** -0.2
        length = max(2, int(round(tau * sr)))
        phi = [m.shape(s.x, s.y, s.radius) for m in fd["modes"]]
        g = [math.exp(-0.5 * ((i + 0.5 - length / 2) / (length / 6)) ** 2) for i in range(length)]
        amp = s.force * fd["w1"] / (sum(g) * dt)
        c = p.contact_damping * (s.radius / 0.2) ** 2
        damp = [math.exp(-2.0 * c * ph * ph * dt) for ph in phi]
        start = int(onset * sr)
        for i in range(length):
            pulses[fi].setdefault(start + i, []).append(([ph * amp * g[i] for ph in phi], damp))

    lk = [(l.src, l.dst, l.order, l.k * fields[l.src]["w1"] ** 2) for l in links]

    if gu is not None:
        wh = 2 * math.pi * gu.f
        sh = LN1000 / gu.t60
        dh = math.sqrt(wh * wh - sh * sh)
        e, c, sn = math.exp(-sh * dt), math.cos(dh * dt), math.sin(dh * dt)
        gprop = (e * (c + sh / dh * sn), e * sn / dh, -e * wh * wh / dh * sn, e * (c - sh / dh * sn))
        gw = [gu.weights[j] if j < len(gu.weights) else 1.0 for j in range(nf)]
        gcouple = [gu.couple * gw[j] * wh * fields[j]["w1"] for j in range(nf)]
        gkick = [gu.kick * gw[j] * wh / fields[j]["w1"] for j in range(nf)]   # per unit field drive
        goct = [(j, k * wh * wh) for j, k in ([gu.octave] if gu.octave else [])]
        gnorm = 1.0 / (out_omega or wh ** (1 - tilt) * w_ref ** tilt)
        qh = vh = 0.0
    total = int(seconds * sr)
    y = np.zeros(total)
    for i in range(total):
        for fi in range(nf):
            if i in pulses[fi]:
                fields[fi]["active"] = True
        for src, dst, _, _ in lk:
            if fields[src]["active"]:
                fields[dst]["active"] = True

        forces = []
        for fd in fields:
            if not fd["active"]:
                forces.append(None)
                continue
            q1, q2, q3 = fd["q"][0], fd["q"][1], fd["q"][2]
            k1, k2 = fd["k1"], fd["k2"]
            forces.append([-(2 * k1 * q1 * q2 + k2 * q2 * q3), -(k1 * q1 * q1 + k2 * q1 * q3),
                           -(k2 * q1 * q2), 0.0, 0.0, 0.0])
        for src, dst, order, k in lk:
            fs, fl = forces[src], forces[dst]
            if fs is None:
                continue
            s1, s2, l1 = fields[src]["q"][0], fields[src]["q"][1], fields[dst]["q"][0]
            if order == 3:     # V = -k q1 q2 l1
                fs[0] += k * s2 * l1
                fs[1] += k * s1 * l1
                fl[0] += k * s1 * s2
            else:              # V = -k q1^2 l1
                fs[0] += 2 * k * s1 * l1
                fl[0] += k * s1 * s1

        fh = 0.0
        if gu is not None:
            for j, fd in enumerate(fields):
                if forces[j] is None:
                    continue
                q1 = fd["q"][0]
                forces[j][0] += gcouple[j] * qh
                fh += gcouple[j] * q1
                for drive, _ in pulses[j].get(i, ()):
                    fh += gkick[j] * drive[0]
            for j, k in goct:
                if forces[j] is not None:
                    forces[j][0] += k * qh * qh
                    fh += 2 * k * qh * fields[j]["q"][0]

        acc = 0.0
        if gu is not None:
            a, b, c_, d = gprop
            qh, vh = a * qh + b * vh, c_ * qh + d * vh
            vh += fh * dt
            acc += gu.out * vh * gnorm
        for fi, fd in enumerate(fields):
            f = forces[fi]
            if f is None:
                continue
            ev = pulses[fi].get(i, ())
            q, v, prop, out = fd["q"], fd["v"], fd["prop"], fd["out"]
            part = 0.0
            for m in range(6):
                a, b, c_, d = prop[m]
                qm, vm = a * q[m] + b * v[m], c_ * q[m] + d * v[m]
                fm = f[m]
                for drive, damp in ev:
                    fm += drive[m]
                    vm *= damp[m]
                vm += fm * dt
                q[m], v[m] = qm, vm
                part += out[m] * vm
            acc += part * fd["norm"]
        y[i] = acc
    return y


def band_envelope(y, f, sr=48000):
    t = np.arange(len(y)) / sr
    z = y * np.exp(-2j * np.pi * f * t)
    k = sr // 25
    return np.abs(np.convolve(z, np.ones(k) / k, "same"))


def swell(y, f, sr=48000, t0=0.0, seconds=1.2):
    """Peak time (ms after t0) and level (dB re the overall peak in the window) of the band at f."""
    a, b = int(t0 * sr), int((t0 + seconds) * sr)
    seg = y[a:b]
    env = band_envelope(seg, f, sr)
    i = int(np.argmax(env[int(0.05 * sr):])) + int(0.05 * sr)
    return 1000 * i / sr, 20 * math.log10(env[i] / np.abs(seg).max())


# ---------------------------------------------------------------- checks

def check():
    import one_field
    import tuning_options as T

    p = Params()
    s = Strike(x=0.2, y=0.1)
    f0 = note_to_hz("D4")
    ref, _ = one_field.render(f0, default_modes(f0), [s], Params(tail=0.8))
    mine = render([f0], [], [(0.0, 0, s)], 0.8, p, tilt=0.0)
    n = min(len(ref), len(mine))
    print(f"one field vs one_field.render: max |diff| {np.abs(ref[:n] - mine[:n]).max():.2e}")

    # D3/A4 pair, option c, with tuning_options' constants and its ding-based output scaling
    yref, a4 = T.render("c", seconds=1.2)
    pad = Strike(x=0.0, y=0.05, force=0.7, contact_ms=1.5, radius=0.2)
    tip = Strike(x=0.2, y=0.1, force=0.6)
    mine = render([T.DING, a4], [Link(0, 1, 3, T.C12)], [(0.0, 0, pad), (1.3, 1, tip), (2.6, 0, pad)],
                  1.2, Params(kappa_oct=T.KAPPA, kappa_12=T.KAPPA), out_omega=2 * math.pi * T.DING)
    print(f"D3/A4 pair vs tuning_options c: max |diff| {np.abs(yref - mine).max():.2e}")

    # the C++ engine, if built (make -C engine)
    exe = Path(__file__).parent.parent / "engine" / "build" / "render_test"
    if not exe.exists():
        print("engine not built; skipping engine parity (make -C engine)")
        return
    import subprocess
    import tempfile
    import wave

    def engine(args):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "out.wav"
            subprocess.run([str(exe), *args[:1], str(path), *args[1:]] if args else [str(exe), str(path)],
                           check=True, capture_output=True)
            with wave.open(str(path)) as w:
                return np.frombuffer(w.readframes(w.getnframes()), "<i2") / 32768

    def corr(a, b, sr=48000, t=0.8):
        n = min(len(a), len(b), int(t * sr))
        return float(np.corrcoef(a[:n], b[:n])[0, 1])

    single = render([f0], [], [(0.0, 0, Strike(x=0.2, y=0.1))], 0.8, p)
    print(f"engine single field vs Python: correlation {corr(engine([]), single):.5f} (0-0.8 s)")
    et = [note_to_hz(n) for n in KURD9]
    freqs, links = layout(et)
    y = render(freqs, links, [(0.0, KURD9.index("D3"), pad)], 2.5, p, gu=default_gu(freqs))
    e = engine(["--kurd"])
    print(f"engine Kurd ding strike vs Python: correlation {corr(e, y):.5f} (0-0.8 s), "
          f"{corr(e, y, t=2.5):.5f} (0-2.5 s)")


# ---------------------------------------------------------------- A/B renders

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if args.check:
        check()
        return

    OUT.mkdir(parents=True, exist_ok=True)
    et = [note_to_hz(n) for n in KURD9]
    D3, A3, D4, A4 = (KURD9.index(n) for n in ("D3", "A3", "D4", "A4"))
    pad = Strike(x=0.0, y=0.05, force=0.7, contact_ms=1.5, radius=0.2)
    tip = Strike(x=0.2, y=0.1, force=0.6)
    clips = []

    def run(name, strikes, seconds, note, k3x=K3X, k2x=0.0, gap_2x=GAP_2X_HZ, out_omega=None):
        freqs, links = layout(et, k3x=k3x, k2x=k2x, gap_2x_hz=gap_2x)
        if not links:
            freqs = et
        y = render(freqs, links, strikes, seconds, out_omega=out_omega)
        tuning = ", ".join(f"{KURD9[j]} {1200 * math.log2(freqs[j] / et[j]):+.1f}c"
                           for j in range(len(et)) if abs(freqs[j] - et[j]) > 1e-9)
        sw = []
        struck = {fi for _, fi, _ in strikes}
        for f_idx in (A4, D4):
            if len(strikes) == 1 and any(l.dst == f_idx and l.src in struck for l in links):
                ms, lvl = swell(y, freqs[f_idx])
                sw.append(f"{KURD9[f_idx]} {ms:3.0f} ms {lvl:+4.0f} dB")
        print(f"{name:28s} {'; '.join(sw):34s} [{tuning}]  {note}")
        clips.append((name, y))

    ding = [(0.0, D3, pad)]
    run("1_ding_uncoupled", ding, 2.5, "no links, equal temperament", k3x=0.0)
    run("2_ding_3x_only", ding, 2.5, "A4 swells (3x); D4 not linked", gap_2x=1.86)
    for k2x in (0.01, 0.02, 0.04):
        run(f"3_ding_2x_k{k2x}", ding, 2.5, f"plus D4 at 2x, k2x {k2x}, gap 1.86 Hz", k2x=k2x, gap_2x=1.86)
    for gap in (0.9, 0.45):
        run(f"4_ding_2x_gap{gap}", ding, 2.5, f"k2x 0.02, D4 gap {gap} Hz (less flat)", k2x=0.02, gap_2x=gap)
    run("5_a3_strike", [(0.0, A3, pad)], 2.5, "A3 struck: A4 at its 2x", k2x=0.02)
    phrase = [(0.0, D3, pad), (0.6, A3, tip), (1.2, D4, tip), (1.8, A4, tip), (2.4, D3, pad)]
    run("6_phrase", phrase, 4.5, "D3 A3 D4 A4 D3", k2x=0.02)
    run("7_phrase_velocity_out", phrase, 4.5, "6 with output ~ velocity (as tuning_options): higher notes louder",
        k2x=0.02, out_omega=2 * math.pi * et[D3])

    gap = np.zeros(int(0.6 * 48000))
    tour = []
    peak = max(np.abs(y).max() for _, y in clips)
    for name, y in clips:
        y = y * 0.9 / peak
        write_wav(OUT / f"{name}.wav", y, 48000)
        tour += [y, gap]
    write_wav(OUT / "tour.wav", np.concatenate(tour), 48000)
    print(f"\nwrote {len(clips)} clips and tour.wav to {OUT} (one gain for all)")


if __name__ == "__main__":
    main()
