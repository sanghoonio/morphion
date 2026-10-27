---
date: 2026-10-25
status: complete
model: Claude Opus 5.5
description: A line-based text format for morphion pieces and recordings, bit-identical replay at a fixed 48 kHz engine rate; parser and CLI render first, app record/playback second
---

# Music box format

## Goal

A plain text file that holds a piece: the settings it was played with, then every strike, slide, lift and slap with its time. One file serves three uses:

1. **Recordings.** The app records what you play; playing the file back reproduces it bit for bit, sound and visuals.
2. **Hand- and machine-written pieces.** A person, a script or an AI writes a file in a short form (note name, time, force) and the engine plays it.
3. **Renders.** `render_test --play piece.txt out.wav` turns any file into audio without the app; later, `--frames` turns one into a video.

## Design

### Extension: `.txt`

Files are `.txt`, identified by a first line `# morphion 0.3`: the release that wrote the file. A `.txt` opens in any editor, mails and uploads without warnings, and is obviously harmless. The app accepts any `.txt` through Open or drag-and-drop and refuses one without the header line, with a message saying so. Name files by piece, e.g. `kurd-c#-seven-small-waves.txt`. A custom extension can be added later without changing the content.

### The version is the release version

The header line carries the app's release version (`CFBundleShortVersionString` in `mac/Info.plist`), which both Makefiles read and compile in, so render_test stamps the same version as the app it ships with. The format ships in 0.3, so the first files say `# morphion 0.3`. Hand-written files put whatever release they target.

The version is information, not a gate: any release plays any file it can read, older or newer than itself. Compatibility is decided by the content, not the number:

- **Format changes are additive only.** A later release may add header keys, line forms or options; it never changes what an existing line means or what a missing key defaults to. So a newer app reads every older file with no version branching, and an older app reads a newer file correctly as long as the file uses nothing it doesn't know.
- **A file using something the app doesn't know is refused, not half-played.** Unknown keys, line forms and note names are errors naming the line; when the file is from a newer release the error says so ("line 14: `bend` is not known to morphion 0.3; the file was made with 0.4").
- **Compatible is not bit-identical.** A file replays bit for bit only on the release that recorded it. On another release it plays with that release's engine: the same performance, possibly a slightly different sound if the tuning changed in between.

### The engine always runs at 48 kHz

Bit-identical replay needs the same sample rate on record and on playback, and the rate must not depend on the Mac's output device (44.1 kHz on some interfaces, 48 kHz on most). So the engine runs at a fixed 48000 Hz everywhere: in the app, live and in playback, and in render_test. The app hands the default output unit a 48 kHz stream and lets its built-in converter resample to the device's rate when they differ. Files carry no rate field; 48000 is part of the format.

### The engine must not depend on the host's buffer size

`Engine::process` does some work once per call: it applies queued events at the start of the call, steps resting-finger mute weights by `frames`, and reads gain, tilt, coupling and stereo width once. Its output therefore depends on how the host chunks the audio: the device buffer (128 requested, but the device may give 256, 512 or change after a device switch). A recording made at 128 replayed in 64-frame chunks would differ.

Fix: the engine processes in **fixed 32-sample sub-blocks** internally, whatever `frames` the host asks for, and applies queued events only at a sub-block boundary. Live, an event lands at the first sub-block boundary after it is queued; the recorder stamps that boundary's sample index. On playback, the player pushes each event just before the sub-block starting at its sample. The engine's state then depends only on the events and their sample indices. A host buffer that isn't a multiple of 32 takes part of a sub-block; the rest is handed out on the next call. Sub-blocks are rendered when first needed, so this adds no latency.

### What is recorded

Engine-level events, after the app's touch mapping: everything the engine needs to reproduce the sound, none of the trackpad hardware. Force and contact time are recorded as computed, so the hit-strength setting, the force curve and the slap-loudness setting (which scales the slap's force before it reaches the engine) don't appear in the file.

Header: every setting the engine reads, including the command-line-only ones, so a recording made with `--gu-hz 73` replays with 73.

```
# morphion 0.3
scale = Kurd            # Kurd, Celtic Minor, Hijaz, Pygmy, Integral, Chinese Pentatonic
key = C#                # the ding's pitch class (A2..G#3)
gain = 1.0
sustain = 1.0
swell = 1.0             # coupling
tilt = -0.1
gu = 0.2
gu_hz = 80
gap = 2.4
gap_2x = 0.45
mute = 0.6              # resting-finger damping
mute_floor = 0.15
stereo = 0.5
attack = 1.0
```

Missing keys take the app's defaults. Unknown keys are an error naming the line (catches typos like `sustian`).

### Events

One per line: a time in seconds, then what happened. `#` starts a comment anywhere. Lines may come in any order; the player sorts them by time, stably, so same-time lines keep their file order.

