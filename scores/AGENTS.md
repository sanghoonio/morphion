# Writing morphion scores

How to write a piece for morphion, a physics-modeled handpan. A score is a plain text file. The engine plays it note for note, and the same file always renders the same audio.

## The file

```
# morphion 0.3
# a comment describing the piece

scale = Kurd
key = D

0.000   D3   0.70                  # a tap: time, note, force
0.500   A3   0.40  @0.30,0.05      # struck at a spot on the note
1.000   F4   0.45  hold 250        # finger left on the note for 250 ms
1.500   slap 0.60
2.000   set stereo 0.8             # a live setting changes
```

- **Line 1** must be `# morphion <version>`, the release the file is written for. Use `0.3`.
- **Header**: `key = value` lines, before the first event. Usually only `scale` and `key`; everything else has sensible defaults.
- **Events**: one per line, `TIME WHAT ...`. Time is in seconds from the start. Lines may be in any order. Lines with the same time play together, in file order.
- **Comments**: `#` at the start of a line or after a space. A `#` inside a note name (`C#4`) is part of the note.

## Header settings

| key | default | meaning |
|---|---|---|
| `scale` | `Kurd` | `Kurd`, `Celtic Minor`, `Hijaz`, `Pygmy`, `Integral`, `Chinese Pentatonic` |
| `key` | `D` | the ding's pitch class: `A Bb B C C# D Eb E F F# G Ab` (sharps or flats both accepted) |
| `sustain` | 1.0 | multiplies every ring time |
| `swell` | 1.0 | strength of the sympathetic swell between notes |
| `stereo` | 0.5 | stereo width, 0 = mono |
| `gu` | 0.2 | the air cavity under the ding (the low "bwom"), 0 = off |
| `attack` | 1.0 | strike click and shimmer, 0 = off |
| `gain` | 1.0 | output level |
| `tilt` | -0.1 | low/high balance, negative favors low notes |
| `mute` | 0.6 | how strongly a finger left on a note damps it |
| `reverb` | `dry` | the space around the pan: `dry`, `small`, `medium`, `hall`, `stairwell` (longer and longer echoes) |

Leave the rest (`gu_hz`, `gap`, `gap_2x`, `mute_floor`) alone. Unknown keys are errors.

## The notes

The pan has a **ding** (the lowest note, in the middle) and **8 notes** above it. The ding's pitch is set by `key`, from A2 up to G#3 (`key = C` gives C3, `key = A` gives A2). The 8 notes are these semitones above the ding:

| scale | semitones above the ding |
|---|---|
| Kurd | 7 8 10 12 14 15 17 19 |
| Celtic Minor | 7 10 12 14 15 17 19 22 |
| Hijaz | 7 8 11 12 14 15 17 19 |
| Pygmy | 7 10 12 14 15 19 22 24 |
| Integral | 7 8 10 12 14 15 19 22 |
| Chinese Pentatonic | 7 9 12 14 16 19 21 24 |

Some pans spelled out:
- D Kurd: D3 | A3 Bb3 C4 D4 E4 F4 G4 A4
- C# Kurd: C#3 | G#3 A3 B3 C#4 D#4 E4 F#4 G#4
- E Hijaz: E3 | B3 C4 D#4 E4 F#4 G4 A4 B4

The scale names are handpan layouts, named after the sound above the ding's fifth. In Hijaz, the notes from the fifth up (B3 C4 D#4 E4 in E Hijaz) form the Hijaz tetrachord: a half step, then the augmented second, then a half step. Measured from the ding, the whole pan is a harmonic minor scale (E F# G A B C D#), so the ding is the tonic of a minor key and the Hijaz color sits on its fifth. Kurd is natural minor from the ding, with the half step just above the fifth. Each layout has its own set of chords: some triads are complete on the pan, others lack a note, and a pattern's harmony is built from what the layout has.

Write notes as letter, optional accidental, octave: `C#4`, `Db4` and `Cs4` are the same note. A note that isn't on the pan is an error naming the line and listing the pan's notes:

