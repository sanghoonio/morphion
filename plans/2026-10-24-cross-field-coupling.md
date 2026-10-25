---
date: 2026-10-24
status: in-progress
model: Claude Opus 5.5
description: Couple tone fields where one sits on another's harmonic, so a struck note makes its neighbours swell in (the bwom)
---

# Cross-field coupling

## Goal

Striking a note should make the notes tuned to its harmonics swell in and peak at about 250 ms, about −16 to −22 dB below the struck note. That's the "bwom" in the first notes of `fs493864` and `fs520472`. Reference renders: `scripts/renders/sympathetic/3c_chain_weaker_peak250.wav` (chosen level and timing) and `scripts/renders/tuning_options/c_detuned_a4.wav` (chosen tuning approach).

## What we know

- The swell is other fields ringing at the struck field's harmonics: on the Shaktipan the C#3 ding's 3x, 4x and 6x swell (G#4, C#5 and the G#4's octave). Its 2x has no field and stays flat.
- Plain linear coupling from the struck field's twelfth is too weak. What matched is the chain: the struck field's fund x octave drives the listener's fundamental, V = −k12 q1 q2 l1 (`scripts/sympathetic_test.py`).
- The peak time is set by the gap between the listener's pitch and the harmonic: about 1/(2 gap) when the gap is large, with a ceiling of about 320 ms at gap 0 from the drive decaying. 1.86 Hz gives about 250 ms. The gap also makes the swell drop away quickly after the peak (the bloom-and-drop the user picked over the lingering in-tune version).
- Option c (chosen): the listener field itself is retuned to harmonic − gap, so one field rings both when struck and in sympathy, as on a real pan.

## Pairs in the D Kurd 9 layout

Matching a field's fundamental to a lower field's 2x or 3x within ±30 cents:

| Source | Harmonic | Listener | Equal-tempered gap | Retuned listener at 1.86 Hz gap |
|---|---|---|---|---|
| D3 146.83 | 3x 440.49 | A4 440.00 | 0.49 Hz | 438.63 (−5.4 c) |
| D3 146.83 | 2x 293.66 | D4 293.66 | 0 | 293.21 at the chosen 0.45 Hz 2x gap (−2.7 c) |
| A3 220.00 | 2x 440.00 | A4 | 0 (1.37 Hz after A4 is retuned for D3) | stays at 438.63 |

No other pairs: the remaining fields don't land on a 2x or 3x of a lower field.

## Design

**Coupling terms.**
- 3x pairs: the chain from 3c, V = −k12 q1 q2 l1 on the source's fund and octave and the listener's fundamental. Back-reaction on the source included, so energy is conserved.
- 2x pairs: no reference measured yet. First try the direct analogue of the in-field octave term, V = −k2x q1² l1. Its timing will differ from the chain (a one-step drive peaks earlier), so it gets its own A/B render before going into the engine.

**Tuning.** `Engine::configure` finds pairs automatically from the field frequencies (any layout, ±30 cents) and retunes each listener to (source harmonic − gap). A listener with two sources is tuned to the lowest source; the other source gets whatever gap results (A4: 1.86 Hz from D3, 1.37 Hz from A3). One gap setting for all pairs.

**Python first.** `scripts/multi_field.py`: N fields from `one_field` plus links, strikes on any field. Checks:
- one field, no links → same output as `one_field.render`;
- the D3/A4 pair → reproduces `tuning_options.py` option c.

It renders the A/B set for the user: D3 strike in the full layout, A3 strike, and the D3→D4 2x pair at a few gaps.

**Engine port.**
- `Field` gets read access to q, plus an external-force input added in `tick()`.
- `Engine::process` computes link forces from the current q of all fields, then ticks every field. This keeps the Python order of operations (forces from the current state, then propagate).
- A sleeping listener wakes when a link drives it. A field doesn't sleep while it's driving a listener.
- `render_test` gains a two-field mode to check correlation against `multi_field.py`.

**App.**
- The grid layout uses the retuned frequencies; note names unchanged.
- Keys `[` and `]` scale all coupling strengths (0 = off), with the value shown in the window title, so the user can tune by ear.
- `--coupling X` and `--gap HZ` flags.

## Decisions & ownership

| Decision | Tag | Note |
|---|---|---|
| Option c: listener fields retuned to harmonic − gap | user-owned, surfaced | User chose c over keeping the pad in tune (b) or plain equal temperament (a). |
| D4 gap: 0.45 Hz for 2x pairs (D4 −2.7 c, swell ~−25 dB at ~430 ms) | user-owned, surfaced | At the 1.86 Hz gap D4 would be 11 c flat. The user picked 0.45 Hz from `4_ding_2x_gap0.45`. Default in `multi_field.py`, `CouplingParams` and the app. |
| In-field octave coupling raised from 0.008 to 0.025 (3c used it) | user-owned, surfaced | Raised in 3c because the chain needs the source's octave. It also strengthens every note's own octave swell, including notes with no listener. Default: raise it globally in both Python and engine, and listen. Alternative: keep 0.008 in-field and raise only the chain. |
| 2x coupling as V = −k2x q1² l1 | user-owned, surfaced | User agreed to judge by ear. Untested; no reference recording isolates a 2x swell (the Shaktipan has no field at the ding's 2x). Gets its own A/B render before the engine. |
| Chain strength 0.116 (3c's 0.058 doubled) | AI-owned, defended | 3c's listener radiated at 2.0; real fields radiate at 1.0, so the coupling is doubled to keep 3c's level. Matches 3c within 1 dB in `tuning_options.py`. |
| Output scaled per field by its own omega_1 (engine convention), not by a common one as in `tuning_options.py` | silently implied → surfaced | All renders the user chose by ear divided every field by the ding's omega_1, so A4 (3x the ding's pitch) came out 3x (9.5 dB) louder relative to the ding than it does in the engine. The swell keeps the same level relative to a struck A4, but it's about 9 dB quieter relative to the ding than what the user heard. Raising k3x can't recover it: the swell saturates near −27 dB and peaks earlier. `6_phrase` vs `7_phrase_velocity_out` A/B it. Needs the user's ear. |
| Listener with two sources tuned to the lowest one | AI-owned, default | The ding is the main source on a handpan. A4 then sits 1.37 Hz from A3's octave. |
| Pairs found automatically within ±30 cents | AI-owned, default | Works for any layout; 30 c catches the equal-tempered matches without false pairs in D Kurd. |
| Sympathetic pairs only at 2x and 3x | AI-owned, default | The pad has nothing at 4x or 6x of a lower note. Revisit with other scales. |
| One gap for all 3x pairs, a separate one for 2x | AI-owned, default | `--gap` (1.86 Hz) and `--gap-2x` (0.45 Hz). |
| Radiation tilt −0.1 (live: `-`/`=`), ref D4 | AI-owned, defended → surfaced | The user asked for a slightly stronger bloom, between `3a_chain_weak` and `3b_chain_weaker`, about +2 dB. Raising the coupling only moves the peak earlier (0.116 → 0.16: A4 −31 → −30 dB, 270 → 223 ms). At 0.3 the tilt lifted the A4 swell 2.3 dB, but high notes sounded too loud on MacBook speakers, so the user asked for less. At 0.15, D3 still sounded noticeably quieter than G4 and up on Etymotic ER2XR earphones, so the tilt is now −0.2 (D3 +1.7 dB vs G4), set by ear for perceived evenness rather than from physics. To keep the swell, k3x went 0.116 → 0.2 and the 3x gap 1.86 → 1.3 Hz: A4 swell −30 dB at 229 ms, A4 −3.2 c. `radiationTilt` in `FieldParams` / `RADIATION_TILT`; 0 restores equal struck loudness. Partly settles the open output-balance question. |
| Gu cavity: 80 Hz, coupling 0.2, ding weight 1.0, others 0.15 | user-owned, surfaced | Picked by ear from `scripts/renders/gu/3_ding_gu_shaktipan.wav`. Only the frequency range (73–85 Hz) is measured. Q, coupling and weights were set by ear. `--gu 0` turns it off. |
| Pre-tune fields and cavity for the coupling | silently implied → surfaced | The cavity pulled the ding 14 c sharp (148.04 Hz) and its 3x harmonic 4 Hz off A4, which collapsed the A4 swell (−33 dB at 123 ms) in the render the user picked. Now the nominal pitches are solved so the coupled pitches land on target (ding nominal −15.9 c, cavity 82.7 → 80 Hz), with the octave and twelfth kept at 2x and 3x the heard pitch, as a tuner would tune the assembled pan. This changes the render the user picked, so it needs a re-listen. |
| Live coupling keys in the app | AI-owned, defended | The user tunes by ear; a key is faster than re-rendering. |

## What this changes elsewhere

- **The pad isn't in equal temperament any more.** A4 and D4 are flat (5.4 c, 2.7 c). A struck A4 beats against the ringing ding at about 2 Hz. That's the price of c, and it's what you'd hear on a real pan with this tuning.
- **Every note's own octave swell gets stronger** if kappa goes to 0.025 globally. The demo renders in `scripts/renders/D4/` and the bwom renders would no longer match the current defaults, so re-render them.
- **`one_field.py` stays the single-field reference**; `multi_field.py` becomes the reference for coupling. The engine has to match both, which doubles the parity checks.
- **Muting changes meaning.** A resting finger on A4 damps A4's sympathetic swell too, which is right. A finger on the ding doesn't stop A4 once it's ringing, which is also right physically, but it may surprise when playing.
- **Loudness rises** when the ding is struck (the swell adds energy to the mix), so the tanh limiter engages more often at the current gain.
- **Sleeping:** fields that drive listeners stay awake longer, so CPU rises slightly. That's negligible at 9 fields.
- **The single-field layout is unaffected** (no pairs).

## Verification

- `multi_field.py` with one field matches `one_field.py` sample for sample. The D3/A4 pair matches `tuning_options.py` option c.
- The engine's two-field `render_test` correlates above 0.999 with `multi_field.py` over 0–0.8 s.
- The app builds warning-free. The user plays it and adjusts coupling with `[`/`]`.
- A/B renders for the user before the engine port: D3 strike (layout), A3 strike, D3→D4 2x pair at a few gaps.

## Implementation log

- **In-field coupling** is now 0.025 in `scripts/one_field.py` and `engine/morphion.h` (`FieldParams`). `scripts/renders/D4/` re-rendered: the octave peaks 9–14 dB below the fundamental at 80–190 ms for normal strikes, so it still stays under the fundamental.
- **`scripts/multi_field.py`** has N fields, harmonic-pair detection with retuning (`layout`), the 3x chain and 2x links with back-reaction, and per-field output.
  - `--check`: matches `one_field.render` (max diff 2e-15) and `tuning_options.py` option c (3e-16); engine parity is below.
  - A/B set in `scripts/renders/multi_field/`: ding uncoupled, 3x only, 2x at k2x 0.01/0.02/0.04, D4 gap 0.9 and 0.45 Hz, A3 strike, a phrase, and the phrase with velocity output.
- **k2x = 0.02.** After a ding strike D4 swells to about −20 dB at about 290 ms. Higher values make D4 drain the ding's fundamental, which weakens and speeds up the A4 swell (k2x 0.04: A4 at 216 ms, −33 dB).
- **D4 gap.** 0.9 Hz → −5.3 c, peak at about 400 ms. 0.45 Hz → −2.7 c, about 430 ms. 1.86 Hz → −11.0 c, about 290 ms.
- **Engine.**
  - `CouplingParams`, `Link` and `findLinks` handle pair detection and retuning, mirroring `layout`.
  - `Field::addForce`, `q()` and `wake()`.
  - `Engine::process` computes link forces from every field's current state, then ticks all fields.
  - `Engine::coupling` (atomic) scales all links live; `Engine::limiter` can be switched off for tests.
  - `render_test --kurd out.wav [field seconds]` renders one strike on the D Kurd grid through the Engine.
  - Correlation with `multi_field.py`: 0.99999 over 0–2.5 s for a ding strike; single field 0.99996.
- **App.**
  - `--coupling`, `--gap` and `--gap-2x` flags; `[`/`]` change coupling in steps of 0.25 (0–4), shown in the window title.
  - At startup it prints each link and the retuned pitches: A4 438.63 Hz (−5.4 c), D4 293.21 Hz (−2.7 c).
  - Builds warning-free. Not yet played on the trackpad.
- **2x gap set to 0.45 Hz** (user's pick) in `multi_field.py` (`GAP_2X_HZ`), `CouplingParams::gap2xHz` and the app's `--gap-2x` default. Parity re-checked: engine vs Python 0.99999.
- **Bloom +2 dB via radiation tilt 0.3** (Python `RADIATION_TILT`, engine `FieldParams::radiationTilt`, reference D4 so D4 is unchanged). A4 swell after a ding strike: −29 dB at 250 ms (was −31 dB at 270 ms). D4 swell barely moves (−25 dB). Parity: engine vs Python 0.99998–0.99999; `one_field` check now runs with tilt 0, which is exact.
- **Tilt lowered to 0.15** at the user's request: high notes sounded loud on MacBook speakers. A4 swell −30 dB at 257 ms.
- **Balance flipped towards low notes:** tilt −0.2, with live keys `-`/`=` (steps of 0.05) and `--tilt`, shown in the title. Compensation: `K3X`/`k3x` 0.2 and `GAP_HZ`/`gapHz`/app `--gap` 1.3 Hz. Results after a ding strike: A4 swell −30 dB at 229 ms, D4 −24 dB at 419 ms. A3 strike → A4 −23 dB at 364 ms (was −19 dB at 314 ms; A4 now sits 0.8 Hz from A3's octave). Parity unchanged (0.99998–0.99999).
- **Tilt halved to −0.1** (user: −0.2 made D3 too strong). D3 +0.9 dB vs G4. A4 swell −29 dB at 229 ms; A3 → A4 −22 dB at 369 ms.
- **Gu cavity** (`multi_field.Gu`, `default_gu`, `gu_detune`; engine `GuParams`, `guDetune`; app `--gu`, `--gu-hz`). One resonator, linearly coupled both ways to every fundamental, stepped in the same order as the fields. Pre-tuning solves the coupled system's frequencies (arrowhead secular equation, bisection plus fixed-point) so the ding sounds at 146.85 Hz and the cavity at 80.2 Hz. After a ding strike: A4 swell −30 dB at 250 ms, D4 −23 dB at 426 ms (no Gu: −29 dB at 229 ms, −24 dB at 419 ms). Parity: engine vs Python 0.99997–0.99998 with the Gu on; without it in Python the correlation drops to 0.32, so the engine's Gu is really there. `scripts/gu_test.py` re-rendered with pre-tuning. The single-field layout also gets the cavity (its one field counts as the ding).
- **In-note bloom left at 0.025 / octave 0.5.** The user tried 0.032 / 0.6 (D4 fingertip octave −9.0 dB instead of −11.8 dB) and reverted it.
- **Links made one-way (no push-back on the source).** With the energy-conserving push-back, a ringing upper note pumped the lower note parametrically: after a soft ding strike, 8 A4 hits raised the ding from −96 dB (its own tail) to −28 dB, louder than A4. The user heard this as the ding resonating too strongly. One-way, the same test leaves the ding at −74 dB. `multi_field.render(reaction=True)` keeps the old form for the `tuning_options` parity check. Without push-back the A4 swell peaked later (321 ms), so it was retuned: 3x gap 1.3 → 2.4 Hz (A4 −7.5 c), `k3x` 0.2 → 0.16. After a ding strike: A4 −28 dB at ~257 ms, D4 −26 dB at ~447 ms (2x unchanged). An A3 strike now swells A4 to −18 dB (was −22 dB).
