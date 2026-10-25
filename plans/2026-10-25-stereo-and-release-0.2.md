---
date: 2026-10-25
status: in-progress
model: Claude Opus 5.5
description: For 0.2, stereo placement of the notes, Strike click and Slap sliders, and tests of sleep/wake, audio device changes and trackpad choice
---

# Stereo, attack/slap settings, and robustness tests for 0.2

## Goal

Three things for the 0.2 release:
1. **Stereo.** Each note sits at its own place left to right, so the pan feels like an instrument in front of you rather than one mono point.
2. **Strike click and Slap in Settings.** The strike attack level and the slap loudness, which are now fixed in code.
3. **Robustness tests.** Sleep and wake, audio device changes, and a built-in plus Magic Trackpad together. Test first; fix only what breaks.

## Design

### Stereo

**Where each note sits.** Pan follows the grid column: left column left, middle column centre, right column right. The grid's zigzag already alternates ascending notes left and right like a real pan, so columns are a fair stand-in for the notes' real positions around the ding. The ding (middle) and the single-note layout are centred.

**Width.** A new live setting, `stereoWidth` (0 = mono, 1 = side columns fully left and right). The pan of a side column is ±width.

**Pan law.** Constant power, normalised so a centred note is unchanged: θ = (p + 1)·π/4, left = √2·cos θ, right = √2·sin θ. A centred note keeps exactly today's level in both channels, so the ding and the parity checks don't move. A side note at p = ±0.5 is +2.3 dB in its near channel and −5.3 dB in the far one, with the mono sum about −0.7 dB.

**What pans.** Each field's output, and each strike's attack (click and shimmer) with its field. Sympathetic notes ring at their own position, so the swell after a ding hit comes from the sides. The Gu cavity, the slap's shell knock and noise stay centred. The slap's faint rim strikes on every field pan with their fields.

**Limiter.** Linked across channels: one gain from the louder channel's peak, applied to both, so a loud note on one side doesn't shift the image.

### Strike click and Slap sliders

- **Strike click:** the engine's existing `attackLevel` (0–2, default 1). It scales the click and shimmer on top of the force curve already tuned (light taps near nothing, hard hits up to 1.5).
- **Slap:** a level from 0 to 2, default 1. The app sends a slap force of 0.8 × level. The engine's clamp on slap force rises from 1 to 2. Every part of the slap is linear in force (cavity push, shell knock, noise, the rim strikes' force), so the level scales its loudness.
- **Stereo width** gets a slider too (0–1).

The pane goes from seven sliders to ten, five rows in its two columns. The rows tighten from 62 to 56 pt so the pane still fits the default 900 × 640 window and the current minimum size. Reset to defaults covers the new ones.

### Robustness tests (you run these; I prepare the build and the checklist)

Each test notes whether touches still sound, whether there is audio, and anything in Console or the terminal.

1. **Sleep and wake.** Play, close the lid or choose Sleep, wait 30 s, wake, play again. Also with the app sitting idle (not playing) during sleep.
2. **Audio device changes.** While playing: plug in and remove wired headphones; connect and disconnect Bluetooth headphones (they switch the sample rate); pick a different output in Control Centre.
3. **Two trackpads.** With a Magic Trackpad connected to a MacBook: which one plays? Disconnect and reconnect the Magic Trackpad while the app is open.

The app's terminal output (run `mac/build/morphion` from Terminal) shows the stream format and link setup. I'll add a line logging device start, stop and wake, so the tests leave a trace.

**Likely fixes, only if the tests show the problem:**
- **Touches stop after wake:** restart the multitouch device on the wake notification.
- **Audio stops or plays at the wrong pitch after a device change:** restart the audio unit on a default-device change.
- **The wrong trackpad plays:** list the devices (the framework has `MTDeviceCreateList`), listen on all of them, or offer a choice in Settings.

## Decisions & ownership