Times are written with 6 decimals (about 0.05 samples at 48 kHz) and rounded to the nearest sample on reading, so a written time round-trips to the same sample index. The recorder writes times of sub-block boundaries; hand-written times land on the next boundary, which is at most 0.67 ms late.

Short form, for writing by hand:

```
0.000   C#3  0.72                  # tap: lands, lifts straight away
1.500   G#3  0.45  @0.20,0.05      # tap at a spot on the note (field coords)
2.100   E4   0.50  hold 300        # finger stays 300 ms: the resting finger mutes it
3.000   slap 0.6
4.000   set stereo 0.8             # a live setting changes mid-piece
```

- Notes are named (`C#4`, `Db4`, `Cs4` all accepted); the header's scale and key map each name to its one grid field. A name not in the scale is an error naming the line.
- Defaults: spot `@0.15,0.10`, contact radius 0.12, contact time from force as the app maps it (1.6 ms soft to 0.9 ms hard).
- `set` takes only the settings the engine reads live: gain, swell, tilt, mute, mute_floor, stereo, attack. Scale, key, sustain, the Gu and the gaps rebuild the engine and stay in the header.

Full form, which the recorder writes:

```
5.000000 down 3 C#4 0.61 @0.18,0.07 r0.12 c1.25   # finger 3, force, spot, radius, contact ms
5.011333 move 3 @0.19,0.07 r0.13
5.052000 up 3
```

Finger ids are any integers; the player maps them to engine finger ids. Short-form taps get fresh ids. Both forms mix freely in one file.

### Code layout

- `engine/score.h/.cpp`: parse a file to a header (settings) and a sorted list of events with sample indices; write events back out. No Cocoa, shared by render_test and the app. Errors carry the line number.
- `engine/score.cpp` also holds the player loop: configure an `Engine` from the header, then run sub-blocks, pushing each event at its sample. render_test and the app's playback both use it.
- `render_test --play piece.txt out.wav [CHUNK]`: stereo, app levels, limiter on, run until a second after the output falls below -90 dB. CHUNK imitates a host buffer size; the output is the same for any. `render_test --rewrite piece.txt` prints a file back in full form.
- The two Kurd pieces are converted to `.txt` files in `scores/`. `kurd_pattern.py`, `kurd_pattern_codex.py` and `render_test --pattern` are then dropped; scripts that generate pieces write score files instead.

### Phase 2: the app

- **Record.** R while playing live starts a take; R again or Esc (anything that ends live playing) stops it and opens a save dialog. The record control sits in the middle of the title bar, with Exit at the right, each labeled with its key, since the cursor is captured while playing. Every live event reaches the engine through the audio callback, which moves an input queue into the engine at each engine block and, while recording, logs each event with that block's first sample to a lock-free queue the main thread drains. A take starts from a freshly configured engine (ringing notes are cut) and is shifted to start at its first event. Settings can't change during a take (the settings pane only opens when stopped), so recordings carry their settings in the header and have no `set` lines.
- **Playback.** The folder button next to Play, Cmd-O or a file dropped on the window opens a `.txt`. The app configures the engine from the file's header, counts in 3, 2, 1 in large amber digits over the pan (the audio callback outputs silence and leaves the engine untouched meanwhile), plays it through the live engine (the player pushes each event from the audio callback, so timing is exact), and draws it: note flashes from `down` lines, roundness and ripples from engine levels as live, touch dots from the spots and radii mapped back to trackpad positions (the inverse of `localIn`), slap flashes. The trackpad is ignored. The title bar becomes a player: Exit (esc) at the right, the file's name, elapsed and total time in the middle, a progress line under it. In full screen the toolbar is hidden and the player gets a 68 pt strip, drawn 1.3x larger with a wider right margin. When the last event has rung out (a second after it and every note below -70 dB), or on stop, the user's own pan and settings come back; nothing is saved.

## Decisions & ownership

