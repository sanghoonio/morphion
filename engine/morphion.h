// Real-time handpan engine: one modal model per tone field, plus links between
// fields that sit on each other's harmonics.
// Port of scripts/one_field.py and scripts/multi_field.py; see their docstrings
// for the model and docs/handpan-acoustics.md for where the numbers come from.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <vector>

namespace morphion {

constexpr int kModes = 6;          // fund, octave, twelfth, upper_a, upper_b, upper_axi
constexpr int kMaxPulses = 4;      // overlapping strikes on one field
constexpr int kMaxFingers = 16;

struct FieldParams {
    double f0 = 293.66;
    double octaveCents = 0.0;
    double twelfthCents = 0.0;
    double kappaOct = 0.025;       // fund^2 -> octave, units of omega_1^2
    double kappa12 = 0.025;        // fund*octave -> twelfth
    double decayScale = 1.0;       // multiplies every mode's T60 (the app's Sustain setting)
    double contactDamping = 60.0;  // extra sigma (1/s) at phi=1 for a 0.2-radius contact
    // Output is divided by omega_1^(1-tilt) * omega_ref^tilt: tilt 0 makes every struck
    // field equally loud in level; negative makes lower fields louder, so they sound as
    // loud as higher ones. Set by ear (multi_field.py).
    double radiationTilt = -0.1;
    double tiltRefHz = 293.66;
};

// Cross-field links (scripts/multi_field.py). A field whose fundamental is
// within tolCents of a lower field's 2nd or 3rd harmonic is retuned to
// (harmonic - gap) and driven by it, so it swells in after a strike on the
// lower field and peaks after about 1 / (2 gap).
struct CouplingParams {
    double gapHz = 2.4;      // 3x pairs: ~265 ms peak (one-way links)
    double gap2xHz = 0.45;   // 2x pairs: ~430 ms peak, 2.7 cents flat on D4
    double k3x = 0.16;       // drive from V = -k q1 q2 l1, units of the source's omega_1^2
    double k2x = 0.02;       // drive from V = -k q1^2 l1
    double tolCents = 30.0;
};

// The air cavity under the Gu hole: one Helmholtz resonator coupled both ways to
// every field's fundamental, V = -couple * weight * w_h * w_1 * q_h * q_1. The
// lowest field (the ding) gets dingWeight, the rest otherWeight. Only the
// frequency is measured (73-85 Hz); the rest was set by ear (multi_field.Gu).
struct GuParams {
    double f = 80.0;
    double t60 = 0.5;
    double out = 1.0;
    double couple = 0.2;     // 0 turns the cavity off
    double dingWeight = 1.0;
    double otherWeight = 0.15;
};

struct Link {
    int src, dst, order;     // order 2 or 3
    double k;                // absolute: strength * omega_src^2
};

// Find pairs and retune listeners. A listener with several sources is tuned
// to the lowest; the others get whatever gap results.
void findLinks(const std::vector<double>& freqs, const CouplingParams& c,
               std::vector<double>& tuned, std::vector<Link>& links);

// Modal amplitude of each mode at (x, y) in field coordinates (unit disc,
// x along the long axis) for a contact of radius a.
std::array<double, kModes> modeShapes(double x, double y, double a);

class Field {
public:
    void configure(const FieldParams& p, double sampleRate);

    // Start a strike. force 0..1, contactMs is tau at force 0.7, radius in field units.
    void strike(double x, double y, double force, double contactMs, double radius);

    // Extra per-mode damping from fingers resting on the field (sigma, 1/s).
    void setRestSigma(const std::array<double, kModes>& sigma);
    void setRadiationTilt(double tilt);

    // Force from links, added in the next tick() and then cleared.
    void addForce(int mode, double f) { ext_[mode] += f; }
    void wake() { asleep_ = false; sleepCheck_ = 0; }