```
line 4: 'D4' is not a note of this pan (E Hijaz: E3 B3 C4 D#4 E4 F#4 G4 A4 B4)
```

So to see a pan's notes, check a file using a note that isn't on it (see Checking).

**Where the notes sit** (this sets stereo placement): the ding is in the center. The 8 notes go from low to high in a zigzag: the lowest is bottom middle, then they alternate left and right going up, and the highest is top middle. Left-column notes sound from the left and right-column notes from the right, so runs up the scale bounce between the sides.

```
 note 6 | note 8 | note 7          D Kurd:   F4  | A4 | G4
 note 4 |  ding  | note 5                    D4  | D3 | E4
 note 2 | note 1 | note 3                    Bb3 | A3 | C4
```

Notes are numbered 1 (lowest) to 8 (highest).

## Events

### Taps (what you will mostly write)

```
TIME  NOTE  FORCE  [@X,Y]  [hold MS]  [rRADIUS]  [cCONTACT_MS]
```

- **FORCE**, 0.1 to 1.0. Harder is louder *and* brighter, with more overtones.
  - 0.15–0.3: ghost notes, quiet fills
  - 0.35–0.55: normal playing
  - 0.6–0.8: accents, the ding on the downbeat
  - 0.85–1.0: rare, big moments
- **@X,Y**: where on the note it is struck, in the note's own coordinates. The center is 0,0 and the rim is at radius 1. The default is `@0.15,0.10`, near the center: a pure tone. Toward the rim (`@0.5,0.0`) more octave and upper partials come through, giving a brighter, more complex sound. Stay within about 0.7 of the center.
- **hold MS**: the finger stays on the note for MS milliseconds before lifting. After about 50 ms a resting finger starts muting the note, as on a real pan. The muting fades in over the next 60 ms or so and pulls the note down while the finger stays. When the finger lifts, the muting stops and the note rings on from whatever level it has fallen to. On the ding at default settings, the tail after `hold 150` is about 5 dB quieter than a free note, after `hold 300` about 10 dB, and longer holds add little more (about 12 dB). So a hold softens and shortens a note and takes off its bloom; a higher `mute` setting chokes harder. Without `hold`, the finger lifts at once and the note rings freely.
- `rRADIUS` (contact size, default 0.12) and `cCONTACT_MS` (default derived from force) rarely need setting.

### Slap

```
TIME  slap  FORCE
```

A palm on the shell between the notes: a skin smack and a short metallic ring over a light thump from the cavity. Around 0.6–0.8 is a normal slap, 0.4 a light one, and 0.15–0.3 a soft ghost slap under a groove.

### Changing a setting mid-piece

```
TIME  set  KEY  VALUE
```

Only `gain`, `swell`, `tilt`, `mute`, `mute_floor`, `stereo`, `attack`. Scale, key, sustain, gu and reverb are fixed for the piece.

### Full form (recordings)

Recordings from the app use explicit fingers: `TIME down ID NOTE FORCE @X,Y rR cMS`, `TIME move ID @X,Y rR` (the finger slides or rests), `TIME up ID`. You can write these too; they are how a finger rests on a note and slides. Taps are simpler for composing.

## The instrument

- **Notes ring for a long time.** The ding sustains for several seconds and the higher notes for a few, so everything played blends with what is still sounding.
- **Bloom.** Over the first few hundred milliseconds each note's energy moves into its octave, so a long note changes color as it rings.
- **Sympathetic swell.** Any note 12 semitones (an octave) or 19 semitones (an octave and a fifth) above another note on the pan is tuned to swell in sympathy 300–400 ms after the lower one is struck. Work out the pairs from the scale table; the ding always wakes its octave.
- **Choking.** A finger left on a note (`hold`) darkens and shortens it, which gives a pattern rhythmic edges.
- **Polyphony.** Up to 16 fingers can be down at once.

## Making music on it

