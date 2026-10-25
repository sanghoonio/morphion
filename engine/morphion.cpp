#include "morphion.h"

#include <algorithm>
#include <cmath>

namespace morphion {

namespace {

constexpr double kPi = 3.14159265358979323846;
const double kLn1000 = std::log(1000.0);

struct ModeSpec {
    double ratio, t60, out;
};

// Interpolate from B2 (low) to C5 (high) on a log-frequency axis, clamped.
double lerpRegister(double f0, double low, double high) {
    double t = (std::log(f0) - std::log(123.0)) / (std::log(523.0) - std::log(123.0));
    t = std::clamp(t, 0.0, 1.0);
    return low + (high - low) * t;
}

std::array<ModeSpec, kModes> modeSpecs(const FieldParams& p) {
    double tFund = lerpRegister(p.f0, 3.2, 2.5) * p.decayScale;  // Alon 2015 register means
    return {{
        {1.0, tFund, 1.0},
        {2.0 * std::pow(2.0, p.octaveCents / 1200.0), tFund * lerpRegister(p.f0, 1.0, 0.8), 0.5},
        {3.0 * std::pow(2.0, p.twelfthCents / 1200.0), tFund * lerpRegister(p.f0, 0.9, 0.45), 0.35},
        {7.5, 0.6 * p.decayScale, 0.25},
        {8.2, 0.5 * p.decayScale, 0.25},
        {9.1, 0.4 * p.decayScale, 0.2},
    }};
}

}  // namespace

std::array<double, kModes> modeShapes(double x, double y, double a) {
    double r2 = x * x + y * y;
    return {
        std::max(0.0, 1.0 - r2 - 0.5 * a * a),  // (0,1) whole field in phase, averaged over contact
        x,                                       // (1,1)a octave: nodal line across the long axis
        y,                                       // (1,1)b twelfth: nodal line along the long axis
        x * x - y * y,
        2.0 * x * y,
        1.0 - 3.0 * r2 - 1.5 * a * a,            // axisymmetric, non-zero at the centre
    };
}

// ---------------------------------------------------------------- Field

void Field::configure(const FieldParams& p, double sampleRate) {
    p_ = p;
    sr_ = sampleRate;
    dt_ = 1.0 / sampleRate;
    w1_ = 2.0 * kPi * p.f0;
    k1_ = p.kappaOct * w1_ * w1_;
    k2_ = p.kappa12 * w1_ * w1_;
    setRadiationTilt(p.radiationTilt);

    auto specs = modeSpecs(p);
    for (int n = 0; n < kModes; ++n) {
        double w = w1_ * specs[n].ratio;
        double s = kLn1000 / specs[n].t60;
        double d = std::sqrt(w * w - s * s);
        double e = std::exp(-s * dt_), c = std::cos(d * dt_), sn = std::sin(d * dt_);
        // exact one-step propagator of the free damped oscillator
        prop_[n] = {e * (c + s / d * sn), e * sn / d, -e * w * w / d * sn, e * (c - s / d * sn)};
        omega_[n] = w;
        out_[n] = specs[n].out;
        q_[n] = v_[n] = 0.0;
        restDamp_[n] = 1.0;
    }
    resting_ = false;
    for (auto& pl : pulses_) pl.on = false;
    asleep_ = true;
}

void Field::setRadiationTilt(double tilt) {
    p_.radiationTilt = tilt;
    outScale_ = 1.0 / (std::pow(w1_, 1.0 - tilt) * std::pow(2.0 * kPi * p_.tiltRefHz, tilt));
}

double Field::contactSigmaScale(double radius) const {
    double k = radius / 0.2;
    return p_.contactDamping * k * k;
}

void Field::strike(double x, double y, double force, double contactMs, double radius) {
    Pulse* slot = &pulses_[0];
    for (auto& pl : pulses_) {
        if (!pl.on) { slot = &pl; break; }
        if (pl.index > slot->index) slot = &pl;   // all busy: replace the most advanced
    }

    // Hertzian contact: harder strikes compress faster, tau ~ v^(-1/5)
    double tau = contactMs / 1000.0 * std::pow(std::max(force, 0.05) / 0.7, -0.2);
    int length = std::max(2, static_cast<int>(std::lround(tau * sr_)));

    // Gaussian pulse, sd = length/6, normalised so its integral is the impulse
    double sum = 0.0, half = length / 2.0, sd = length / 6.0;
    for (int i = 0; i < length; ++i) {
        double u = (i + 0.5 - half) / sd;
        sum += std::exp(-0.5 * u * u);
    }
    double impulse = force * w1_;   // fundamental reaches amplitude ~force at the centre

    double c = contactSigmaScale(radius);
    auto phi = modeShapes(x, y, radius);
    slot->on = true;
    slot->length = length;
    slot->index = 0;
    slot->amp = impulse / (sum * dt_);
    for (int n = 0; n < kModes; ++n) {
        slot->phi[n] = phi[n];
        slot->damp[n] = std::exp(-2.0 * c * phi[n] * phi[n] * dt_);
    }
    asleep_ = false;
    sleepCheck_ = 0;
}

void Field::setRestSigma(const std::array<double, kModes>& sigma) {
    resting_ = false;
    for (int n = 0; n < kModes; ++n) {
        restDamp_[n] = std::exp(-2.0 * sigma[n] * dt_);
        if (sigma[n] > 0.0) resting_ = true;
    }
}

double Field::tick() {
    if (asleep_) return 0.0;

    double q1 = q_[0], q2 = q_[1], q3 = q_[2];
    std::array<double, kModes> f = ext_;
    ext_.fill(0.0);
    f[0] -= 2.0 * k1_ * q1 * q2 + k2_ * q2 * q3;
    f[1] -= k1_ * q1 * q1 + k2_ * q1 * q3;
    f[2] -= k2_ * q1 * q2;

    std::array<double, kModes> damp;
    damp.fill(1.0);
    bool contact = resting_;
    if (resting_) damp = restDamp_;
    for (auto& pl : pulses_) {
        if (!pl.on) continue;
        double half = pl.length / 2.0, sd = pl.length / 6.0;
        double u = (pl.index + 0.5 - half) / sd;
        double force = pl.amp * std::exp(-0.5 * u * u);
        for (int n = 0; n < kModes; ++n) {
            f[n] += pl.phi[n] * force;
            damp[n] *= pl.damp[n];
        }
        contact = true;
        if (++pl.index >= pl.length) pl.on = false;
    }

    double acc = 0.0;
    for (int n = 0; n < kModes; ++n) {
        const auto& m = prop_[n];
        double qn = m[0] * q_[n] + m[1] * v_[n];
        double vn = m[2] * q_[n] + m[3] * v_[n];
        if (contact) vn *= damp[n];
        vn += f[n] * dt_;
        q_[n] = qn;
        v_[n] = vn;
        acc += out_[n] * vn;
    }

    // go to sleep once everything has decayed below ~-140 dB
    if (++sleepCheck_ >= 512) {
        sleepCheck_ = 0;
        bool pulsing = false;
        for (auto& pl : pulses_) pulsing |= pl.on;
        double e = 0.0;
        for (int n = 0; n < kModes; ++n) e += v_[n] * v_[n] + omega_[n] * omega_[n] * q_[n] * q_[n];
        if (!pulsing && e < 1e-14 * w1_ * w1_) {
            asleep_ = true;
            q_.fill(0.0);
            v_.fill(0.0);
        }
    }
    return acc * outScale_;
}

double Field::modeLevel(int n) const {
    if (asleep_) return 0.0;
    return std::fabs(out_[n] * outScale_) * std::sqrt(v_[n] * v_[n] + omega_[n] * omega_[n] * q_[n] * q_[n]);
}

double Field::level() const {
    double e = 0.0;
    for (int n = 0; n < kModes; ++n) e += modeLevel(n) * modeLevel(n);
    return std::sqrt(e);
}

// ---------------------------------------------------------------- Engine

void findLinks(const std::vector<double>& freqs, const CouplingParams& c,
               std::vector<double>& tuned, std::vector<Link>& links) {
    tuned = freqs;
    links.clear();
    for (size_t j = 0; j < freqs.size(); ++j) {
        double lowest = 0.0;
        int lowestOrder = 0;
        for (size_t i = 0; i < freqs.size(); ++i) {
            for (int n = 2; n <= 3; ++n) {
                if (freqs[i] >= freqs[j]) continue;
                if (std::fabs(1200.0 * std::log2(freqs[j] / (n * freqs[i]))) >= c.tolCents) continue;
                double strength = n == 3 ? c.k3x : c.k2x;
                double w = 2.0 * kPi * freqs[i];
                if (strength > 0.0)
                    links.push_back({static_cast<int>(i), static_cast<int>(j), n, strength * w * w});
                if (lowestOrder == 0 || freqs[i] < lowest) { lowest = freqs[i]; lowestOrder = n; }
            }
        }
        if (lowestOrder) tuned[j] = lowestOrder * lowest - (lowestOrder == 3 ? c.gapHz : c.gap2xHz);
    }
}

namespace {

// Nominal field and cavity frequencies that land on `freqs` and `guHz` once coupled
// (scripts/multi_field.py gu_detune, same algorithm): roots of the arrowhead secular
// equation F(l) = l - w_h^2 - sum_j c_j^2 / (l - w_j^2), fixed-point on the nominals.
void guDetune(std::vector<double>& freqs, double& guHz, const std::vector<double>& weights, double couple) {
    const size_t n = freqs.size();
    std::vector<double> wt(n), w(n), poles(n), c2(n), lam(n);
    for (size_t j = 0; j < n; ++j) wt[j] = w[j] = 2.0 * kPi * freqs[j];
    const double wht = 2.0 * kPi * guHz;
    double wh = wht;
    std::vector<size_t> order(n);
    for (size_t j = 0; j < n; ++j) order[j] = j;
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) { return w[a] < w[b]; });

