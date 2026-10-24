# Handpan acoustics for real-time modal synthesis

Tags: **[M]** measured or published; **[U]** widely repeated, unsourced; **[I]** inference or calculation.

## 1. Tone-field vibration

**Mode shapes [M].** Holographic interferometry of a Hang field shows three tuned modes (Morrison & Rossing 2007; Rossing et al. ISMA 2007):

- **(0,1)**: the whole field moves in phase. Fundamental.
- **(1,1)a** and **(1,1)b**: one nodal line each, orthogonal to each other. Octave and twelfth (compound fifth), giving 1:2:3.

The two (1,1) modes are one degenerate pair that the tuner splits by about ×1.5. PANArt: "Shaping a hyperbolic area around the dome leads to a frequency ratio of 2:3 of the (1,0) and (0,1) modes (octave and fifth)" (Rohner & Schärer 2007, different index convention). The central dome gives "a strong fundamental with two harmonic partials, an octave and a fifth. The higher modes came to lie around the third octave due to the stiffening effect of the dome."

**Measured frequencies [M]** (cents from 1:2:3 are [I]):

| Field | Modes (Hz) | Octave | Twelfth | Source |
|---|---|---|---|---|
| High-voice Hang, G3 ding | 189 / 390 / 593; (2,1)a,b 1418 / 1543 | +54 c | +78 c | Morrison & Rossing 2007 |
| Low-voice Hang, F3 ding | 174 / 348 / 520 | 0 | −7 c | Morrison & Rossing 2007 |
| Low-voice F#4 | 368 / 738 / 1104 | +5 c | 0 | Wessel et al. 2008 |
| Integral Hang, D3 ding | 148 / 295 / 445; 4th at 1344 | −6 c | +4 c | Wessel et al. 2008 |
| Non-PANArt handpans (pre-retune) | ratios 1.96–1.99, 2.92–2.99 | −37 to −6 c | −49 to −10 c | Alon 2015, Table 4.1 |
| Steelpan G3 (PANArt tenor) | 198.9 / 391.9 / 583.8 | −26 c | −38 c | Hansen & Rossing 2005 |

Holographic frequencies are drive frequencies, accurate to a few Hz. Wessel 2008's "178 Hz" for the G3 ding looks like a typo for 189. **[I]** Good PANArt fields sit within about ±10 cents; rougher handpans run 10–50 cents flat on the upper partials. PANArt tunes for overall sound, not exact ratios.

**Higher, untuned modes [M].** They come as split pairs with quasi-circular symmetry around the dome (Hansen & Rossing 2005):

- G3 ding: (2,1) pair at 7.5× and 8.2× f0.
- Integral ding: 4th mode at 9.1× f0.
- Ping C4: pairs at 2004/2066 Hz (7.6–7.9× f0) and 3725/3904 Hz (14–15×).

**Material and geometry [M].** Gas-nitrided steel (600 °C in ammonia, then 15 min at 400 °C). Ding shell 50 cm diameter, 0.91–0.95 mm thick (Rohner & Schärer 2007); instrument about 52 × 24 cm. Modes stay localised in note regions, with confinement set by the curvature difference between note and bowl (Bryde & Mahadevan 2023, steelpan).

**Relative amplitudes [M]** (Alon Table 4.1; struck at the fundamental sweet spot, mic 20–50 cm, dB relative to strongest peak, strike speed uncontrolled):

- Fundamental: −0.8 to −2.6 dB
- Octave: −2 to −11 dB (louder than the fundamental on D4 and F4)
- Twelfth: −9 to −22 dB

Wessel 2008: a ppp stroke has "but two audibly significant components in an octave relationship"; at fff the high components are inharmonic with strong beating.

**How many modes matter [M].** Alon's listening test (21 subjects): about 4–7 modes per note, fewer if beating oscillators are added (soft result: his decay-constant formula had an error). Steelpan: "from 3 to 10 modes" in normal playing (Monteil et al. 2012).

## 2. Decay and damping

**Handpan T60 per partial [M]** (Alon 2015, Appendix F; four instruments, three makers):

