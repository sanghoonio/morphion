# morphion

A handpan you play on a Mac trackpad. The sound comes from a physical model of the steel, and each finger's contact sets where, how hard and how long the note is struck.

## Install

Download `morphion-<version>-macos.zip` from [Releases](https://github.com/sanghoonio/morphion/releases), unzip it and move `morphion.app` to Applications. It needs an Apple silicon Mac with macOS 13 or later and has been tested on macOS 15.

## Build from source

Needs the Xcode command line tools (`clang++`, `make`), and [uv](https://docs.astral.sh/uv/) for the Python scripts (optional).

```
make -C mac
open mac/build/morphion.app
```

`mac/build/morphion` links to the app's executable, for running it with command-line flags (`--probe` prints raw touch data; see the top of `mac/main.mm` for the rest). `make -C mac release` signs the bundle ad hoc and zips it to `mac/build/morphion-<version>-macos.zip` for a release.

## Playing

- **Play** (or Return) starts playing. The cursor is frozen and hidden so taps land on the pan. **Esc** stops.
- Where you strike inside a note changes its tone. Harder hits are louder and brighter.
- A finger left resting on a note mutes it, as on a real pan. Quick taps don't.
- **Space** slaps the shell: a low thump from the cavity and a short knock.
- The **gear** next to Play opens settings:
  - scale: Kurd, Celtic Minor, Hijaz, Pygmy, Integral, Chinese Pentatonic
  - key
  - layout: 3×3 grid or a single note
  - volume and sustain
  - hit strength and resting mute
  - sympathetic swell and low/high balance
  - Gu cavity
  - stereo width
  - strike click and slap loudness

  Settings are saved between launches.

## The sound model

- Each note is a set of resonant modes tuned like a handpan note: fundamental, octave and twelfth, plus a few upper modes. Energy flows from the fundamental into the octave over the first few hundred milliseconds (the bloom).
- Notes that sit on another note's 2nd or 3rd harmonic are coupled to it and tuned slightly below that harmonic, so they swell in sympathy a beat after the lower note is struck.
- The Gu, the hole in the bottom shell, is modelled as an air resonance under the ding. The notes are pre-tuned so they land on pitch with it coupled in.
- A strike is a short force pulse whose length depends on how hard you hit. While the finger touches, it damps the note.
- Notes are placed left to right by their column on the grid, the ding in the middle. Notes swelling in sympathy sound from their own side.
- The output goes through a lookahead peak limiter that turns the level down rather than distorting it.

The numbers come from published handpan measurements where they exist (see `docs/handpan-acoustics.md`).

## Layout

- `engine/`: the C++ real-time engine (`morphion.h/.cpp`) and `render_test`, which renders strikes to WAV without the app.
- `mac/`: the Mac app (Objective-C++, one file), its Makefile, Info.plist and icon.
- `scripts/`: Python reference models (`one_field.py`, `multi_field.py`) and the A/B render scripts used to tune the sound. Run them with `uv run scripts/<name>.py`. `uv run scripts/multi_field.py --check` compares the engine against the Python model.
- `docs/`: research notes on handpan acoustics.
- `plans/`: design plans and implementation logs.

## License

MIT. Inspired by [Orphion](https://www.orphion.de/).