    auto root = [&](double lo, double hi, double wh2) {
        for (int it = 0; it < 100; ++it) {
            double mid = 0.5 * (lo + hi), fv = mid - wh2;
            for (size_t j = 0; j < n; ++j) fv -= c2[j] / (mid - poles[j]);
            if (fv < 0.0) lo = mid; else hi = mid;
        }
        return 0.5 * (lo + hi);
    };
    for (int iter = 0; iter < 20; ++iter) {
        for (size_t j = 0; j < n; ++j) {
            poles[j] = w[j] * w[j];
            double c = couple * weights[j] * wh * w[j];
            c2[j] = c * c;
        }
        double lamH = root(0.0, poles[order[0]], wh * wh);
        for (size_t k = 0; k < n; ++k) {
            size_t j = order[k];
            double hi = k + 1 < n ? poles[order[k + 1]] : poles[j] * 4.0 + 4.0 * wh * wh;
            lam[j] = root(poles[j], hi, wh * wh);
        }
        wh *= wht / std::sqrt(lamH);
        for (size_t j = 0; j < n; ++j) w[j] *= wt[j] / std::sqrt(lam[j]);
    }
    for (size_t j = 0; j < n; ++j) freqs[j] = w[j] / (2.0 * kPi);
    guHz = wh / (2.0 * kPi);
}

}  // namespace