| Decision | Tag | Note |
|---|---|---|
| Default stereo width | user-owned, surfaced | On by default at 0.5 (side notes about 30° off centre), confirmed by the user. Changes how the app sounds for everyone who updates. |
| Pan by grid column (L/C/R), ding centred | user-owned, surfaced | Confirmed by the user over placement by pitch. The zigzag already alternates notes left and right like a real pan, and rows don't change the pan. |
| Pan law normalised to centre unity | AI-owned, defended | Keeps the ding and the parity checks exactly as they are. The cost is side notes slightly louder in their near channel. |
| Linked stereo limiter | AI-owned, defended | Independent limiting would push the image towards the quieter side on loud hits. |
| Gu, slap knock and noise centred | AI-owned, default | The cavity and the shell are under and around the whole pan. |
| Slider ranges: click 0–2, slap 0–2, width 0–1, defaults 1 / 1 / 0.5 | AI-owned, default | 0 turns the click or slap off. 2 is double the current level, past which the limiter takes over. |
| Robustness: test first, fix only what breaks | user-owned, surfaced | Your call ("4–6 we should test"). Fixes are listed as conditional. |
| Settings pane rows tightened to 56 pt | silently implied → surfaced | Ten sliders need a fifth row. Otherwise the window's minimum size would have to grow. |

## What this changes elsewhere

- **Engine output** becomes truly stereo. `process(left, right)` with right == nullptr (render_test, `--frames`) must still work: it gets the left channel or a mono mix. `render_test --kurd` (the parity path) sets width 0, so the Python checks compare like with like. The ding is centred, so even with width on its left channel equals today's mono.
- **Saved settings** gain `stereoWidth`, `attackLevel` and `slapLevel`. Missing keys fall back to defaults, so existing saved settings load fine.
- **Loudness:** at width 0.5, side notes are +2.3 dB in one channel, so loud chords on one side reach the limiter a little sooner. The sound is otherwise unchanged in level.
- **Headphones vs speakers:** on laptop speakers, about 25 cm apart, width 0.5 is subtle. On headphones it's clear. That's a reason not to go wider by default.
- **`--frames` audio** is written mono (left channel). It becomes stereo or a mix if a stereo WAV is useful there; mixed by default.
- **The docs:** the README's sound-model list gains a line on stereo. The Settings list gains the three new sliders.

## Implementation log

- **Engine:**
  - `stereoWidth` (atomic, default 0) and `setFieldPan()`.
  - Each field's output and each strike's attack are panned with constant power, normalised to centre unity. The Gu, the shell knock and the noise stay centred.
  - The limiter is linked across the channels.
  - With one output buffer, `process()` writes a mono mix, identical to either channel at width 0.
  - The slap force clamp is now 0–2.
  - Parity is unchanged (0.99996 single, 0.99999 / 0.99998 Kurd), since `render_test` runs at width 0.
- **Measured** (width 0.5, one strike):
  - A left-column note is 30.5 / 22.6 dB (L / R), a right-column note 22.1 / 30.0, the ding 28.5 / 28.6.
  - The ding's slight difference is its sympathetic D4, which sits in the left column.
- **App:**
  - Settings gain Stereo width (default 0.5), Strike click (`attackLevel`, default 1) and Slap (force 0.8 × level, default 1), saved and covered by Reset.
  - Pans are set per grid column in `configureEngine`; the single-note layout is centred.
  - The pane has five slider rows at 60 pt and is up to 540 pt tall. The window's minimum content height went from 610 to 620.
- **Listening:** `engine/build/render_test --stereo out.wav [WIDTH]` renders a phrase across the grid. Width 0, 0.5 and 1 are in `scripts/renders/stereo/`.
- **Robustness logging:** run `mac/build/morphion` from Terminal. Timestamped lines on stderr show:
  - start (number of multitouch devices, sample rate);
  - sleeping and woke;
  - the first touch frame after start and after each wake;
  - default output device changes (device, its rate, the engine's rate).
- **Tests 1–3: not run yet.** They need the user's hardware.
