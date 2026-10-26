#pragma once
// Score files: a piece or a recording as plain text, played back bit for bit.
//
//   # morphion 0.3                 first line: the release that wrote the file
//   scale = Kurd                   header: the settings the engine reads (see Settings)
//   key = C#
//   0.000   C#3  0.72              a tap: lands and lifts at once
//   1.500   G#3  0.45 @0.20,0.05   ... at a spot on the note (field coordinates)
//   2.100   E4   0.50 hold 300     ... finger left down 300 ms (the resting finger mutes it)
//   3.000   slap 0.6
//   4.000   set stereo 0.8         a live setting changes
//   5.000000 down 3 C#4 0.61 @0.18,0.07 r0.12 c1.25   full form (what the recorder writes):
//   5.011333 move 3 @0.19,0.07 r0.13                  finger id, force, spot, radius, contact ms
//   5.052000 up 3
//
// A `#` at the start of a line or after a space starts a comment (C#4 is a note). Times are
// seconds, rounded to the nearest sample at kRate; the engine applies each event at the start
// of the first block at or after its sample, and a `set` before that block's events. Lines may
// come in any order; same-time lines keep their file order. Format changes are additive only:
// anything a release doesn't know is an error, never guessed at.

#include "morphion.h"

#include <cstdint>
#include <string>
#include <vector>

#ifndef MORPHION_VERSION
#define MORPHION_VERSION "dev"
#endif

namespace morphion::score {

constexpr double kRate = 48000.0;   // the engine's rate everywhere; part of the format

// Scales: a ding plus 8 notes, as semitones above the ding. Pygmy, Integral and the
// gong-mode pentatonic are built from their usual definitions, not maker charts.
struct ScaleDef { const char* name; int semis[8]; };
inline constexpr ScaleDef kScales[] = {
    {"Kurd", {7, 8, 10, 12, 14, 15, 17, 19}},
    {"Celtic Minor", {7, 10, 12, 14, 15, 17, 19, 22}},
    {"Hijaz", {7, 8, 11, 12, 14, 15, 17, 19}},
    {"Pygmy", {7, 10, 12, 14, 15, 19, 22, 24}},
    {"Integral", {7, 8, 10, 12, 14, 15, 19, 22}},
    {"Chinese Pentatonic", {7, 9, 12, 14, 16, 19, 21, 24}},
};
inline constexpr int kScaleCount = int(sizeof(kScales) / sizeof(kScales[0]));
// The ding's pitch: A2 up to G#3 (MIDI 45-56).
inline constexpr const char* kKeys[12] = {"A", "Bb", "B", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab"};
inline constexpr const char* kNoteNames[12] = {"C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"};

// The playable fields: grid fields are numbered row * 3 + col, rows top to bottom; the ding is
// the centre and the 8 others zigzag upwards from the bottom middle (lowest) to the top middle
// (highest), as on the D Kurd layout. The single layout is one field, the ding an octave up.
struct Layout {
    int count = 9;
    int midi[9] = {};
    double freq[9] = {};
};
Layout layout(int scale, int key, bool single);
std::string noteName(int midi);            // "C#4", with the app's spellings (C# Eb F# Ab Bb)
std::string noteName(int midi, int key);   // spelled from the key's minor signature: G#3 in C#, Bb3 in D

// Everything the engine reads; the app's defaults. Header keys in brackets.
struct Settings {
    int scale = 0;              // [scale] index into kScales
    int key = 5;                // [key] index into kKeys: D
    bool single = false;        // [layout] grid | single
    float gain = 1.0f;          // [gain]
    float sustain = 1.0f;       // [sustain] multiplies every decay time
    float swell = 1.0f;         // [swell] cross-field coupling
    float tilt = -0.1f;         // [tilt]
    float gu = 0.2f;            // [gu] cavity coupling, 0 = off
    double guHz = 80.0;         // [gu_hz]
    double gap = 2.4;           // [gap] Hz below a 3rd harmonic a listener is tuned
    double gap2x = 0.45;        // [gap_2x] same for 2nd-harmonic pairs
    float mute = 0.6f;          // [mute] resting-finger damping
    float muteFloor = 0.15f;    // [mute_floor]
    float stereo = 0.5f;        // [stereo] width
    float attack = 1.0f;        // [attack] strike click and shimmer
};

struct Line {
    enum Kind { Down, Move, Up, Slap, Set } kind = Down;
    int64_t sample = 0;
    int finger = 0;
    int field = 0;
    float x = 0.15f, y = 0.1f, force = 0.5f, contactMs = 1.2f, radius = 0.12f;
    std::string key;            // Set: the setting
    float value = 0.0f;         // Set
    int lineNo = 0;             // in the file, for messages
};

struct Piece {
    std::string version;        // from the first line
    Settings settings;
    std::vector<Line> lines;    // sorted by sample, stably
    int64_t end() const { return lines.empty() ? 0 : lines.back().sample; }
};

// false with a message naming the line on any error
bool parse(const std::string& text, Piece& out, std::string& error);
// header and full-form lines, stamped with this release
std::string write(const Piece& piece);

// Configure the engine for the piece: layout, decays, links, cavity, pans, live settings.
void configure(Engine& engine, const Piece& piece);
// Apply one live setting (gain swell tilt mute mute_floor stereo attack); false if unknown.
bool applySetting(Engine& engine, const std::string& key, float value);

// Feeds a piece's events to an engine as it renders: before each engine block, every line due
// at or before the block's first sample. Call configure first, and give it every process call.
class Player {
public:
    Player(Engine& engine, const Piece& piece) : engine_(engine), piece_(piece) {}
    void process(float* left, float* right, int frames);
    bool done() const { return next_ >= piece_.lines.size(); }
    int dropped() const { return dropped_; }   // events the engine's queue had no room for

private:
    Engine& engine_;
    const Piece& piece_;
    size_t next_ = 0;
    int64_t pos_ = 0;           // samples handed out since configure
    int dropped_ = 0;
    void feed();
};

}  // namespace morphion::score
