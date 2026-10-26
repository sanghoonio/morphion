---
date: 2026-10-26
status: complete
model: Claude Opus 5.5 (claude-opus-5-5)
description: A fresh Claude agent's feedback on scores/AGENTS.md after writing a D Celtic Minor piece from it
---

# Feedback on scores/AGENTS.md

Written after composing `scores/celtic-minor-d-the-turning-stone.txt` using only the guide and its two named example scores. Render: `scripts/renders/scores/celtic-minor-d-the-turning-stone.wav` (70.7 s, 225 score events, 433 full-form events).

## The piece

*The Turning Stone*, D Celtic Minor (D3 | A3 C4 D4 E4 F4 G4 A4 C5), in 6/8 with the dotted quarter between 40 and 74.

- **Motif:** A3 up a sixth to F4, then a step down to E4, always in quarter, eighth, dotted quarter (long-short-long). It starts on the second beat and lands on a downbeat.
- **Pattern and harmony:** a 3+3 eighth-note figure: the ding on 1, then the chord's middle, low and high notes, with rim ghosts between them. The harmony moves one voice at a time: Dm (A3 D4 F4), then F (D4 goes to C4), then Am (F4 goes to E4), then C (C4 E4 G4).
- **Form and development, following the guide's sequence:**
  - Intro: the motif alone, stretched to twice its length.
  - A: the motif above a quiet pattern, sequenced up the pan (A3 F4 E4, C4 G4 F4, D4 A4 G4).
  - B: the motif squeezed into 16ths (2:1:3) takes the pattern's middle voices. Then the figure is built from the squeezed motif in both halves of the bar, while the stretched motif climbs D4 A4 G4, then E4 C5 A4, on top. The climax follows, then silence.
  - Breakdown: the motif slow and low, with `set mute 1.1` and a faint pattern up in C5 and A4. Then the motif is cut to its first interval (A3 F4) and the last F4 is clipped with `hold 150`.
  - A 0.45 s breath.
  - Return: the motif, then its inversion (F4 A3 C4), then one last high statement.
  - Coda: the motif alone, then its first interval, then the ding.
- **Tempo:** a curve per bar integrated to seconds: 50 to 54, 60 to 64, pressing 64 to 74, the breakdown 48 to 44, the return 60 to 63, the coda 54 to 40.
- **Ornaments, at the joints:**
  - a run of three rim ghosts into A;
  - a two-stroke drag on the ding into B;
  - a 28 ms flam on motif arrivals;
  - a four-stroke finger roll (G4/A4 alternating, crescendo) into the climax;
  - the ding and D4 by both hands 12–14 ms apart, with a slap, at the climax and at the return;
  - a three-tap fill into the third bar of the return;
  - a clipped note in the breakdown.
- **Energy:** slaps start soft (0.32) in B and grow to 0.72 at the climax. Section RMS goes from about −20 dB (intro) to −13.7 dB (climax), drops to −22.8 dB (breakdown), comes back to −15.6 dB (return) and falls to −24 dB (coda).
- **Playability** (my own counter, since the guide gives no tool): at most 3 strokes at once (the climax: ding, slap and D4 within 18 ms), at most 4 in any 250 ms, at most 9 in any second. The first draft had 6 in 250 ms, where the roll overlapped the B figure, and 5 at a fill-plus-downbeat. I fixed both by spacing them out and dropping the figure's second half under the roll.

## What was clear and useful

- **The file format section** is complete and exact. My first parse succeeded. The note-error example ("check a file using a note that isn't on it") is a neat trick, though I could compute the D Celtic Minor notes from the semitone table instead.
- **The semitone table, the worked examples and the zigzag layout diagram** were enough to place every note and predict which side it sounds from.
- **"Harmony lives in the patterns"** was the most useful paragraph. "One note of the figure moves by a step" translated directly into a voicing table and a progression.
- **The motif-development paragraph** gave a ready-made form: above, among, within, below, alone. The list of familiar transformations (sequence, inversion, cut to first interval, stretched, squeezed) plus "a fixed rhythm keeps it recognisable" told me exactly what to keep constant.
- **The `hold` paragraph** with numbers (−5 dB at 150 ms, −10 dB at 300 ms) made clipped notes something I could design rather than guess.
- **The Generating section** (16th = 15/B, a tempo curve integrated over beats, shared jitter for simultaneous notes, the three playability numbers) is the right level of detail for writing a generator.
- **The render-length paragraph** explained the ending behaviour in advance, so a 70.7 s render from a 65.45 s last event was no surprise.

## What was missing, ambiguous or wrong

1. **The file name for a two-word scale.** The guide says "`<scale>-<key>-<title>.txt` in lowercase", but `Celtic Minor` (and `Chinese Pentatonic`) contain a space. I used `celtic-minor-d-...`. The examples only show `kurd`.
2. **The version line disagrees with the engine.** The guide says "Line 1 must be `# morphion <version>` ... Use `0.3`." `render_test --rewrite` prints `# morphion 0.2.2` at the top of its output, while `--play` says "made with morphion 0.3". Harmless, but confusing if you compare against the rewrite.
3. **The sympathetic swell is only given for Kurd.** The guide says "In Kurd the ding wakes note 4 (its octave) and note 8, and note 1 also wakes note 8." It isn't clear whether the swell follows the interval on any scale (so in D Celtic Minor the ding wakes D4 = note 3 and A4 = note 7, A3 wakes A4, and C4 wakes C5) or is tuned per layout. I assumed the interval rule. It matters for deciding which notes to leave unstruck so the swell can speak.
4. **The playability check is underspecified.** "Count strokes: at most 3 at the same moment, 4 in any 250 ms, and about 10 in any second." It doesn't say:
   - what counts as "the same moment" (I used 20 ms; a flam 12–30 ms apart is either one moment or two);
   - whether slaps count (I counted them);
   - whether there is a tool, or each composer writes a counter. The guide calls it "the guide's playability check", but it is only a rule.