    double tick();
    bool asleep() const { return asleep_; }
    double q(int mode) const { return q_[mode]; }
    double omega1() const { return w1_; }
    double outLevel() const { return outScale_ * w1_; }   // output per unit modal amplitude
    double modeLevel(int n) const;   // output amplitude of one mode
    double level() const;            // how loudly the field is ringing: its modes' levels summed in power

    double contactSigmaScale(double radius) const;
    const FieldParams& params() const { return p_; }

private:
    struct Pulse {
        bool on = false;
        int length = 0;
        int index = 0;
        double amp = 0.0;          // impulse / (sum(g) * dt)
        std::array<double, kModes> phi{};
        std::array<double, kModes> damp{};
    };

    FieldParams p_;
    double sr_ = 48000.0, dt_ = 1.0 / 48000.0;
    double w1_ = 0.0, k1_ = 0.0, k2_ = 0.0, outScale_ = 0.0;
    std::array<double, kModes> omega_{}, out_{};
    std::array<std::array<double, 4>, kModes> prop_{};
    std::array<double, kModes> q_{}, v_{};
    std::array<double, kModes> ext_{};
    std::array<double, kModes> restDamp_{};   // per-sample velocity multiplier
    bool resting_ = false;
    std::array<Pulse, kMaxPulses> pulses_{};
    bool asleep_ = true;
    int sleepCheck_ = 0;
};

struct Event {
    enum Type : int { Down, Move, Up, Slap } type;   // Slap: a palm on the shell; uses force only
    int finger;      // touch identifier, any int
    int field;       // Down only
    float x, y;      // field coordinates
    float force;     // Down only
    float contactMs; // Down only
    float radius;
};

// Single-producer single-consumer ring buffer: touch thread pushes, audio thread pops.
template <typename T, size_t N>
class SpscQueue {
public:
    bool push(const T& item) {
        size_t w = write_.load(std::memory_order_relaxed);
        size_t next = (w + 1) % N;
        if (next == read_.load(std::memory_order_acquire)) return false;
        buf_[w] = item;
        write_.store(next, std::memory_order_release);
        return true;
    }
    bool pop(T& item) {
        size_t r = read_.load(std::memory_order_relaxed);
        if (r == write_.load(std::memory_order_acquire)) return false;
        item = buf_[r];
        read_.store((r + 1) % N, std::memory_order_release);
        return true;
    }

private:
    std::array<T, N> buf_{};
    std::atomic<size_t> write_{0}, read_{0};
};

class Engine {
public:
    // Allocates; call before audio starts.
    void configure(double sampleRate, const std::vector<double>& fieldFreqs, const FieldParams& base,
                   const CouplingParams& coupling = {}, const GuParams& gu = {});

    bool push(const Event& e) { return queue_.push(e); }   // any one non-audio thread

    // Audio thread: no allocation, no locks.
    void process(float* left, float* right, int frames);

    // settable from any thread while running
    std::atomic<float> gain{1.0f};           // a hard single strike peaks near -0.5 dBFS (just into the limiter knee)
    std::atomic<float> restStrength{0.6f};   // resting-finger damping relative to strike contact damping
    std::atomic<float> restFloor{0.15f};     // damping anywhere on the field, as a fraction of the centre's
    // A trackpad tap keeps the finger down 40-75 ms where steel would bounce it off in 1-2 ms,
    // so a resting finger only starts muting after a grace period, then fades in.
    float restGraceMs = 50.0f;
    float restRampMs = 60.0f;
    // Peak limiter on the mix: looks 1.5 ms ahead and turns the gain down smoothly before a
    // peak would pass the ceiling, recovering over ~150 ms. It changes level only, so it
    // adds no new tones (a waveshaper made intermodulation buzz on stacked notes).
    bool limiter = true;
    std::atomic<float> coupling{1.0f};   // scales every link; settable from any thread
    std::atomic<float> attackLevel{1.0f};    // scales the strike click and shimmer (force-weighted), 0 = off
    std::atomic<float> radiationTilt{0.0f};   // live override of FieldParams::radiationTilt
    int fieldCount() const { return static_cast<int>(fields_.size()); }
    double fieldFreq(int i) const { return heard_[i]; }   // pitch heard, after link retuning
    const std::vector<Link>& links() const { return links_; }
    // How loudly each field (and each of its modes) is ringing, before the gain, updated once
    // per block. For drawing; readable from any thread.
    static constexpr int kMaxFields = 16;
    float fieldLevel(int i) const { return i >= 0 && i < kMaxFields ? levels_[i].load(std::memory_order_relaxed) : 0.0f; }
    float modeLevel(int i, int n) const {
        return i >= 0 && i < kMaxFields ? modeLevels_[i * kModes + n].load(std::memory_order_relaxed) : 0.0f;
    }

private:
    struct Finger {
        bool on = false;
        int id = 0;
        int field = 0;
        float x = 0, y = 0, radius = 0;
        int age = 0;            // samples since touch-down
        float weight = 0.0f;    // how much of the resting-finger damping applies (0..1)
    };

