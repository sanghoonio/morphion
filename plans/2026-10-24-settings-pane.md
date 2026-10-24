---
date: 2026-10-24
status: complete
model: Claude Opus 5.5
description: Gear button next to Play opens an in-canvas settings pane for scale, key, layout and general sound/touch settings
---

# Settings pane

## Goal

A gear button next to Play opens a settings pane: choose the scale and key, and adjust the general settings that are now only command-line flags. Drawn in the app's own style (outlines, flat colours), not with macOS controls.

## Design

**Entry.** A round gear button to the right of Play on the strip, same outline style, amber on hover. Clicking it opens the pane over the canvas. A close button or Esc returns to the strip. Not available while playing (the strip is hidden then).

**Pane.** A rounded-rectangle panel in the canvas, flat dark fill, light outline. Rows of custom-drawn controls:
- **Scale:** a row of choices, each a ding plus 8 notes, laid out on the grid with the same zigzag as now (lowest outer note bottom middle, then alternating left/right upwards, highest top middle). In D:
  - Kurd (now): D3 | A3 Bb3 C4 D4 E4 F4 G4 A4
  - Celtic Minor (Amara): D3 | A3 C4 D4 E4 F4 G4 A4 C5
  - Hijaz: D3 | A3 Bb3 C#4 D4 E4 F4 G4 A4
  - Pygmy: D3 | A3 C4 D4 E4 F4 A4 C5 D5 (built from the usual definition, minor pentatonic-like; no D chart from a maker found)
  - Integral: D3 | A3 Bb3 C4 D4 E4 F4 A4 C5 (Kurd without the G; same caveat)
  - Chinese pentatonic (gong mode, major pentatonic): D3 | A3 B3 D4 E4 F#4 A4 B4 D5 (built from the mode; makers sell plain pentatonic pans but none labelled Chinese was found)
- **Key:** the ding's pitch, A2 up to G#3 (D3 now). The whole scale moves with it.
- **Layout:** grid or single note.
- **Volume:** slider (gain).
- **Touch:** sensitivity (`--size-hard`) and resting-finger mute (`--mute`), sliders.
- **Sound:** sympathetic swell (`coupling`), balance (`tilt`), Gu cavity amount (`--gu`), sliders. A global "Reset to defaults" button restores every setting to the current defaults.

Choice rows are pill outlines with the selected one filled amber. Sliders are a line with a round knob, dragged with the mouse (the cursor isn't captured while the pane is open).

**Applying.**
- **Live, no glitch:** volume, mute, swell and balance set atomics or engine fields from the UI thread. These are already read once per audio block.
- **Restart the audio unit:** scale, key, layout and cavity change the fields, links and pre-tuning. That needs `Engine::configure`, which allocates. So stop the audio unit, reconfigure, and restart it. Ringing notes are cut, with a brief silence, which is fine for a settings change.
- **Touch sensitivity:** read by the touch thread. It becomes an atomic.

**Persistence.** Settings are saved with `NSUserDefaults` on change and loaded at launch. Command-line flags still override for that run.

**Generalising the layout.** `kGridNames`/`kGridFreqs` become a current-layout table built from (scale, key), shared by touch mapping, drawing and the engine. The title, note names and the probe output read from it.

## Decisions & ownership

| Decision | Tag | Note |
|---|---|---|
| Custom-drawn pane, not native macOS controls | AI-owned, defended | The user rejected a macOS-styled button because nothing else in the app is native. |
| Scales: Kurd, Celtic Minor, Hijaz, Pygmy, Integral, Chinese pentatonic (gong) | user-owned, surfaced | User picked all offered and asked about Chinese scales. Pygmy, Integral and gong note lists are constructed from definitions, not maker charts. |
| Settings: volume, layout, touch, sound, persistence, global reset | user-owned, surfaced | User picked all and asked for a reset-to-defaults button. |
| Changing scale/key/layout/cavity restarts audio (ringing notes cut) | silently implied → surfaced | `configure` allocates and can't run on the audio thread. A glitch-free swap would need a second engine and a crossfade. Not worth it for settings. |
| Settings persist across launches (NSUserDefaults) | AI-owned, default | Otherwise every launch resets to D Kurd. Flags still override. |
| Zigzag grid order for every scale | AI-owned, default | Same rule as the current D Kurd layout, so the feel carries over. |
| Pane only reachable while not playing | AI-owned, defended | The cursor is captured while playing; the pane needs the mouse. |

## What this changes elsewhere

- **The layout tables stop being constants.** Touch mapping (touch thread), drawing (main thread) and engine setup all read them. A scale change while the touch thread is active needs care. The touch thread only sends field indices, and the audio unit is stopped during reconfigure, so swapping the table under a stopped engine is safe. The touch thread reading names for `--probe` output could see a torn table; a mutex or a pointer swap covers that.
- **Cross-field links change per scale.** `findLinks` already detects harmonic pairs from whatever frequencies it's given, so new scales get their own sympathetic pairs (and retuning) automatically. Some scales will have no pairs, which means no swell at all, so the swell sounds different between scales.
- **The Gu pre-tuning runs per configure** (already does).
- **Persisted settings can surprise.** If you set swell to 0 and forget, the app launches with no swell. The pane shows the values, and "Reset to defaults" restores them.
- **Engine gets atomics** for gain, rest strength and mute floor (now plain floats set before start).

## Implementation log

- **Engine:** `gain`, `restStrength` and `restFloor` are now atomics, so the pane can change them while audio runs. Parity unchanged (0.99996–0.99998).
- **App (`mac/main.mm`):**
  - `Settings` (persisted via `NSUserDefaults`, loaded before flags so flags override) replaces those fields in `Config`.
  - `kScales` / `kKeys` / `buildLayout()` replace the fixed D Kurd tables. The grid uses the same zigzag; the single layout plays the note an octave above the ding.
  - The touch thread reads `g_single` and `g_sizeHard` atomics, plus layout names under `g_layoutMutex` for `--probe`.
  - `applyLiveSettings()` handles volume, mute, swell, balance and hit strength. `reconfigure()` stops the audio unit, rebuilds the layout and engine (links and cavity pre-tuning included), and restarts it. It runs for scale, key, layout, cavity and reset.
- **UI:**
  - A round gear button next to Play on the strip (SF Symbol `gearshape`, drawn in the strip's ink colour), amber on hover.
  - The pane is drawn in the canvas: choice pills for scale (wrapping), key (one row) and layout; six sliders in two columns with value and hint; "Reset to defaults" and "Done".
  - Esc or a click outside closes it. Settings save on every change.
  - The window's minimum content size is 760 × 560 so the pane fits.
- **`--snapshot`** now also writes `settings.png`. The layout was checked at the default size; interaction (clicks, drags, audio restart) wasn't run here.