void Engine::setGuTilt(double tilt) {
    guNorm_ = 1.0 / (std::pow(guOmega_, 1.0 - tilt) * std::pow(guTiltRef_, tilt));
}

void Engine::configure(double sampleRate, const std::vector<double>& fieldFreqs, const FieldParams& base,
                       const CouplingParams& coupling, const GuParams& gu) {
    std::vector<double> tuned;
    findLinks(fieldFreqs, coupling, tuned, links_);
    heard_ = tuned;

    // With the cavity on, pre-tune fields and cavity so they sound at `tuned` and gu.f
    // once coupled, and keep each field's octave and twelfth at 2x and 3x the pitch heard.
    guOn_ = gu.couple > 0.0 && !tuned.empty();
    std::vector<double> nominal = tuned, guWeights(tuned.size(), gu.otherWeight);
    double guNominalHz = gu.f;
    if (guOn_) {
        size_t ding = std::min_element(tuned.begin(), tuned.end()) - tuned.begin();
        guWeights[ding] = gu.dingWeight;
        guDetune(nominal, guNominalHz, guWeights, gu.couple);
    }
    fields_.assign(fieldFreqs.size(), Field{});
    pan_.assign(fieldFreqs.size(), 0.0f);
    for (auto& l : levels_) l.store(0.0f, std::memory_order_relaxed);
    for (auto& l : modeLevels_) l.store(0.0f, std::memory_order_relaxed);
    for (size_t i = 0; i < tuned.size(); ++i) {
        FieldParams p = base;
        p.f0 = nominal[i];
        double keep = 1200.0 * std::log2(tuned[i] / nominal[i]);
        p.octaveCents += keep;
        p.twelfthCents += keep;
        fields_[i].configure(p, sampleRate);
    }
    for (auto& f : fingers_) f.on = false;
    appliedTilt_ = static_cast<float>(base.radiationTilt);
    radiationTilt = appliedTilt_;

    sr_ = sampleRate;
    engineSr_ = sampleRate;
    limDelay_.assign(std::max<size_t>(1, size_t(0.0015 * sampleRate)), 0.0f);
    limDelayR_.assign(limDelay_.size(), 0.0f);
    limPos_ = 0;
    limGain_ = 1.0f;
    limAttack_ = 1.0f - std::exp(-5.0f / float(limDelay_.size()));   // ~99% of the way within the lookahead
    limRelease_ = 1.0f - std::exp(-1.0f / float(0.15 * sampleRate));
    gu_ = gu;
    guQ_ = guV_ = 0.0;
    guCouple_.assign(fields_.size(), 0.0);
    guOsc_ = gu.f > 0.0 && gu.t60 > 0.0 && !fields_.empty();
    if (guOsc_) {
        double dt = 1.0 / sampleRate;
        guOmega_ = 2.0 * kPi * guNominalHz;
        guTiltRef_ = 2.0 * kPi * base.tiltRefHz;
        double s = kLn1000 / gu.t60, d = std::sqrt(guOmega_ * guOmega_ - s * s);
        double e = std::exp(-s * dt), c = std::cos(d * dt), sn = std::sin(d * dt);
        guProp_ = {e * (c + s / d * sn), e * sn / d, -e * guOmega_ * guOmega_ / d * sn, e * (c - s / d * sn)};
        if (guOn_)
            for (size_t j = 0; j < fields_.size(); ++j)
                guCouple_[j] = gu.couple * guWeights[j] * guOmega_ * fields_[j].omega1();
        setGuTilt(base.radiationTilt);
    }

    // shell body modes for slaps: low, inharmonic, short (set by ear)
    static const double shellHz[kShellModes] = {205, 465, 815, 1310, 2060, 3150};
    static const double shellT60[kShellModes] = {0.28, 0.20, 0.13, 0.09, 0.06, 0.04};
    for (int k = 0; k < kShellModes; ++k) {
        double dt = 1.0 / sampleRate, w = 2.0 * kPi * shellHz[k], s = kLn1000 / shellT60[k];
        double d = std::sqrt(w * w - s * s), e = std::exp(-s * dt), c = std::cos(d * dt), sn = std::sin(d * dt);
        shellProp_[k] = {e * (c + s / d * sn), e * sn / d, -e * w * w / d * sn, e * (c - s / d * sn)};
        shellOmega_[k] = w;
        shellQ_[k] = shellV_[k] = 0.0;
    }
    noiseLeft_ = 0;
    slapLeft_ = 0;
    for (auto& v : attacks_) v.on = false;
    noiseEnv_ = noiseHp_ = noiseLp_ = noisePrev_ = 0.0;
    noiseDecay_ = std::exp(-1.0 / (0.0015 * sampleRate));
}