| Decision | Tag | Notes |
|---|---|---|
| Line-based text format | user-owned, surfaced | Chosen by the user. |
| `.txt` with a `# morphion <version>` header line, no custom extension | user-owned, surfaced | User leaned this way (custom extensions look suspicious), not closed on it. |
| Bit-identical at the recorded rate; rate cannot be changed | user-owned, surfaced | Chosen by the user. |
| Engine fixed at 48 kHz in the app, resampled to the device by CoreAudio | AI-owned, defended | Follows from the line above: the only way a recording replays bit-identically on any Mac. |
| Engine processes in fixed 32-sample sub-blocks, events at sub-block boundaries | silently implied → now named | Bit-identity is impossible otherwise: per-call state depends on host buffer size. Changes live behavior slightly (see below). Approved by the user. |
| Record engine events, not raw trackpad frames | AI-owned, defended | Small, readable, editable, independent of hardware and input settings. A recording cannot be re-interpreted with different hit-strength settings afterwards. |
| No bit-identity across engine changes | user-owned, surfaced | A recording replays bit-identically on the same engine build; after a tuning change it plays with the new sound. Approved by the user. |
| Parser and CLI first, app second | user-owned, surfaced | Chosen by the user. |
| Note names in files, mapped through scale and key | AI-owned, defended | Readable; transposing is a key change plus renaming. |
| Header version is the release version, not a separate format number | user-owned, surfaced | Chosen by the user. Every release stamps a new version even when the format didn't change. |
| Any release plays any file it can read; the version is not a gate | user-owned, surfaced | User: a different version should play if compatible. |
| Format changes are additive only (never redefine existing syntax or defaults) | AI-owned, defended | The only way an older app can tell a compatible newer file from an incompatible one: anything new is unknown and refused, anything known means the same. Constrains every future format change. |
| Unknown header keys are errors | AI-owned, default | Strict catches typos; loose would let newer files open in older apps. |
| `scores/` as a new top-level dir | user-owned, surfaced | Approved by the user. |
| Drop `--pattern` and the Python piece scripts once converted | AI-owned, default | They duplicate the player. |
| Where recordings are saved | user-owned, surfaced | Save dialog when a take ends; Cancel discards it. Default name `<scale>-<key>-<date>-<time>.txt`. |
| Playback uses the file's settings and pan, then restores the user's without saving | user-owned, surfaced | Confirmed by the user: that is what "plays exactly as recorded" means. |
| Record control in the middle of the title bar and Exit at the right while playing; folder button right of Play; a player overlay replaces "Esc to stop" | user-owned, surfaced | User's layout. Live playing hides the cursor, so Exit and Record show their keys (esc, r) in key badges; the links have no icons. |
| A take starts from a freshly configured engine, cutting ringing notes | AI-owned, defended | Otherwise the take's start depends on whatever was ringing and on the noise generators' state, and it can't replay bit for bit. Costs a brief audio restart when R is pressed. |
| A take starts at its first event (leading silence dropped) | AI-owned, defended | Tested: an idle engine renders identically shifted by whole blocks, so the trim changes no sample. |
| Recordings have no `set` lines | AI-owned, defended | Settings can't change while live playing; if a live control is added later, it must go through the input queue to be recorded at its block. |
| Quitting mid-take stops it and opens the save dialog instead of quitting | AI-owned, default | Avoids losing a take to Cmd-Q; quit again afterwards. |
| The single-note layout is gone, from the app and the format (no `layout` header key) | user-owned, surfaced | User saw no point in it. Removed before 0.3 shipped, so the additive-only rule isn't broken; `scores/test.txt` (a 0.2.2-stamped recording) had its `layout = grid` line removed. |
| An info button left of Play opens an About panel for the whole app (an introduction, playing and settings on one tab, recording and scores on another); Copy guide for AI copies the score guide bundled in the app (`Resources/score-guide.md`, copied from `scores/AGENTS.md` at build time) | user-owned, surfaced | User chose the place. The copied guide always matches the app's format. It includes the repository's `render_test` commands, which an AI model in a chat can't run. |
| Score playback works with no trackpad connected (Cmd-O or drop) | AI-owned, default | The pan is drawn in place of the "No trackpad found" message while a file plays. |

## What this changes elsewhere

