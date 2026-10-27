#include "score.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <sstream>

namespace morphion::score {

Layout layout(int scale, int key) {
    Layout L;
    int ding = 45 + std::clamp(key, 0, 11);
    const ScaleDef& sc = kScales[std::clamp(scale, 0, kScaleCount - 1)];
    static const int zigzag[8] = {7, 6, 8, 3, 5, 0, 2, 1};
    L.midi[4] = ding;
    for (int i = 0; i < 8; ++i) L.midi[zigzag[i]] = ding + sc.semis[i];
    for (int i = 0; i < L.count; ++i) L.freq[i] = 440.0 * std::pow(2.0, (L.midi[i] - 69) / 12.0);
    return L;
}

std::string noteName(int midi) {
    return std::string(kNoteNames[midi % 12]) + std::to_string(midi / 12 - 1);
}

std::string noteName(int midi, int key) {
    // minor keys with sharps in their signature: A (none), B, C#, E, F#
    static const bool sharps[12] = {true, false, true, false, true, false, false, true, false, true, false, false};
    static const char* sharpNames[12] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
    static const char* flatNames[12] = {"C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"};
    const char* const* names = sharps[std::clamp(key, 0, 11)] ? sharpNames : flatNames;
    return std::string(names[midi % 12]) + std::to_string(midi / 12 - 1);
}

namespace {

// "C#", "Db", "Cs": pitch class 0-11, or -1. Consumes the letter and any accidental.
int pitchClass(const std::string& s, size_t& i) {
    static const int base[7] = {9, 11, 0, 2, 4, 5, 7};   // A B C D E F G
    if (i >= s.size()) return -1;
    char c = char(std::toupper(static_cast<unsigned char>(s[i])));
    if (c < 'A' || c > 'G') return -1;
    int pc = base[c - 'A'];
    ++i;
    if (i < s.size() && (s[i] == '#' || s[i] == 's')) { pc += 1; ++i; }
    else if (i < s.size() && s[i] == 'b') { pc += 11; ++i; }
    return pc % 12;
}

int noteMidi(const std::string& s) {
    size_t i = 0;
    int pc = pitchClass(s, i);
    if (pc < 0 || i >= s.size()) return -1;
    char* end = nullptr;
    long oct = std::strtol(s.c_str() + i, &end, 10);
    if (*end || end == s.c_str() + i) return -1;
    // B#3 is C4 and Cb4 is B3: octave numbers follow the letter
    char letter = char(std::toupper(static_cast<unsigned char>(s[0])));
    int shift = (letter == 'B' && pc == 0) ? 12 : (letter == 'C' && pc == 11) ? -12 : 0;
    return int((oct + 1) * 12 + pc + shift);
}

bool number(const std::string& s, double& v) {
    char* end = nullptr;
    v = std::strtod(s.c_str(), &end);
    return !s.empty() && *end == '\0' && std::isfinite(v);
}

std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n"), b = s.find_last_not_of(" \t\r\n");
    return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

std::string stripComment(const std::string& s) {
    for (size_t i = 0; i < s.size(); ++i)
        if (s[i] == '#' && (i == 0 || s[i - 1] == ' ' || s[i - 1] == '\t')) return s.substr(0, i);
    return s;
}

// 0.3 < 0.3.1 < 0.10; missing parts count as 0
int compareVersions(const std::string& a, const std::string& b) {
    std::istringstream sa(a), sb(b);
    std::string pa, pb;
    while (true) {
        bool ha = bool(std::getline(sa, pa, '.')), hb = bool(std::getline(sb, pb, '.'));
        if (!ha && !hb) return 0;
        long x = ha ? std::atol(pa.c_str()) : 0, y = hb ? std::atol(pb.c_str()) : 0;
        if (x != y) return x < y ? -1 : 1;
    }
}

// shortest text that reads back as exactly this float
std::string fmt(float v) {
    char b[32];
    auto r = std::to_chars(b, b + sizeof b, v);
    return std::string(b, r.ptr);
}

float forceToContactMs(float force) { return 1.6f - 0.7f * (force - 0.1f) / 0.9f; }   // as the app maps it

const char* kLiveKeys[] = {"gain", "swell", "tilt", "mute", "mute_floor", "stereo", "attack"};

}  // namespace

bool applySetting(Engine& e, const std::string& key, float v) {
    if (key == "gain") e.gain = v;
    else if (key == "swell") e.coupling = v;
    else if (key == "tilt") e.radiationTilt = v;
    else if (key == "mute") e.restStrength = v;
    else if (key == "mute_floor") e.restFloor = v;
    else if (key == "stereo") e.stereoWidth = v;
    else if (key == "attack") e.attackLevel = v;
    else return false;
    return true;
}

bool parse(const std::string& text, Piece& out, std::string& error) {
    Piece p;
    std::istringstream in(text);
    std::string raw;
    int lineNo = 0;
    bool sawEvent = false;
    int nextTapFinger = 1 << 30;   // short-form taps get ids no recording uses
    Layout L = layout(p.settings.scale, p.settings.key);
    bool layoutStale = false;

    auto fail = [&](const std::string& msg) {
        error = "line " + std::to_string(lineNo) + ": " + msg;
        if (!p.version.empty() && compareVersions(p.version, MORPHION_VERSION) > 0)
            error += " (the file was made with morphion " + p.version + ", this is " MORPHION_VERSION ")";
        return false;
    };

    while (std::getline(in, raw)) {
        ++lineNo;
        if (p.version.empty()) {
            std::string t = trim(raw);
            if (t.empty()) continue;
            if (t.rfind("# morphion ", 0) != 0) {
                error = "not a morphion score: the first line should be '# morphion <version>'";
                return false;
            }
            p.version = trim(t.substr(11));
            if (p.version.empty()) return fail("no version after '# morphion'");
            continue;
        }
        std::string line = trim(stripComment(raw));
        if (line.empty()) continue;

        // header: key = value
        size_t eq = line.find('=');
        if (eq != std::string::npos) {
            if (sawEvent) return fail("settings go before the first event; use 'set' to change a live setting");
            std::string key = trim(line.substr(0, eq)), val = trim(line.substr(eq + 1));
            double v = 0;
            Settings& s = p.settings;
            if (key == "scale") {
                int i = 0;
                while (i < kScaleCount && val != kScales[i].name) ++i;
                if (i == kScaleCount) return fail("unknown scale '" + val + "'");
                s.scale = i;
            } else if (key == "key") {
                size_t k = 0;
                int pc = pitchClass(val, k);
                if (pc < 0 || k != val.size()) return fail("unknown key '" + val + "'");
                s.key = (pc - 9 + 12) % 12;   // kKeys starts at A
            } else if (key == "reverb") {
                int i = 0;
                while (i < kReverbCount && val != kReverbs[i].name) ++i;
                if (i == kReverbCount) {
                    std::string names;
                    for (const auto& r : kReverbs) names += (names.empty() ? "" : ", ") + std::string(r.name);
                    return fail("unknown reverb '" + val + "' (" + names + ")");
                }
                s.reverb = i;
            } else {
                static const char* numeric[] = {"gain", "sustain", "swell", "tilt", "gu", "gu_hz", "gap", "gap_2x",
                                                "mute", "mute_floor", "stereo", "attack"};
                if (std::find(std::begin(numeric), std::end(numeric), key) == std::end(numeric))
                    return fail("unknown setting '" + key + "'");
                if (!number(val, v)) return fail("'" + key + "' needs a number");
                if (key == "gain") s.gain = float(v);
                else if (key == "sustain") s.sustain = float(v);
                else if (key == "swell") s.swell = float(v);
                else if (key == "tilt") s.tilt = float(v);
                else if (key == "gu") s.gu = float(v);
                else if (key == "gu_hz") s.guHz = v;
                else if (key == "gap") s.gap = v;
                else if (key == "gap_2x") s.gap2x = v;
                else if (key == "mute") s.mute = float(v);
                else if (key == "mute_floor") s.muteFloor = float(v);
                else if (key == "stereo") s.stereo = float(v);
                else if (key == "attack") s.attack = float(v);
                else return fail("unknown setting '" + key + "'");
            }
            layoutStale = true;
            continue;
        }

        // event: TIME WHAT ...
        if (layoutStale) {
            L = layout(p.settings.scale, p.settings.key);
            layoutStale = false;
        }
        sawEvent = true;
        std::istringstream ls(line);
        std::vector<std::string> tok;
        for (std::string t; ls >> t;) tok.push_back(t);
        double t = 0;
        if (!number(tok[0], t) || t < 0) return fail("expected a time in seconds, got '" + tok[0] + "'");
        if (tok.size() < 2) return fail("nothing after the time");
        Line ln;
        ln.sample = std::llround(t * kRate);
        ln.lineNo = lineNo;

        auto fieldOf = [&](const std::string& name, int& field) {
            int m = noteMidi(name);
            for (int i = 0; i < L.count; ++i)
                if (L.midi[i] == m) { field = i; return true; }
            return false;
        };
        auto notOnPan = [&](const std::string& name) {
            std::vector<int> m(L.midi, L.midi + L.count);
            std::sort(m.begin(), m.end());
            std::string list;
            for (int x : m) list += (list.empty() ? "" : " ") + noteName(x, p.settings.key);
            return fail("'" + name + "' is not a note of this pan (" + kKeys[p.settings.key] + " " +
                        kScales[p.settings.scale].name + ": " + list + ")");
        };
        auto num = [&](size_t i, double& v, const char* what) {
            if (i >= tok.size() || !number(tok[i], v)) {
                fail(std::string("expected ") + what + (i < tok.size() ? ", got '" + tok[i] + "'" : ""));
                return false;
            }
            return true;
        };
        // trailing options: @x,y  rRADIUS  cCONTACT_MS  hold MS
        double hold = -1;
        bool contactSet = false;
        auto options = [&](size_t i, bool allowHold, bool allowContact) {
            for (; i < tok.size(); ++i) {
                const std::string& o = tok[i];
                double a = 0, b = 0;
                if (o[0] == '@') {
                    size_t c = o.find(',');
                    if (c == std::string::npos || !number(o.substr(1, c - 1), a) || !number(o.substr(c + 1), b))
                        return fail("a spot is @x,y, got '" + o + "'");
                    ln.x = float(a);
                    ln.y = float(b);
                } else if (o[0] == 'r' && number(o.substr(1), a)) {
                    ln.radius = float(a);
                } else if (allowContact && o[0] == 'c' && number(o.substr(1), a)) {
                    ln.contactMs = float(a);
                    contactSet = true;
                } else if (allowHold && o == "hold") {
                    if (!num(i + 1, hold, "a hold time in ms")) return false;
                    ++i;
                } else {
                    return fail("unknown option '" + o + "'");
                }
            }
            return true;
        };

        const std::string& what = tok[1];
        double v = 0;
        if (what == "slap") {
            if (!num(2, v, "a slap force")) return false;
            if (tok.size() > 3) return fail("unknown option '" + tok[3] + "'");
            ln.kind = Line::Slap;
            ln.force = float(v);
            p.lines.push_back(ln);
        } else if (what == "set") {
            if (tok.size() != 4) return fail("set needs a setting and a value");
            if (std::find(std::begin(kLiveKeys), std::end(kLiveKeys), tok[2]) == std::end(kLiveKeys))
                return fail("'" + tok[2] + "' can't change during a piece; set it in the header");
            if (!num(3, v, "a value")) return false;
            ln.kind = Line::Set;
            ln.key = tok[2];
            ln.value = float(v);
            p.lines.push_back(ln);
        } else if (what == "down" || what == "move" || what == "up") {
            double id = 0;
            if (!num(2, id, "a finger id") || id != std::floor(id)) return fail("expected a whole-number finger id");
            ln.finger = int(id);
            if (what == "up") {
                if (tok.size() > 3) return fail("unknown option '" + tok[3] + "'");
                ln.kind = Line::Up;
            } else if (what == "move") {
                ln.kind = Line::Move;
                if (!options(3, false, false)) return false;
            } else {
                ln.kind = Line::Down;
                if (tok.size() < 5) return fail("down needs a finger id, a note and a force");
                if (!fieldOf(tok[3], ln.field)) return notOnPan(tok[3]);
                if (!num(4, v, "a force")) return false;
                ln.force = float(v);
                if (!options(5, false, true)) return false;
                if (!contactSet) ln.contactMs = forceToContactMs(ln.force);
            }
            p.lines.push_back(ln);
        } else {
            // short form: a tap
            if (!fieldOf(what, ln.field)) {
                if (noteMidi(what) < 0) return fail("unknown event '" + what + "'");
                return notOnPan(what);
            }
            if (!num(2, v, "a force")) return false;
            ln.kind = Line::Down;
            ln.force = float(v);
            ln.finger = nextTapFinger++;
            if (!options(3, true, true)) return false;
            if (!contactSet) ln.contactMs = forceToContactMs(ln.force);
            p.lines.push_back(ln);
            Line up = ln;
            up.kind = Line::Up;
            up.sample = ln.sample + (hold > 0 ? std::llround(hold * 1e-3 * kRate) : 0);
            p.lines.push_back(up);
        }
    }
    if (p.version.empty()) {
        error = "empty file: the first line should be '# morphion <version>'";
        return false;
    }
    std::stable_sort(p.lines.begin(), p.lines.end(), [](const Line& a, const Line& b) { return a.sample < b.sample; });
    out = std::move(p);
    return true;
}

std::string write(const Piece& piece) {
    const Settings& s = piece.settings;
    Layout L = layout(s.scale, s.key);
    std::string o = "# morphion " MORPHION_VERSION "\n";
    o += std::string("scale = ") + kScales[s.scale].name + "\nkey = " + kKeys[s.key] + "\n";
    auto kv = [&](const char* k, const std::string& v) { o += std::string(k) + " = " + v + "\n"; };
    auto dbl = [](double v) { char b[32]; auto r = std::to_chars(b, b + sizeof b, v); return std::string(b, r.ptr); };
    kv("gain", fmt(s.gain)); kv("sustain", fmt(s.sustain)); kv("swell", fmt(s.swell)); kv("tilt", fmt(s.tilt));
    kv("gu", fmt(s.gu)); kv("gu_hz", dbl(s.guHz)); kv("gap", dbl(s.gap)); kv("gap_2x", dbl(s.gap2x));
    kv("mute", fmt(s.mute)); kv("mute_floor", fmt(s.muteFloor)); kv("stereo", fmt(s.stereo)); kv("attack", fmt(s.attack));
    kv("reverb", kReverbs[s.reverb].name);
    o += "\n";
    // fingers renumbered from 1, each down taking the smallest id not held by a finger still down
    std::vector<std::pair<int, int>> held;   // (id in the piece, id written)
    auto idFor = [&](int id, bool down) {
        for (auto& h : held) if (h.first == id) return h.second;
        if (!down) return id;
        int w = 1;
        while (std::any_of(held.begin(), held.end(), [&](const auto& h) { return h.second == w; })) ++w;
        held.push_back({id, w});
        return w;
    };
    char t[32];
    for (const Line& line : piece.lines) {
        Line l = line;
        if (l.kind == Line::Down || l.kind == Line::Move || l.kind == Line::Up) l.finger = idFor(l.finger, l.kind == Line::Down);
        if (l.kind == Line::Up)
            held.erase(std::remove_if(held.begin(), held.end(), [&](const auto& h) { return h.first == line.finger; }), held.end());
        std::snprintf(t, sizeof t, "%.6f ", double(l.sample) / kRate);
        o += t;
        switch (l.kind) {
        case Line::Down:
            o += "down " + std::to_string(l.finger) + " " + noteName(L.midi[l.field], s.key) + " " + fmt(l.force) + " @" +
                 fmt(l.x) + "," + fmt(l.y) + " r" + fmt(l.radius) + " c" + fmt(l.contactMs);
            break;
        case Line::Move: o += "move " + std::to_string(l.finger) + " @" + fmt(l.x) + "," + fmt(l.y) + " r" + fmt(l.radius); break;
        case Line::Up: o += "up " + std::to_string(l.finger); break;
        case Line::Slap: o += "slap " + fmt(l.force); break;
        case Line::Set: o += "set " + l.key + " " + fmt(l.value); break;
        }
        o += "\n";
    }
    return o;
}

void configure(Engine& engine, const Piece& piece) {
    const Settings& s = piece.settings;
    Layout L = layout(s.scale, s.key);
    CouplingParams cp;
    cp.gapHz = s.gap;
    cp.gap2xHz = s.gap2x;
    GuParams gp;
    gp.couple = s.gu;
    gp.f = s.guHz;
    FieldParams fp;
    fp.decayScale = s.sustain;
    engine.reverb = s.reverb;
    engine.configure(kRate, std::vector<double>(L.freq, L.freq + L.count), fp, cp, gp);
    for (int i = 0; i < L.count; ++i) engine.setFieldPan(i, float(i % 3 - 1));
    engine.limiter = true;
    engine.gain = s.gain;
    engine.coupling = s.swell;
    engine.radiationTilt = s.tilt;
    engine.restStrength = s.mute;
    engine.restFloor = s.muteFloor;
    engine.stereoWidth = s.stereo;
    engine.attackLevel = s.attack;
}

void Player::feed() {
    const int64_t at = engine_.nextBlockSample();
    while (next_ < piece_.lines.size() && piece_.lines[next_].sample <= at) {
        const Line& l = piece_.lines[next_++];
        bool ok = true;
        switch (l.kind) {
        case Line::Down: ok = engine_.push({Event::Down, l.finger, l.field, l.x, l.y, l.force, l.contactMs, l.radius}); break;
        case Line::Move: ok = engine_.push({Event::Move, l.finger, 0, l.x, l.y, 0, 0, l.radius}); break;
        case Line::Up: ok = engine_.push({Event::Up, l.finger, 0, 0, 0, 0, 0, 0}); break;
        case Line::Slap: ok = engine_.push({Event::Slap, 0, 0, 0, 0, l.force, 0, 0}); break;
        case Line::Set: applySetting(engine_, l.key, l.value); break;
        }
        if (!ok) ++dropped_;
    }
}

void Player::process(float* left, float* right, int frames) {
    // hand the engine one block's worth at a time, so each block's events go in just before it
    for (int done = 0; done < frames;) {
        int intoBlock = int(pos_ % Engine::kBlock);
        if (intoBlock == 0) feed();
        int n = std::min(frames - done, Engine::kBlock - intoBlock);
        engine_.process(left + done, right ? right + done : nullptr, n);
        pos_ += n;
        done += n;
    }
}

}  // namespace morphion::score