void Engine::startAttack(int field, double level, double force, double contactMs) {
    double a = attackLevel.load(std::memory_order_relaxed);
    if (a <= 0.0 || force <= 0.0) return;
    Attack* v = &attacks_[0];
    for (auto& x : attacks_) {
        if (!x.on) { v = &x; break; }
        if (x.age > v->age) v = &x;   // all busy: replace the oldest
    }
    v->field = field;
    // Hertz-shortened contact, as in Field::strike: harder = shorter = brighter
    double tau = std::max(0.3, contactMs * std::pow(std::max(force, 0.05) / 0.7, -0.2)) * 1e-3;
    double f = std::clamp(force, 0.0, 1.0);
    // attack relative to the tone, an S-curve over force: almost none for a light tap (< 0.18),
    // rising steeply through moderate force, 1.5 from a firm hit (0.65) up (1 sits mid-range in
    // the recordings, 2 at their bright end)
    double u = std::clamp((f - 0.18) / (0.65 - 0.18), 0.0, 1.0), rel = 1.5 * u * u * (3.0 - 2.0 * u);
    *v = Attack{};
    v->on = true;
    v->click = a * level * 0.045 * f * rel;                      // 0.045 * f * rel: set by ear against the recordings
    v->clickDecay = std::exp(-1.0 / (tau * sr_));
    v->lpA = 1.0 - std::exp(-2.0 * kPi * std::clamp(9000.0 * (1.2e-3 / tau), 4000.0, 14000.0) / sr_);

    // shell modes: log-spaced 2-9 kHz, jittered per note so each field has its own shimmer
    // the landing edge of the contact (skin, then bone on steel) is much sharper than its
    // overall length: ~0.05 ms for a fingertip, sharper for harder hits
    const double dt = 1.0 / sr_, sd = 0.05e-3 * (tau / 1.2e-3);
    uint32_t h = 2654435761u * uint32_t(field + 1);
    for (int k = 0; k < kAttackModes; ++k) {
        h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
        double jitter = (h & 0xffff) / 65535.0 - 0.5;
        double hz = 2000.0 * std::pow(4.5, (k + 0.5 + 0.8 * jitter) / kAttackModes);
        double t60 = 0.45 * std::pow(2000.0 / hz, 0.9);          // ~0.45 s at 2 kHz, ~0.12 s at 9 kHz
        double w = 2.0 * kPi * hz, s = kLn1000 / t60, d = std::sqrt(w * w - s * s);
        double e = std::exp(-s * dt), c = std::cos(d * dt), sn = std::sin(d * dt);
        v->prop[k] = {e * (c + s / d * sn), e * sn / d, -e * w * w / d * sn, e * (c - s / d * sn)};
        v->w[k] = w;
        double contact = std::exp(-0.5 * (w * sd) * (w * sd));     // spectrum of the landing edge
        v->v[k] = a * level * 0.006 * f * rel * contact * w;      // impulse: displacement amplitude * w
    }
}

