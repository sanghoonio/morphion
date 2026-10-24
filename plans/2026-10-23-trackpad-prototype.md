---
date: 2026-10-23
status: complete
model: Claude Opus 5.5
description: Port the one-field modal model to a real-time C++ engine and play it from the Mac trackpad
---

# Trackpad prototype

## Goal

Play the handpan model live from the Mac trackpad, so strike position, contact size and force can be judged by feel. Same model as `scripts/one_field.py` (coupling 0.008), no coupling between fields.

## Pieces

- `engine/` (C++20, no platform code): `Field` (6 modes, exact damped-oscillator step, quadratic fund→octave→twelfth coupling, Gaussian contact pulse, contact damping while a finger rests), `Engine` (N fields, lock-free SPSC event queue from the touch thread, `process(float*, frames)` for the audio callback, soft limiter). Also a `render_test` CLI that renders a strike to WAV, to compare against the Python renders without the app.
- `mac/` (Objective-C++, Makefile):
  - Touch input from the private `MultitouchSupport.framework`, loaded with `dlopen` (private frameworks have no link stubs in the SDK). Gives per-finger position, contact size (ellipse axes, `size`) at the trackpad's frame rate.
  - Audio via a Core Audio default-output AudioUnit; the render callback only calls `Engine::process`.
  - A window that shows the layout and live touches. While playing, the cursor is frozen and hidden over the window so taps and clicks land on it, not on other apps. Esc releases.
- Strike detection: a finger's first contact frame triggers a strike. Force comes from the contact size in the first frames (bigger and faster-growing → harder). Contact size → contact time τ and contact radius. A finger left resting damps the field (muting), as on a real pan.
- Layouts: `--layout grid` (default): 3×3, D Kurd 9, zigzag (F4 A4 G4 / D4 D3 E4 / Bb3 A3 C4), each cell its own field, position inside the cell is the strike point. `--layout single`: whole pad is one D4 field, for judging strike position.

## Decisions & ownership

| Decision | Tag | Note |
|---|---|---|
| Private MultitouchSupport for per-finger contact size | user-owned, surfaced | Discussed earlier; only source of per-finger size on Mac. Can break on a macOS update; can't ship on the App Store. |
| Objective-C++ for the Mac app, not Swift | AI-owned, defended | One toolchain (clang + Makefile), no Xcode project, no Swift/C++ interop setup. Swift stays the plan for the iPad UI. |
| Freeze and hide the cursor while playing | AI-owned, defended | Otherwise tap-to-click and physical clicks hit whatever is under the cursor. Esc releases. |
| System gestures (3/4-finger swipes, edge swipes) not blocked | silently implied → surfaced | An app can't suppress them via this API. Disable in System Settings → Trackpad while playing, or avoid 3+ finger contacts. |
| Grid as default layout, single-field as option | AI-owned, default | Grid is more fun to test; single gives a big field for position. Easy to flip. |
| Force estimated from early contact size | AI-owned, default | No per-finger pressure exists; Force Touch pressure is one global value. Needs tuning by feel. |
| Resting finger mutes | AI-owned, defended | Physically right (the contact dashpot). Can surprise on a trackpad where fingers linger; damping strength is a flag. |
| Fields independent (no cross-field coupling) | user-owned, taken earlier | User deferred cross-note resonance. |
| MTTouch struct layout from community reverse engineering | open / vague | 96-byte layout used by OpenMultitouchSupport etc. Unverified on this macOS; `--probe` prints raw values to check. |

## What this changes elsewhere

- The Python script stays the reference: the engine must reproduce its renders (render_test vs one_field.py), so model changes go in both until the Python one is retired.
- Running the app moves nothing outside it, but the cursor freeze affects the whole session until Esc or quit.
- No App Store path for the Mac version while it uses MultitouchSupport.

## Implementation log

- Coupling: `kappa_oct`/`kappa_12` 0.04 → 0.008, octave output weight 0.7 → 0.5, twelfth 0.5 → 0.35, octave T60 factor 1.3–0.8 → 1.0–0.8. Octave now stays below the fundamental in all demo strikes and blooms ~+7 dB over 400 ms; soft and fingertip strikes land near the Shaktipan reference (`reference/recordings/fs493864_shaktipan_csharp.wav`).
- `engine/`: `morphion.h/.cpp` (Field, Engine, SPSC queue), `render_test.cpp`, Makefile. `render_test` vs `one_field.py` on the same strike: correlation 0.99997 over 0–0.8 s, 0.9991 after (Python switches to a linear tail at 0.8 s; the engine stays nonlinear).
- Offline event-path test: strike then lift after 10 ms decays to −23 dB at 1 s; strike with finger held decays to −48 dB (muting works).
- `mac/`: `main.mm`, Makefile; builds warning-free. MultitouchSupport symbols resolve via dlopen on macOS 15 (Darwin 24.6). Not yet run on the trackpad: struct layout, size/major-axis calibration and latency are unverified.