**Harmony lives in the patterns.** A handpan's harmony is what is left ringing. A repeating figure of bass, chord notes and ghost taps sets it, and the sustain blends the figure into a chord. The harmony moves when one note of the figure moves by a step while the rest keeps going, so changes feel like voices leading somewhere. Notes struck together make an accent at a moment the pattern has prepared. Uneven groupings of sixteenths give a figure its lilt.

**A motif carries the piece.** A short cell of two to four notes, with a shape and a rhythm the ear can hold onto, is the material everything grows from. It develops by moving through the texture: stated on top of a quiet pattern, then taking over some of the pattern's middle notes, then built into the figure itself, then down in the low notes with the pattern above it. It also develops in the familiar ways: sequenced through the harmony, inverted, cut down to its first interval, stretched into long notes or squeezed into short ones. A fixed rhythm keeps it recognizable wherever it sits. A piece can end with the motif alone.

**Energy follows the form.** Intensity builds through loudness, register, slaps, fuller patterns and faster harmonic change. The tempo moves with the form: it presses into a climax, settles back, slows into a breakdown, takes a breath before a return. Silence after a full texture is one of the strongest moments available.

**Ornaments are a hand drummer's.** Flams and drags (two or three strokes on one note, often the ding), quick runs of ghost taps into a downbeat, short finger rolls swelling into an accent, a note clipped by a pressing finger, the ding and its octave struck by both hands a hair apart. They sit where sections meet and at the arrivals of the motif. Their timing stays fixed in seconds whatever the tempo: a flam's strokes are 20–30 ms apart, a drag's about 55 ms, a run of ghost taps about 50 ms, a finger roll 30–40 ms.

**It is played with two hands.** Everything written has to fit two hands and a few fingers, unless asked otherwise. Ordinary strokes stay within three at once, four in any quarter second and ten in any second, with sixteenths as the working speed. A flam, drag or finger roll on one note is a single motion of one hand and counts as one stroke; a roll lasts up to about 0.4 s.

## Generating a score

For anything longer than a few bars, compute the times with a script.

- **Timing.** At B beats per minute a beat is 60/B seconds and a 16th is 15/B. A moving tempo is easiest as a tempo curve over beats, integrated to seconds. Ornaments are offsets in seconds from their main note.
- **Humanizing.** Jitter times by a few milliseconds (σ ≈ 5 ms), force by about ±6% and the spot by about 0.04. Notes meant to land together share one jitter, and an ornament moves as one unit so its spacing stays exact. Times stay at 0 or later, forces within 0.1–1.0, spots within about 0.7 of the center. A fixed random seed makes the piece reproducible.
- **Playability.** `render_test --check` (see Checking) measures the piece against the two-hand limits and names the busiest moment.

## Checking and rendering

From the repository root:

```
make -C engine
engine/build/render_test --rewrite scores/my-piece.txt > /dev/null   # parse only: prints the first error, with its line number
engine/build/render_test --check scores/my-piece.txt                 # playability: exits 1 if too dense for two hands
engine/build/render_test --play scores/my-piece.txt out.wav          # render (stereo, 48 kHz)
```

`--rewrite` without the redirect prints the piece in full form, with every note named as the engine sees it. That's a quick way to check you got the notes you meant. Its first line carries the version of the build that printed it.

`--check` reports the most strokes at once (within 20 ms), the most in any 250 ms and in any second, and the longest roll, each with the time it happens.

**How long the render is.** The file has no length or end marker. The render ends when the last notes have faded: it runs past the last event until the sound falls below −90 dB, then adds one second. An ending lasts as long as its final notes ring, about 4–6 s for the ding and less for high notes; a higher `sustain` makes it longer. `--play` prints the rendered length.

## Conventions

- Save scores in `scores/` as `<scale>-<key>-<title>.txt` in lowercase, with spaces in the scale name and title written as hyphens.
- Start with a comment describing the piece: tempo, form, ideas. A human will read it.
- If you generate a score with a script, commit the score. The script is optional.