void Engine::setFieldPan(int field, float pan) {
    if (field >= 0 && field < int(pan_.size())) pan_[field] = std::clamp(pan, -1.0f, 1.0f);
}

void Engine::slap(double force) {
    // cavity: a push of air, peaking around a medium note's level
    if (guOsc_) guV_ += force * 0.55 / guNorm_;
    // shell knock: pushed over a 1.5 ms contact (see process); longer would dull the knock
    slapLen_ = std::max(2, int(0.0015 * sr_));
    slapLeft_ = slapLen_;
    slapForce_ = force;
    slapNorm_ = 0.0;
    for (int i = 0; i < slapLen_; ++i) {
        double u = (i + 0.5 - slapLen_ / 2.0) / (slapLen_ / 6.0);
        slapNorm_ += std::exp(-0.5 * u * u);
    }
    // skin on metal: ~4 ms of noise
    noiseLeft_ = int(0.004 * sr_);
    noiseEnv_ = force * 0.10;
    // every field rings faintly through the shell: a broad, slow, soft touch near its rim
    for (auto& f : fields_) f.strike(0.85, 0.0, force * 0.08, 5.0, 0.6);
}

// A resting finger mutes most of the field, not just the very centre: the
// fundamental's damping stays near full out to about half way and falls off
// towards the rim ((1 - r^4)^2 rather than the mode shape's (1 - r^2)^2), and
// every mode gets at least restFloor of the centre's damping wherever the
// finger is. Tuned by feel on the trackpad, not measured.
void Engine::updateRest(int field) {
    std::array<double, kModes> sigma{};
    Field& fd = fields_[field];
    double floor = std::clamp(static_cast<double>(restFloor.load(std::memory_order_relaxed)), 0.0, 1.0);
    double strength = restStrength.load(std::memory_order_relaxed);
    for (const auto& fg : fingers_) {
        if (!fg.on || fg.field != field) continue;
        double c = strength * fg.weight * fd.contactSigmaScale(fg.radius);
        auto phi = modeShapes(fg.x, fg.y, fg.radius);
        double rr = fg.x * fg.x + fg.y * fg.y + 0.5 * fg.radius * fg.radius;
        phi[0] = std::max(0.0, 1.0 - rr * rr);
        for (int n = 0; n < kModes; ++n) {
            double w = std::min(1.0, phi[n] * phi[n]);
            sigma[n] += c * (floor + (1.0 - floor) * w);
        }
    }
    fd.setRestSigma(sigma);
}