5. **Rolls conflict with the stroke limit.** "Rolls lasting a beat or so" and "short finger rolls swelling into an accent" can't be fast: 4 strokes in 250 ms caps a roll at about 12 strokes per second, less once the target accent and other hands are counted. My roll had to be 105 ms apart, which is closer to a 16th run than a roll. The guide should say so, or say rolls are the allowed "short burst" exception.
6. **Ornament timings are not quantified.** The guide says ornaments are "two or three strokes on one note", struck "a hair apart", and "their timing stays fixed in seconds", but gives no numbers. I read the examples to get a 30 ms flam and used 12–14 ms for the two-hands ding and octave and 35–40 ms for drag spacing. A line with typical offsets would save opening the examples.
7. **Ghost taps "near the rim" vs "stay within about 0.7".** The examples put ghosts at about @0.5, which I copied. One line saying "ghosts at @0.45–0.55" would make this explicit.
8. **Meter is assumed to be 16ths in 4/4.** "16th = 15/B" and "3+3+2 sixteenths" work for 4/4. For 6/8 the beat unit is ambiguous (is B the dotted quarter or the eighth?). I defined tempo per dotted quarter with eighth = 20/B. A sentence saying the beat can be any unit, and that the 16th formula assumes a quarter-note beat, would help.
9. **No guidance on level or headroom.** My climax (ding 0.88, D4 0.78, slap 0.72, all within 18 ms) peaked at −0.43 dBFS. The guide gives a force scale but doesn't say whether stacking accents can clip, whether `gain` should be lowered for dense climaxes, or what peak a normal piece reaches.
10. **No way to audition, and nothing said about it.** An agent writing a score can't hear the render. The guide could suggest objective checks: section RMS to confirm the energy arc, peak level, and `--rewrite` to confirm notes. I did these on my own initiative.
11. **Small points:**
    - Humanising can push the first event below 0. The guide says "Times stay at 0 or later" but doesn't say whether the first event must be at exactly 0. Clamping worked.
    - The `hold` numbers are given only for the ding. Do higher notes choke faster?
    - The breakdown's `set mute` needs resetting; the guide doesn't say that `set` persists until changed, though I assumed it does.

## Judgement calls

- The file name `celtic-minor-d-...` for the two-word scale.
- The swell for Celtic Minor, assumed to follow the interval rule.
- A 6/8 meter with tempo in dotted quarters. The guide's whole rhythmic vocabulary is in 16ths.
- What counts as a stroke and as the same moment in the playability count: slaps counted, a 20 ms window.
- Ornament offsets, taken from the examples rather than the guide.
- `mute 1.1` in the breakdown, a value the guide doesn't bound ("a higher `mute` setting chokes harder").
- The climax force stack, left at −0.43 dBFS peak rather than lowering `gain`.

## Errors hit

- No parse errors. The format section is good enough to get it right first time.
- Playability violations: 6 strokes in 250 ms (the roll on top of the pattern) and 5 in 250 ms (a fill into a downbeat that carried both the ding and a motif note). The guide's numbers found them once I wrote a counter. It didn't say how to fix them, but the fixes were obvious: thin the pattern under ornaments and space the fill.
- A self-inflicted error that the guide indirectly caught: my intro's "stretched" motif was evenly spaced. Rereading "a fixed rhythm keeps it recognisable" sent me back to fix it to 4:2:6 eighths.

## Suggested edits

1. **Naming:** change the convention line to "`<scale>-<key>-<title>.txt` in lowercase with spaces as hyphens, e.g. `scores/kurd-d-evening.txt`, `scores/celtic-minor-d-...txt`".
2. **Swell:** replace the Kurd-only sentence with a general rule plus a per-scale line, e.g. "Any note an octave or an octave-and-a-fifth above another on the pan swells with it. In Kurd the ding wakes note 4 and note 8. In Celtic Minor the ding wakes note 3 (its octave) and note 7, note 1 wakes note 7, and note 2 wakes note 8." (Confirm this against the engine.)
3. **Playability:** define it exactly, e.g. "Count every tap and slap, not holds or `set`. 'At once' means within 20 ms. Flams and the two-hand ding and octave count as two strokes." Ship a small checker, or a `render_test --check` flag, if one exists.
4. **Ornament numbers:** add one line: "Typical offsets: flam 20–35 ms before the main stroke, drag strokes 35–40 ms apart, both hands 10–15 ms apart, ghost runs 60–80 ms apart. A roll must still fit 4 strokes in 250 ms, so roll strokes are at least about 85 ms apart, or treat a roll as the one allowed burst."
5. **Meter:** add "The beat can be any unit. For 6/8 use the dotted quarter as B, and an eighth is 20/B."
6. **Headroom:** add a line on peak level, e.g. "Three hard strokes at once (around 0.8) peak near 0 dBFS. Lower `gain` or the forces if a climax stacks accents."
7. **Version line:** fix `--rewrite` to print the score version (0.3), or note why it prints the engine version.
8. **Checking without ears:** add "You can't listen to the render, so check it: `--rewrite` for notes, and the per-section RMS of the WAV against the intended energy arc."