    void handle(const Event& e);
    void updateRest(int field);

    std::vector<Field> fields_;
    std::vector<Link> links_;
    std::vector<double> heard_;
    float appliedTilt_ = 0.0f;
    std::vector<float> limDelay_;    // lookahead line
    size_t limPos_ = 0;
    float limGain_ = 1.0f, limAttack_ = 0.0f, limRelease_ = 0.0f;
    double engineSr_ = 48000.0;

    void setGuTilt(double tilt);
    GuParams gu_;
    double sr_ = 48000.0;
    // Strike attack: finger on metal. A click of filtered noise as long as the contact, then a
    // shimmer from 16 high, inharmonic shell modes (2-9 kHz, different for each note, filtered
    // by the contact like the note's own modes). In the recordings this band (2.5-12 kHz) starts
    // ~20-36 dB under the tone, holds ~-35 to -45 dB for ~25 ms and is ~-50 dB at 100 ms.
    static constexpr int kAttackModes = 16;
    struct Attack {
        bool on = false;
        int age = 0;
        double click = 0, clickDecay = 0, lpA = 0, hp = 0, lp = 0, prev = 0;
        std::array<std::array<double, 4>, kAttackModes> prop{};
        std::array<double, kAttackModes> q{}, v{}, w{};
    };
    std::array<Attack, 8> attacks_{};
    uint32_t attackSeed_ = 987654321u;
    void startAttack(int field, double level, double force, double contactMs);

    bool guOn_ = false;      // cavity coupled to the fields
    bool guOsc_ = false;     // cavity oscillator exists (also rung by slaps when uncoupled)

    // Slap: a palm on the shell between the notes. The Gu cavity gets a push of air, the
    // shell's own low body modes knock and die fast (the palm stays on), skin on metal makes
    // a short noise burst, and every field rings faintly through the shell.
    static constexpr int kShellModes = 6;
    std::array<std::array<double, 4>, kShellModes> shellProp_{};
    std::array<double, kShellModes> shellQ_{}, shellV_{}, shellOmega_{};
    int slapLeft_ = 0, slapLen_ = 1;     // palm contact: the shell is pushed over a few ms, not instantly
    double slapForce_ = 0.0, slapNorm_ = 1.0;
    int noiseLeft_ = 0;
    double noiseEnv_ = 0.0, noiseDecay_ = 0.0, noiseHp_ = 0.0, noiseLp_ = 0.0, noisePrev_ = 0.0;
    uint32_t noiseSeed_ = 12345u;
    void slap(double force);
    double guOmega_ = 0.0, guTiltRef_ = 0.0, guNorm_ = 0.0, guQ_ = 0.0, guV_ = 0.0;
    std::array<double, 4> guProp_{};
    std::vector<double> guCouple_;   // absolute, per field
    std::array<Finger, kMaxFingers> fingers_{};
    std::array<std::atomic<float>, kMaxFields> levels_{};
    std::array<std::atomic<float>, kMaxFields * kModes> modeLevels_{};
    SpscQueue<Event, 1024> queue_;
};

}  // namespace morphion