void Engine::handle(const Event& e) {
    switch (e.type) {
    case Event::Down: {
        if (e.field < 0 || e.field >= fieldCount()) return;
        Finger* slot = nullptr;
        for (auto& f : fingers_) if (f.on && f.id == e.finger) slot = &f;
        if (!slot) for (auto& f : fingers_) if (!f.on) { slot = &f; break; }
        fields_[e.field].strike(e.x, e.y, e.force, e.contactMs, e.radius);
        startAttack(e.field, fields_[e.field].outLevel(), e.force, e.contactMs);
        if (slot) {
            *slot = {true, e.finger, e.field, e.x, e.y, e.radius, 0, 0.0f};
            updateRest(e.field);
        }
        break;
    }
    case Event::Slap:
        slap(std::clamp(double(e.force), 0.0, 2.0));   // 0.8 is a normal slap; the Slap setting scales it
        break;
    case Event::Move:
        for (auto& f : fingers_) {
            if (f.on && f.id == e.finger) {
                f.x = e.x;
                f.y = e.y;
                f.radius = e.radius;
                updateRest(f.field);
            }
        }
        break;
    case Event::Up:
        for (auto& f : fingers_) {
            if (f.on && f.id == e.finger) {
                f.on = false;
                updateRest(f.field);
            }
        }
        break;
    }
}

