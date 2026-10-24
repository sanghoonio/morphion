// Render one strike through the C++ engine to a WAV, to check it against
// scripts/one_field.py without the app.
//
//   make -C engine && engine/build/render_test out.wav [x y force contact_ms radius note_hz]
//   engine/build/render_test --kurd out.wav [field seconds]
//   engine/build/render_test --slap out.wav [alone|phrase]
//
// The first form renders one Field (compare with one_field.py). --kurd renders
// one strike on the D Kurd 9 layout through the Engine with cross-field links
// (compare with multi_field.py --check); field is the grid index, default 4 (D3).
// Both write the raw output peak-normalised to 0.9, no limiter.

#include "morphion.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static void writeWav(const char* path, const std::vector<float>& y, int sr) {
    FILE* f = std::fopen(path, "wb");
    if (!f) { std::perror(path); std::exit(1); }
    uint32_t dataBytes = static_cast<uint32_t>(y.size() * 2);
    auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f); u32(36 + dataBytes); std::fwrite("WAVE", 1, 4, f);
    std::fwrite("fmt ", 1, 4, f); u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16);
    std::fwrite("data", 1, 4, f); u32(dataBytes);
    for (float s : y) {
        int16_t v = static_cast<int16_t>(std::lround(std::fmax(-1.0, std::fmin(1.0, s)) * 32767));
        std::fwrite(&v, 2, 1, f);
    }
    std::fclose(f);
}

static void normaliseAndWrite(std::vector<float>& out, const char* path, int sr) {
    double peak = 0.0;
    for (float s : out) peak = std::fmax(peak, std::fabs(s));
    for (auto& s : out) s = static_cast<float>(s * 0.9 / peak);
    writeWav(path, out, sr);
}

static int kurd(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: %s --kurd out.wav [field seconds]\n", argv[0]); return 1; }
    int field = argc > 3 ? std::atoi(argv[3]) : 4;
    double seconds = argc > 4 ? std::atof(argv[4]) : 2.5;
    const int sr = 48000;
    const std::vector<double> grid = {349.23, 440.00, 392.00, 293.66, 146.83, 329.63, 233.08, 220.00, 261.63};

    morphion::Engine engine;
    engine.configure(sr, grid, morphion::FieldParams{});
    engine.limiter = false;
    engine.gain = 1.0f;
    engine.restStrength = 0.0f;   // multi_field.py has no resting finger
    for (const auto& l : engine.links())
        std::printf("link %d -> %d (%dx), listener now %.3f Hz\n", l.src, l.dst, l.order, engine.fieldFreq(l.dst));

    engine.push({morphion::Event::Down, 1, field, 0.0f, 0.05f, 0.7f, 1.5f, 0.2f});
    engine.push({morphion::Event::Up, 1, field, 0.0f, 0.05f, 0.0f, 0.0f, 0.2f});
    std::vector<float> out(static_cast<size_t>(seconds * sr));
    const int block = 128;
    for (size_t i = 0; i < out.size(); i += block) {
        int n = static_cast<int>(std::min<size_t>(block, out.size() - i));
        engine.process(out.data() + i, nullptr, n);
    }
    normaliseAndWrite(out, argv[2], sr);
    std::printf("wrote %s (field %d struck, %.1f s)\n", argv[2], field, seconds);
    return 0;
}

// A slap alone, or a short phrase mixing notes and slaps, through the full engine
// (limiter on, as in the app) on the D Kurd grid.
static int slapDemo(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: %s --slap out.wav [alone|phrase]\n", argv[0]); return 1; }
    bool phrase = argc > 3 && std::string(argv[3]) == "phrase";
    const int sr = 48000;
    const std::vector<double> grid = {349.23, 440.00, 392.00, 293.66, 146.83, 329.63, 233.08, 220.00, 261.63};
    morphion::Engine engine;
    engine.configure(sr, grid, morphion::FieldParams{});
    struct Hit { double t; int field; float force; };   // field -1 = slap
    std::vector<Hit> hits = phrase
        ? std::vector<Hit>{{0.0, 4, 0.8f}, {0.45, -1, 0.8f}, {0.75, 7, 0.6f}, {1.05, -1, 0.6f}, {1.2, -1, 0.8f},
                           {1.5, 3, 0.6f}, {1.8, -1, 0.8f}, {2.1, 4, 0.7f}, {2.4, 1, 0.5f}, {2.7, -1, 0.9f}}
        : std::vector<Hit>{{0.05, -1, 0.8f}};
    double seconds = phrase ? 4.5 : 1.5;
    std::vector<float> out(size_t(seconds * sr)), buf(64);
    size_t next = 0;
    for (size_t n = 0; n < out.size(); n += 64) {
        while (next < hits.size() && hits[next].t * sr <= n) {
            const Hit& h = hits[next++];
            if (h.field < 0) engine.push({morphion::Event::Slap, 0, 0, 0, 0, h.force, 0, 0});
            else {
                engine.push({morphion::Event::Down, int(next), h.field, 0.15f, 0.1f, h.force, 1.2f, 0.12f});
                engine.push({morphion::Event::Up, int(next), 0, 0, 0, 0, 0, 0});
            }
        }
        engine.process(buf.data(), nullptr, 64);
        std::copy(buf.begin(), buf.begin() + std::min<size_t>(64, out.size() - n), out.begin() + n);
    }
    writeWav(argv[2], out, sr);   // app levels, not normalised
    std::printf("wrote %s\n", argv[2]);
    return 0;
}

int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) == "--kurd") return kurd(argc, argv);
    if (argc > 1 && std::string(argv[1]) == "--slap") return slapDemo(argc, argv);
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s out.wav [x y force contact_ms radius note_hz]\n", argv[0]);
        return 1;
    }
    auto arg = [&](int i, double d) { return argc > i ? std::atof(argv[i]) : d; };
    double x = arg(2, 0.2), y = arg(3, 0.1), force = arg(4, 0.7), contactMs = arg(5, 1.2),
           radius = arg(6, 0.15), f0 = arg(7, 293.66);
    const int sr = 48000;

    morphion::FieldParams p;
    p.f0 = f0;
    morphion::Field field;
    field.configure(p, sr);
    field.strike(x, y, force, contactMs, radius);

    std::vector<float> out(static_cast<size_t>(4.0 * sr));
    for (auto& s : out) s = static_cast<float>(field.tick());
    normaliseAndWrite(out, argv[1], sr);
    std::printf("wrote %s (%.0f Hz, strike %.2f,%.2f force %.2f contact %.1f ms radius %.2f)\n",
                argv[1], f0, x, y, force, contactMs, radius);
}