- Mean 2.9 s (SD 1.0), range 0.87–5.9 s.
- Low notes (B2–B3) 3.2 s; mid (C4–E4) 3.0 s; high (F4–C5) 2.5 s.
- Examples, fundamental / octave / twelfth: B3 4.0 / 5.1 / (8.9, flagged inaccurate); D4 5.9 / 2.6 / 2.3; F#3 2.5 / 4.7 / 3.2; C5 2.6 / 1.9 / 0.87.
- No consistent ordering between partials. The octave often outlasts the fundamental on lower notes; the twelfth is usually shortest on high notes.
- Fundamental T60 barely changes with strike position. Loud notes ring longer than soft ones (Wessel 2008).
- Caveats: −60 dB was referenced to the strongest peak, biasing weaker partials short; undamped measurements include beating from coupling.

**As Q [I]:** Q = π f T60 / ln 1000 ≈ 0.455 f T60 → roughly **Q ≈ 200–1200** (loss factor 1–5 × 10⁻³). B3 fundamental ≈ 450; B4 octave ≈ 1150; C5 twelfth ≈ 620.

**Steelpan comparison [M]** (Maloney 2010): painted soprano pan Q = 50–800, mostly 100–300. Bare low-carbon steel > 1000; annealed at 350–400 °C, up to 5000–9000. Paint and chrome add damping.

**Nitrided vs stainless.** [M] PANArt chose nitrided steel partly for "low absorption"; nitriding gives a hard surface over a softer core and stable pitch. [U] Stainless is said to sustain longer and sound brighter; no controlled measurements found. [I] Model "material" as a global damping scale plus a frequency tilt; stainless maybe ×1.2–1.5 on T60 (guess).

## 3. Coupling (sympathetic resonance)

**Mechanism [M].** All fields share one shell; coupling is strongest between fields whose partials share a frequency, which is why layouts put octaves and fifths next to each other (Hansen & Rossing 2005; Physics Today 2009).

Coupling is partly **nonlinear** and grows with amplitude. Hang F3 ding driven at 348 Hz: at small amplitude F4 responds strongly and F#4 weakly; at large amplitude "at least three additional notes" respond. At 520 Hz the C4 (1,1)a and C5 (0,1) respond (Morrison & Rossing 2007).

**Numbers [M]:**