void Engine::process(float* left, float* right, int frames) {
    Event e;
    while (queue_.pop(e)) handle(e);

    // resting fingers: mute only after the grace period, fading in over the ramp
    const double grace = restGraceMs * 1e-3 * engineSr_, ramp = std::max(1.0, restRampMs * 1e-3 * engineSr_);
    for (auto& fg : fingers_) {
        if (!fg.on) continue;
        fg.age += frames;
        float w = float(std::clamp((fg.age - grace) / ramp, 0.0, 1.0));
        if (w != fg.weight) {
            fg.weight = w;
            updateRest(fg.field);
        }
    }

    float tilt = radiationTilt.load(std::memory_order_relaxed);
    if (tilt != appliedTilt_) {
        for (auto& f : fields_) f.setRadiationTilt(tilt);
        if (guOsc_) setGuTilt(tilt);
        appliedTilt_ = tilt;
    }
    double scale = coupling.load(std::memory_order_relaxed);
    float g = gain.load(std::memory_order_relaxed);
    // pan gains for this block: constant power, normalised so a centred field is unchanged
    const double width = std::clamp(double(stereoWidth.load(std::memory_order_relaxed)), 0.0, 1.0);
    const size_t nf = fields_.size();
    double gainL[kMaxFields], gainR[kMaxFields];
    for (size_t j = 0; j < nf && j < size_t(kMaxFields); ++j) {
        double th = (pan_[j] * width + 1.0) * M_PI / 4.0;
        gainL[j] = std::sqrt(2.0) * std::cos(th);
        gainR[j] = std::sqrt(2.0) * std::sin(th);
    }
    for (int i = 0; i < frames; ++i) {
        // link forces from the current state of every field, before any field steps
        for (const auto& l : links_) {
            Field& src = fields_[l.src];
            if (src.asleep() || scale == 0.0) continue;
            Field& dst = fields_[l.dst];
            dst.wake();
            double k = l.k * scale, s1 = src.q(0), s2 = src.q(1);
            // one way: the lower note drives the upper one, nothing pushes back. The push-back
            // pumped the lower note parametrically (multi_field.py docstring).
            if (l.order == 3) dst.addForce(0, k * s1 * s2);   // drive from V = -k q1 q2 l1
            else dst.addForce(0, k * s1 * s1);                // drive from V = -k q1^2 l1
        }
        // Gu cavity: forces from the current state, stepped with the fields
        double fh = 0.0;
        if (guOn_) {
            for (size_t j = 0; j < fields_.size(); ++j) {
                Field& fd = fields_[j];
                if (fd.asleep()) continue;
                fd.addForce(0, guCouple_[j] * guQ_);
                fh += guCouple_[j] * fd.q(0);
            }
        }
        double s = 0.0, panL = 0.0, panR = 0.0;   // centred, and panned left and right
        if (guOsc_) {
            double q = guProp_[0] * guQ_ + guProp_[1] * guV_;
            double v = guProp_[2] * guQ_ + guProp_[3] * guV_ + fh / sr_;
            guQ_ = q;
            guV_ = v;
            s += gu_.out * guV_ * guNorm_;
        }
        double push = 0.0;   // Gaussian contact (no spectral nulls, unlike a raised cosine), integrating to slapForce_
        if (slapLeft_ > 0) {
            double u = (slapLen_ - slapLeft_ + 0.5 - slapLen_ / 2.0) / (slapLen_ / 6.0);
            push = slapForce_ * std::exp(-0.5 * u * u) / slapNorm_;
            --slapLeft_;
        }
        static const double shellAmp[kShellModes] = {0.30, 0.22, 0.16, 0.10, 0.06, 0.04};
        for (int k = 0; k < kShellModes; ++k) {
            const auto& m = shellProp_[k];
            double q = m[0] * shellQ_[k] + m[1] * shellV_[k], v = m[2] * shellQ_[k] + m[3] * shellV_[k];
            v += push * shellAmp[k] * shellOmega_[k];
            shellQ_[k] = q;
            shellV_[k] = v;
            s += v / shellOmega_[k];
        }
        for (auto& v : attacks_) {
            if (!v.on) continue;
            ++v.age;
            double sum = 0.0;
            if (v.click > 1e-8) {
                attackSeed_ = attackSeed_ * 1664525u + 1013904223u;
                double white = (attackSeed_ >> 8) / double(1 << 24) * 2.0 - 1.0;
                v.hp = 0.75 * (v.hp + white - v.prev);   // high-pass, ~2.2 kHz at 48 kHz
                v.prev = white;
                v.lp += v.lpA * (v.hp - v.lp);           // low-pass: brighter for shorter contacts
                sum += v.lp * v.click;
                v.click *= v.clickDecay;
            }
            for (int k = 0; k < kAttackModes; ++k) {
                const auto& m = v.prop[k];
                double q = m[0] * v.q[k] + m[1] * v.v[k], vel = m[2] * v.q[k] + m[3] * v.v[k];
                v.q[k] = q;
                v.v[k] = vel;
                sum += vel / v.w[k];
            }
            int fj = v.field < int(kMaxFields) ? v.field : 0;
            panL += sum * gainL[fj];
            panR += sum * gainR[fj];
            if (v.age > int(1.0 * sr_)) v.on = false;    // the slowest mode is ~60 dB down by 1 s
        }
        if (noiseLeft_ > 0) {
            noiseSeed_ = noiseSeed_ * 1664525u + 1013904223u;
            double white = (noiseSeed_ >> 8) / double(1 << 24) * 2.0 - 1.0;
            noiseHp_ = 0.95 * (noiseHp_ + white - noisePrev_);   // drop the lows
            noisePrev_ = white;
            noiseLp_ += 0.45 * (noiseHp_ - noiseLp_);            // and the harshest highs
            s += noiseLp_ * noiseEnv_;
            noiseEnv_ *= noiseDecay_;
            --noiseLeft_;
        }
        for (size_t j = 0; j < nf; ++j) {
            double v = fields_[j].tick();
            if (j < size_t(kMaxFields)) { panL += v * gainL[j]; panR += v * gainR[j]; }
        }
        float yl = static_cast<float>(s + panL) * g, yr = static_cast<float>(s + panR) * g;   // s: the centred parts
        if (limiter) {   // linked: one gain from the louder channel, so loud hits don't shift the image
            constexpr float ceiling = 0.95f;
            const size_t L = limDelay_.size();
            limDelay_[limPos_] = yl;
            limDelayR_[limPos_] = yr;
            limPos_ = (limPos_ + 1) % L;
            float peak = 0.0f;                       // loudest sample in the lookahead window
            for (size_t k = 0; k < L; ++k) peak = std::max(peak, std::max(std::fabs(limDelay_[k]), std::fabs(limDelayR_[k])));
            float target = peak > ceiling ? ceiling / peak : 1.0f;
            limGain_ += (target - limGain_) * (target < limGain_ ? limAttack_ : limRelease_);
            yl = std::clamp(limDelay_[limPos_] * limGain_, -1.0f, 1.0f);   // the oldest samples, level-matched;
            yr = std::clamp(limDelayR_[limPos_] * limGain_, -1.0f, 1.0f);  // the clamp is a rarely touched safety net
        }
        if (right) {
            left[i] = yl;
            right[i] = yr;
        } else {
            left[i] = 0.5f * (yl + yr);   // one buffer: a mono mix (identical to either channel at width 0)
        }
    }
    for (size_t i = 0; i < fields_.size() && i < size_t(kMaxFields); ++i) {
        double e = 0.0;
        for (int n = 0; n < kModes; ++n) {
            double a = fields_[i].modeLevel(n);
            modeLevels_[i * kModes + n].store(float(a), std::memory_order_relaxed);
            e += a * a;
        }
        levels_[i].store(float(std::sqrt(e)), std::memory_order_relaxed);
    }
}

}  // namespace morphion