- **Live latency and CPU.** 48 kHz fixed: on a 44.1 kHz device CoreAudio resamples, adding a little CPU and well under 1 ms. On 48 kHz devices (most Macs' built-in output) nothing changes. Sub-blocks: events land at a 32-sample boundary instead of the host buffer's start; at 128 frames that is the same or earlier, never later.
- **Engine sound under different buffer sizes.** Today the output differs slightly between 128- and 512-frame buffers (rest-mute steps, setting reads). After the change it doesn't. Rest-mute ramps step every 0.67 ms instead of every host buffer: smoother, not audibly different.
- **Parity checks.** `multi_field.py --check` compares the engine with the Python model. Sub-blocks only change when events and per-block reads happen, and `--kurd` pushes its strike before the first block, so the check should still pass. Run it to confirm.
- **render_test modes** (`--kurd`, `--slap`, `--attack`, `--stereo`) keep working: `process` still takes any `frames`. Their output may shift by up to a sub-block where events fell mid-call; the A/B renders in `scripts/renders/` were made before and are not regenerated.
- **App sample rate handling.** `g_sr` stops following the device; the device-change notification no longer reconfigures for a new rate. Log lines that print the device rate stay.
- **Event path.** The touch thread and the Space key no longer push to the engine directly; they push to an input queue the audio callback drains at each engine block. Event timing is unchanged (both apply at the next block). The Space key now takes the touch mutex, so the input queue keeps one producer at a time.
- **Settings persistence.** Playback applies the file's settings temporarily and must not save them to NSUserDefaults.
- **Build.** `engine/Makefile` reads the version from `mac/Info.plist` (as `mac/Makefile` already does for the release zip) and passes it as a define; bumping a release is still one edit to Info.plist.
- **README.** A section on the format, once phase 1 lands.

## Implementation log

### Phase 1 (2026-10-25)

- **Engine** (`engine/morphion.h/.cpp`): `process` hands out samples from fixed 32-sample blocks rendered by `renderBlock`; queued events are applied at a block start. `nextBlockSample()` exposes the next block's sample index for the recorder. `configure` now also resets the two noise seeds, drains the event queue and resets the block counter, so the same events always render the same samples. `multi_field.py --check` still passes (Kurd ding correlation 0.99999 / 0.99998).
- **Score module** (`engine/score.h/.cpp`): scale/key tables and `layout()` (moved from `mac/main.mm`; the app now uses them), `parse`, `write`, `configure`, `applySetting` and `Player`. Details settled in the code:
  - `#` starts a comment at the start of a line or after a space, so `C#4` is a note.
  - Note names accept `#`, `s` and `b` (`C#4`, `Cs4`, `Db4`; `B#2` is C3). The writer spells from the key's minor signature (sharps for A, B, C#, E, F#; flats otherwise), so C# Kurd is written G#3, D#4. The app's labels keep their old spellings (Ab, Eb).
  - A `set` takes effect at the start of its block, before that block's events.
  - Short-form taps get internal finger ids from 2^30; the writer renumbers all fingers from 1 (smallest id not held down).
  - The writer formats floats with `std::to_chars` (shortest exact), so write then read gives back the same floats.
  - When a file from a newer release fails to parse, the error says which release made it.
  - A note not on the pan is reported with the pan's notes: `'D4' is not a note of this pan (E Hijaz: E3 B3 C4 D#4 E4 F#4 G4 A4 B4)`.
- **Guide**: `scores/AGENTS.md` (with a root `AGENTS.md` pointing to it) teaches people and agents to write scores. Codex wrote `scores/hijaz-e-amber-courtyard.txt` from it alone; its feedback is in `plans/2026-10-25-codex-score-guide-feedback.md` and has been applied.
- **render_test**: `--pattern` replaced by `--play in.txt out.wav [CHUNK]`, `--rewrite in.txt` and `--check in.txt` (two-hand playability: 3 strokes within 20 ms, 4 in 250 ms, 10 in 1 s; same-note strokes under 60 ms apart are one gesture, rolls up to 0.4 s; exit 1 if exceeded). The render length is cut at an exact sample (a second after the output falls below -90 dB), so it doesn't depend on CHUNK.
- **Build**: both Makefiles read the version from `mac/Info.plist` and pass `-DMORPHION_VERSION`. It is still 0.2.2, so errors on the 0.3 score files currently add "(made with morphion 0.3, this is 0.2.2)" until the release bump.
- **Scores**: `scores/kurd-c#-groove.txt` and `scores/kurd-c#-seven-small-waves.txt`, converted from the two Python scripts (same humanized hits, short form), which are deleted. Renders in `scripts/renders/scores/`.
- **Checks**: both scores render byte-identically with CHUNK 1, 37, 128 and 512; `--rewrite` output replays byte-identically to the original and rewrites to itself; parser errors checked on bad headers, typos, notes outside the pan, header after events, non-live `set`, bad options, newer-release files. The app builds and its snapshot shows the same layout and labels.
- **Not done (phase 2)**: the app still runs the engine at the device's rate; fixing it at 48 kHz belongs with recording and playback.

### Phase 2 (2026-10-26)

- **48 kHz**: the app hands the default output unit a 48 kHz stream and the engine is configured through `score::configure` from the user's settings as a score header (`scoreSettings`), so live, recorded and replayed audio share one setup.
- **Record and playback** as described under Phase 2 above, in `mac/main.mm`: `feedInput` and `renderCallback` (audio thread), `drainTake`, `startRecording`, `finishTake`, `saveTake`, `playScore`, `tickPlayback`, `stopScore` (main thread), `drawPlayer` for the title-bar player.
- **Check**: `mac/build/morphion --check-recording` sends random touches and slaps through the real callback and recorder in host buffers of 1-700 frames, writes the take as a score, parses it, replays it with `score::Player` and compares: 748 events, 946,612 frames, identical. Snapshots (`--snapshot`) now include `recording.png` and `score.png`.
- **Not checked here**: anything needing the trackpad, the speakers or the dialogs: recording a real take, the save and open dialogs, dropping a file, playback visuals in motion, and playing through a 44.1 kHz interface.