- **Mode splitting, steelpan** (Monteil et al. 2012): G3 octave and G4 fundamental form two global modes at 390.0 and 397.8 Hz (Δf/f ≈ 2.0%); at 4f1, 789.5 / 799.3 Hz (1.2%).
- **Handpan beating** (Alon Table 4.3): 3.3 Hz at 662 Hz, 8.6 Hz at 438 Hz, 3.9 Hz at 248 Hz, 3.1 Hz at 373 Hz, 3.3 Hz at 374 Hz. Muting the other fields nearly removes it.
- **Sympathetic peak strength** (Alon Table 4.5, D4 field): peaks from other fields are 13–22 dB stronger with those fields free than muted (B2 +21, F#3 +15, E4 +16, F#4 +15, B4 +13, F#5 +22).
- **Bloom onset delays** (Alon Table 4.4, F#3 field): fundamental peaks within 23 ms; octave at 92 ms; 748 Hz component at 209 ms (92 ms with neighbours muted); 556 Hz at 510 ms (372 ms muted).
- **Nonlinear threshold, steelpan:** mode coupling switches on around amplitude h/25. Models with 1:2:2 and 1:2:4 internal resonance reproduce forced responses; a fitted 1:2:4 model reproduced a struck note's first four harmonics (Monteil et al. 2012; Thomas et al. 2014). [I] With h ≈ 0.93 mm that's about 40 µm, so handpans are probably in the coupled regime in normal playing.
- Steelpan: "damping the B4 note produces a very noticeable change in the timbre of the B3 note" (Physics Today 1996).
- Coupling is not reciprocal: it differs depending on which note of a pair is struck (Achong, via Alon). A steelpan video study saw the second harmonic decay fast then rise again about 90 ms later (arXiv 2102.00632).
- Steelpan skirt vibration is 19–46 dB below the note (Physics Today 1996).

Not found: a numeric coupling matrix for any handpan.

## 4. Body: Helmholtz resonance (Gu)

**[M]**

- Integral Hang: "a small peak at 85 Hz, the frequency of the cavity resonance (near F2)" in every note's spectrum (Wessel et al. 2008). Dziwak (coursework) measured ≈85 Hz, moving to ≈90 Hz with a mallet resting on a note.
- PANArt design target: Helmholtz resonance on the lap at D2 (≈73 Hz), ding an octave above (D3) (Rohner & Schärer 2007). [I] So ≈85 Hz free, pulled toward 73 Hz by the knees.
- Tunable by knee spacing (acoustic neck length) or a wooden collar.
- The ding "couples strongly to the cavity" (Rossing et al. 2007); striking it "excites a strong cavity (Helmholtz)" resonance (Wessel 2008).
- The Gu rim is itself tuned: D5 / F5 / F#5 for its (0,1) / (1,1)a / (1,1)b modes.
- Radiation 8 cm above the instrument: fundamental is monopole-like over the struck field; 2nd partial spread across much of the instrument; 3rd is dipole. Circulating reactive intensity suggests energy exchange between front and back (Morrison & Rossing 2007).

Not found: Helmholtz Q, Gu diameter, ding–cavity coupling coefficient. [I] Expect Q ≈ 5–30 (radiation damping through the port).

## 5. Excitation

**[M]**

- Technique "has considerable influence on ... spectral content, the decay time, and ... amplitude envelope"; "the longer the contact time the greater the damping effect" (Wessel 2008).
- Documented techniques: finger pad, fingernail, flams, multi-finger rolls, flat fingers or palm base on the ding, palm on the Gu (Wessel 2008; Alon 2015).
- **Strike position** (Alon, F#3 field): the "O" sweet spot raises the octave ≈ +5 dB; the "P" spot raises the fifth ≈ +7 dB, relative to the fundamental spot. Fundamental decay doesn't change.
- **Force:** harder strikes add more and stronger high partials and more beating.
- **Muting:** a finger at "O" while striking "P" isolates the fifth. Pressing the damping finger harder bends pitch slightly (Alon 2015). A resting mallet shortened f0 and f2 most, f1 less, and also shortened coupled partials (Dziwak).
- Contact-time references: rubber-tipped steelpan stick 1–2 ms on a tenor pan (Physics Today 1996), usually shorter than one fundamental period. Fingertip pulp is compliant below ≈1 N and stiffens fast above it (Serina et al. 1997). FoleyAutomatic models impact as F(t) = 1 − cos(2πt/τ), 0 ≤ t ≤ τ, finding "the exact details of the shape is relatively unimportant and the hardness is conveyed well by the duration" (van den Doel, Kry & Pai 2001).

Not found: measured finger contact duration or force on a handpan.

**[I] Finger model**

- Hunt–Crossley contact F = k xᵅ (1 + λ ẋ), α ≈ 1.5–2.5; contact time shortens weakly with impact speed (Hertz: τ ∝ v^−1/5).
- A quick fingertip must be near 1 ms. A raised-cosine pulse's first spectral null is at 2/τ, so τ = 3 ms nulls ≈ 670 Hz and kills the octave of D4, which real fingertip strikes clearly have. Raised-cosine nulls at k/τ also notch out individual upper modes; a Gaussian pulse avoids this.
- Damping during contact matters as much as τ: the finger is a dashpot draining the modes while it touches.
- Thumb: longer τ. Palm: covers the field, so the (1,1) modes average out (their nodal lines fall under the contact) → fundamental-heavy, thuddy. Nail: τ < 1 ms, bright.

## 6. Synthesis methods and existing synths

**Handpan / steelpan specific**

- **Wessel, Morrison & Rossing 2008** [M]: resonant filter bank, one filter per spectral component, fitted from recordings. A free-running bank (state carries over between strikes) captures how successive strikes in a roll differ; one reset on each impulse doesn't. **Never reset modal state on note-on.**
- **Alon 2015 / Alon & Murphy SMC 2015** [M]: decaying sinusoids convolved with a measured excitation (instrument struck with all fields and port muted), plus beating-correction oscillators.
- **Dziwak** (coursework) [M]: time-varying additive + FM, up to 15 harmonics per field, envelopes reused on coupled fields.
- **Monteil/Touzé/Thomas 2012–2015** [M]: reduced-order nonlinear modal models with quadratic coupling, aimed at modal sound synthesis:
  - q̈₁ + ω₁²q₁ = ε[−2μ₁q̇₁ − α₁q₁q₂ − α₂q₁q₃ + F cos Ωt]
  - q̈₂,₃ + ω²q₂,₃ = ε[−2μq̇ − α₃,₄q₁²]
  - This structure produces the low-to-high energy transfer (bloom).
- **Pianoteq Steelpans** (vendor): Steel Drum, Spacedrum, Hand Pan, Tank Drum. "Blooming energy" and "blooming inertia" controls; sustain pedal triggers the Gu resonance. Internals undisclosed.
- **Buhr Audio Physical Modelling Handpan**, **SampleScience Virtual Handpan** (vendor): claim physical modelling with sympathetic resonance and shimmer controls; no technical detail.

**General methods**

- **van den Doel & Pai**: y(t) = Σ aₙₖ e^{−dₙt} sin(2πfₙt), gain aₙₖ depending on strike location k, driven by audio-rate contact forces (FoleyAutomatic, SIGGRAPH 2001).
- **Cook**, *Real Sound Synthesis for Interactive Applications* (2002), PhISM. Not read.
- **Chadwick, An & James, "Harmonic Shells"** (SIGGRAPH Asia 2009): linear modes plus nonlinear thin-shell coupling via cubature, audio-rate mode updates at cost independent of mesh size; pitch glide, mode locking, FFAT radiation maps. Most directly relevant method for a steel shell.
- **Ducceschi & Touzé**, JSV 344 (2015): energy-conserving modal time-stepping for von Kármán plates with per-mode damping (gongs, cymbals).
- **Bilbao**, *Numerical Sound Synthesis* (2009); Webb & Bilbao DAFx-15 real-time FD plates; Physical Audio plugins (NESS project).

## Starting parameters

**Per tone field** (f0 = note frequency):

| Mode | Freq | T60 | Gain at centre strike | Source |
|---|---|---|---|---|
| (0,1) fundamental | f0 | 2.5–4 s low/mid, 2–3 s high | 0 dB | Alon [M] |
| (1,1)a octave | 2f0, ±5 c (good) or −10 to −35 c (rough) | 2–5 s, often ≥ fundamental below ~E4 | −3 dB (−11 to +2) | Alon, Morrison [M] |
| (1,1)b twelfth | 3f0, ±5–40 c | 1–3.5 s, shortest on high notes | −12 dB (−9 to −22) | Alon [M] |
| (2,1)a,b pair | ≈7.5 f0 and 8.2 f0 | ≈0.3–1 s | −25 to −40 dB, rising with force | freqs Morrison [M]; rest [I] |
| optional higher pair | ≈14–15 f0 | < 0.3 s | strike-dependent | Ping [M]; rest [I] |

Damping σ = π f / Q with Q 200–1200 [I].

**Strike-position gains [I].** Mode-shape gains over the elliptical field: φ₀₁ ≈ 1 − r²; φ₁₁a ∝ x, φ₁₁b ∝ y in field coordinates. These reproduce Alon's +5 dB octave / +7 dB fifth shifts. On an elongated field the lower (1,1) mode (octave) likely has its nodal line across the long axis (standard elliptical-plate behaviour; not documented for handpans).

**Linear coupling [I].** Global modal basis with coupled blocks wherever partials of different fields lie within ≈2% of each other. κ ≈ 0.003–0.02 (upper from Monteil's 2% split, lower from Alon's 3–9 Hz beats at 250–660 Hz). Diagonalise offline: each global mode then has shapes on several fields; the struck field sets excitation gain and every field contributes to radiation. Beating and the +13–22 dB sympathetic peaks fall out of the model.

**Nonlinear coupling [M]/[I].** Quadratic 1:2 internal-resonance terms: α q₁² driving the octave, α q₁q₂ back-reaction. Tune α so transfer starts around h/25 strike amplitude, giving an octave peak at ≈50–100 ms and later partials at ≈200–500 ms (Alon Table 4.4).

**Helmholtz / Gu.** One oscillator at 85 Hz free [M], adjustable down to 73 Hz (D2) for on-lap [M]. Q ≈ 10–20 [I]. Driven by net volume velocity of the (0,1) modes, ding weighted ≈5–10× outer fields [I]; two-way coupled. Mix quietly: a "small peak" in outer-note spectra [M].

**Excitation [I].** Gaussian pulse (sd τ/6), τ ≈ 1.2 ms (quick fingertip), 2.5 ms (thumb or slow), 5 ms (palm), 0.4 ms (nail), shortening as force^−1/5. Force scales gain and nonlinear coupling strength. During contact, add c·φₙ(x_c)² to each mode's damping; the same term covers muting with a resting finger. Pressure raises the Helmholtz mode ≈ +5% (85 → 90 Hz with a resting mallet [M]) and plate modes by a few cents [I].

## Gaps (searched, not found)

- Measured finger contact time or force on a handpan
- Helmholtz Q
- Numeric coupling matrix between handpan fields
- Controlled nitrided vs stainless decay measurements
- Peer-reviewed handpan physical-model synth paper beyond Alon & Murphy 2015
- Pianoteq and Buhr Audio internals
- Not accessed: Achong, JSV 197 (1996), doi:10.1006/jsvi.1996.0543; Monteil et al. 2015, Applied Acoustics, doi:10.1016/j.apacoust.2014.08.008; Morrison's 2005 PhD; full Physics Today 2009 web version

## Sources

- Morrison & Rossing, "Modes of vibration and sound radiation from the HANG", Archives of Acoustics 32(3) 551–560 (2007): https://acoustics.ippt.pan.pl/index.php/aa/article/download/709/627
- Rossing, Morrison, Hansen, Rohner, Schärer, "Acoustics of the HANG", ISMA 2007: https://www.hangblog.org/panart/2-S2-4-IsmaRossing.pdf
- Rohner & Schärer, "History, Development and Tuning of the HANG", ISMA 2007: https://www.hangblog.org/panart/Paper-Hang-2007.pdf
- Wessel, Morrison, Rossing, "Sound of the HANG", POMA 4, 035002 (2008): https://cnmat.berkeley.edu/sites/default/files/2008_sound_of_the_hang.pdf
- Morrison & Rossing, "The extraordinary sound of the hang", Physics Today 62(3) 66 (2009): https://aip.brightspotcdn.com/PTO.v62.i3.66_1.online.pdf
- Alon, "Analysis and Synthesis of the Handpan Sound", MSc, University of York (2015): https://etheses.whiterose.ac.uk/12260/1/EyalMSc.pdf ; Alon & Murphy, SMC 2015: https://zenodo.org/records/851153
- Monteil, Touzé, Thomas, ICSV 2012: https://perso.ensta-paris.fr/~touze/PDF/ICSV2012Monteil.pdf ; Thomas, Monteil, Touzé, ENOC 2014: https://perso.ensta-paris.fr/~touze/PDF/ENOC2014_ThomasMonteilTouze.pdf ; Monteil et al. 2015: https://sam.ensam.eu/handle/10985/10115
- Hansen & Rossing, "The Caribbean Steelpan, and some Offsprings", Forum Acusticum 2005: https://www.hangblog.org/pdf/hansen_rossing_the-caribbean-steelpan-and-some-offsprings.pdf
- Rossing, Hampton, Hansen, "Music from Oil Drums", Physics Today 49(3) 24 (1996): https://aip.brightspotcdn.com/PTO.v49.i3.24_1.online.pdf
- Maloney, PhD thesis, Cambridge (2010): https://www.repository.cam.ac.uk/handle/1810/238665
- Bryde & Mahadevan, "Localization in musical steelpans", Proc. R. Soc. A (2023): https://arxiv.org/abs/2212.14465
- Steelpan transient video study: https://arxiv.org/pdf/2102.00632
- Dziwak, "Sound of the handpan: analysis and synthesis" (Salford coursework): https://www.sonoresacoustics.be/portfolio/handpan
- van den Doel, Kry, Pai, "FoleyAutomatic", SIGGRAPH 2001: https://www.cs.mcgill.ca/~kry/pubs/foleyautomatic/foleyautomatic.pdf
- Chadwick, An, James, "Harmonic Shells", SIGGRAPH Asia 2009: https://www.cs.cornell.edu/projects/HarmonicShells/
- Ducceschi & Touzé, JSV 344 (2015): https://perso.ensta-paris.fr/~touze/modalsynthesis.html
- Serina et al., fingertip pulp, J. Biomech. (1997): https://www.coeh.berkeley.edu/publications/force-response-fingertip-pulp-repeated-compression-effects-loading-rate-loading-angle-and
- Pianoteq Steelpans: https://www.modartt.com/steelpans ; Buhr Audio: https://buhraudio.com/blog/what-is-a-physical-modelling-handpan ; SampleScience: https://samplescience.gumroad.com/l/virtualhandpan
- Hang overview: https://en.wikipedia.org/wiki/Hang_(instrument) ; stainless vs nitrided (vendor): https://blog.masterthehandpan.com/stainless-steel-handpans-just-a-fad/
