// morphion trackpad prototype: play the handpan engine from the Mac trackpad.
//
//   make -C mac && open mac/build/morphion.app
//   mac/build/morphion [--layout grid|single] [--probe] [--mute 0.6] [--mute-floor 0.15]
//            [--size-soft 0.2] [--size-hard 1.3] [--force-curve 1.15] [--major-ref 10]
//            [--gain 1.0] [--buffer 128]
//            [--coupling 1.0] [--gap 1.3] [--gap-2x 0.45] [--tilt -0.1]
//            [--gu 0.2] [--gu-hz 80]
//   mac/build/morphion --snapshot DIR   # draw the canvas to DIR/idle.png and playing.png, exit
//
// Play (or Return) starts playing: the cursor is frozen and hidden so taps land here.
// Esc stops, Space slaps the shell, the gear opens settings. Touches only sound while playing.
//
// Per-finger contact data comes from the private MultitouchSupport framework,
// loaded with dlopen. Its struct layout is community reverse engineering;
// --probe prints raw values to check it and to calibrate --size-soft,
// --size-hard and --major-ref.
//
// Strike strength comes from the touch's peak size over its first frames: a
// harder hit flattens the finger more. Harder also means a shorter contact
// (brighter), as on a real pan, so a big touch no longer reads as a soft thumb.

#import <Cocoa/Cocoa.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dlfcn.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "../engine/morphion.h"

// ---------------------------------------------------------------- MultitouchSupport

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;          // 1 start, 2 hover, 3 make touch, 4 touching, 5 break touch, 6 linger, 7 out of range
    int fingerId;
    int handId;
    MTVector normalized; // 0..1, y up
    float size;          // total signal ("zTotal"); grows with contact area and pressure
    int unknown1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int unknown2[2];
    float density;
} MTTouch;
static_assert(sizeof(MTTouch) == 96, "MTTouch layout");

typedef void* MTDeviceRef;
typedef int (*MTFrameCallback)(MTDeviceRef, const MTTouch*, int, double, int);

static MTDeviceRef (*MTDeviceCreateDefault)(void);
static void (*MTRegisterContactFrameCallback)(MTDeviceRef, MTFrameCallback);
static void (*MTUnregisterContactFrameCallback)(MTDeviceRef, MTFrameCallback);
static int (*MTDeviceStart)(MTDeviceRef, int);
static int (*MTDeviceStop)(MTDeviceRef);

static bool loadMultitouch() {
    void* h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!h) { std::fprintf(stderr, "dlopen MultitouchSupport failed: %s\n", dlerror()); return false; }
    MTDeviceCreateDefault = (MTDeviceRef(*)(void))dlsym(h, "MTDeviceCreateDefault");
    MTRegisterContactFrameCallback = (void (*)(MTDeviceRef, MTFrameCallback))dlsym(h, "MTRegisterContactFrameCallback");
    MTUnregisterContactFrameCallback = (void (*)(MTDeviceRef, MTFrameCallback))dlsym(h, "MTUnregisterContactFrameCallback");
    MTDeviceStart = (int (*)(MTDeviceRef, int))dlsym(h, "MTDeviceStart");
    MTDeviceStop = (int (*)(MTDeviceRef))dlsym(h, "MTDeviceStop");
    if (!MTDeviceCreateDefault || !MTRegisterContactFrameCallback || !MTDeviceStart || !MTDeviceStop) {
        std::fprintf(stderr, "MultitouchSupport symbols missing\n");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- config, settings and layout

// Fixed tuning and calibration (command-line only).
struct Config {
    bool probe = false;
    float muteFloor = 0.15f; // resting-finger damping anywhere on a field, fraction of the centre's
    float sizeSoft = 0.2f;   // peak touch size of the softest tap (force 0.1)
    float forceCurve = 1.15f; // >1: more room at the soft end, <1: reaches hard sooner
    float softMs = 1.6f;     // contact time passed to the engine for the softest tap
    float hardMs = 0.9f;     // ... and for the hardest (engine adds Hertz scaling on top)
    float majorRef = 10.0f;  // major axis of a typical fingertip (sets contact radius)
    int buffer = 128;
    double gap = 1.3;        // Hz below the source's 3rd harmonic that a listener is tuned to
    double gap2x = 0.45;     // same for 2nd-harmonic pairs
    double guHz = 80.0;      // cavity pitch: ~85 free, ~73 on the lap
};
static Config g_cfg;

// User settings: the settings pane edits these and they persist between launches
// (NSUserDefaults, domain "morphion": the bundle identifier and the bare executable's
// name agree, so the app and the build/morphion symlink share them). Command-line flags
// override them for one run.
struct Settings {
    int scale = 0;           // index into kScales
    int key = 5;             // index into kKeys: D
    bool single = false;     // one big field instead of the grid
    float gain = 1.0f;       // output volume
    float sizeHard = 1.3f;   // peak touch size of a full-force tap: lower = lighter touch reaches full force
    float mute = 0.6f;       // resting-finger damping relative to strike contact damping
    float coupling = 1.0f;   // scales every cross-field link (the sympathetic swell)
    float tilt = -0.1f;      // loudness balance: negative favours low notes
    float gu = 0.2f;         // Gu cavity coupling, 0 = off
    float sustain = 1.0f;    // multiplies every decay time (1 = the measured handpan values)
};
static Settings g_set;

// Scales: a ding plus 8 notes, as semitones above the ding. Pygmy, Integral and the
// gong-mode pentatonic are built from their usual definitions, not maker charts.
struct ScaleDef { const char* name; int semis[8]; };
static const ScaleDef kScales[] = {
    {"Kurd", {7, 8, 10, 12, 14, 15, 17, 19}},
    {"Celtic Minor", {7, 10, 12, 14, 15, 17, 19, 22}},
    {"Hijaz", {7, 8, 11, 12, 14, 15, 17, 19}},
    {"Pygmy", {7, 10, 12, 14, 15, 19, 22, 24}},
    {"Integral", {7, 8, 10, 12, 14, 15, 19, 22}},
    {"Chinese Pentatonic", {7, 9, 12, 14, 16, 19, 21, 24}},
};
constexpr int kScaleCount = int(sizeof(kScales) / sizeof(kScales[0]));
// The ding's pitch: A2 up to G#3 (MIDI 45-56).
static const char* kKeys[12] = {"A", "Bb", "B", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab"};
static const char* kNoteNames[12] = {"C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"};

// The playable fields for the current settings. Grid fields are numbered row * 3 + col,
// rows top to bottom; the ding is the centre and the 8 others zigzag upwards from the
// bottom middle (lowest) to the top middle (highest), as on the D Kurd layout.
struct LayoutTable {
    int count = 9;
    int ding = 4;            // -1 in the single layout
    double freq[9] = {};
    char name[9][6] = {};
};
static LayoutTable g_layout;
static std::mutex g_layoutMutex;          // the touch thread reads names for --probe output
static std::atomic<bool> g_single{false}; // read by the touch thread
static std::atomic<float> g_sizeHard{1.3f};

static void noteName(int midi, char* out) {
    std::snprintf(out, 6, "%s%d", kNoteNames[midi % 12], midi / 12 - 1);
}

static void buildLayout() {
    LayoutTable L;
    int ding = 45 + std::clamp(g_set.key, 0, 11);
    const ScaleDef& sc = kScales[std::clamp(g_set.scale, 0, kScaleCount - 1)];
    auto hz = [](int m) { return 440.0 * std::pow(2.0, (m - 69) / 12.0); };
    if (g_set.single) {
        L.count = 1;
        L.ding = -1;
        L.freq[0] = hz(ding + 12);
        noteName(ding + 12, L.name[0]);
    } else {
        static const int zigzag[8] = {7, 6, 8, 3, 5, 0, 2, 1};
        L.freq[4] = hz(ding);
        noteName(ding, L.name[4]);
        for (int i = 0; i < 8; ++i) {
            L.freq[zigzag[i]] = hz(ding + sc.semis[i]);
            noteName(ding + sc.semis[i], L.name[zigzag[i]]);
        }
    }
    std::lock_guard<std::mutex> lock(g_layoutMutex);
    g_layout = L;
    g_single = g_set.single;
}

static NSString* layoutTitle() {
    return [NSString stringWithFormat:@"morphion: %s %s%s", kKeys[g_set.key], kScales[g_set.scale].name,
                                      g_set.single ? " (single note)" : ""];
}

static void loadSettings() {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    if (![d objectForKey:@"scale"]) return;
    g_set.scale = std::clamp(int([d integerForKey:@"scale"]), 0, kScaleCount - 1);
    g_set.key = std::clamp(int([d integerForKey:@"key"]), 0, 11);
    g_set.single = [d boolForKey:@"single"];
    g_set.gain = [d floatForKey:@"gain"];
    g_set.sizeHard = [d floatForKey:@"sizeHard"];
    g_set.mute = [d floatForKey:@"mute"];
    g_set.coupling = [d floatForKey:@"coupling"];
    g_set.tilt = [d floatForKey:@"tilt"];
    g_set.gu = [d floatForKey:@"gu"];
    g_set.sustain = [d objectForKey:@"sustain"] ? [d floatForKey:@"sustain"] : 1.0f;
}

static void saveSettings() {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    [d setInteger:g_set.scale forKey:@"scale"];
    [d setInteger:g_set.key forKey:@"key"];
    [d setBool:g_set.single forKey:@"single"];
    [d setFloat:g_set.gain forKey:@"gain"];
    [d setFloat:g_set.sizeHard forKey:@"sizeHard"];
    [d setFloat:g_set.mute forKey:@"mute"];
    [d setFloat:g_set.coupling forKey:@"coupling"];
    [d setFloat:g_set.tilt forKey:@"tilt"];
    [d setFloat:g_set.gu forKey:@"gu"];
    [d setFloat:g_set.sustain forKey:@"sustain"];
}

static int fieldAt(float nx, float ny) {
    if (g_single.load()) return 0;
    int col = std::clamp(int(nx * 3), 0, 2);
    int row = std::clamp(int((1 - ny) * 3), 0, 2);
    return row * 3 + col;
}

// Position in a field's own coordinates: [-1, 1] across the cell, x along the long (horizontal) axis.
static void localIn(int field, float nx, float ny, float& fx, float& fy) {
    if (g_single.load()) { fx = nx * 2 - 1; fy = ny * 2 - 1; return; }
    int col = field % 3, row = field / 3;
    fx = (nx * 3 - col) * 2 - 1;
    fy = (ny * 3 - (2 - row)) * 2 - 1;
}

// ---------------------------------------------------------------- shared state

static morphion::Engine g_engine;

static const CGFloat kTitlebar = 52;   // the content runs under the transparent title bar (with toolbar)

static std::atomic<bool> g_captured{false};

struct UiTouch { float nx, ny, major, minor, angle, size; int state; };
static std::mutex g_uiMutex;
static std::vector<UiTouch> g_uiTouches;
static std::array<std::atomic<double>, 9> g_flashTime;
static std::atomic<double> g_slapTime{0.0};   // for a brief flash of the whole pan
static std::array<std::atomic<float>, 9> g_flashForce;

// ---------------------------------------------------------------- touch handling (MT thread)

struct Track {
    bool used = false, seen = false, down = false;
    int id = 0, field = 0, state = 0, frames = 0;
    float peakSize = 0.0f;   // largest size seen before contact: hard hits are biggest on the first frame
};
static std::array<Track, 32> g_tracks;

static Track* findTrack(int id) {
    for (auto& t : g_tracks) if (t.used && t.id == id) return &t;
    for (auto& t : g_tracks) if (!t.used) { t = Track{}; t.used = true; t.id = id; return &t; }
    return nullptr;
}

static float contactRadius(const MTTouch& t) {
    float scale = g_single.load() ? 1.0f / 3.0f : 1.0f;   // a single field is three cells wide
    return std::clamp(0.15f * t.majorAxis / g_cfg.majorRef * scale, 0.05f, 0.8f);
}

static int touchCallback(MTDeviceRef, const MTTouch* touches, int n, double, int) {
    bool live = g_captured.load();
    for (auto& t : g_tracks) t.seen = false;

    for (int i = 0; i < n; ++i) {
        const MTTouch& t = touches[i];
        Track* tr = findTrack(t.identifier);
        if (!tr) continue;
        tr->seen = true;
        bool contact = (t.state == 3 || t.state == 4);
        float nx = t.normalized.pos.x, ny = t.normalized.pos.y;

        if (g_cfg.probe && (t.state != tr->state || tr->frames < 4)) {
            std::printf("id %2d state %d  size %6.3f  major %6.2f minor %6.2f  angle %5.2f  pos %.3f,%.3f  frame %d\n",
                        t.identifier, t.state, t.size, t.majorAxis, t.minorAxis, t.angle, nx, ny, tr->frames);
        }
        tr->state = t.state;
        tr->frames++;
        if (!tr->down) tr->peakSize = std::max(tr->peakSize, t.size);

        if (contact && !tr->down) {
            tr->down = true;
            tr->field = fieldAt(nx, ny);
            float fx, fy;
            localIn(tr->field, nx, ny, fx, fy);
            float u = std::clamp((tr->peakSize - g_cfg.sizeSoft) / (g_sizeHard.load() - g_cfg.sizeSoft), 0.0f, 1.0f);
            u = std::pow(u, g_cfg.forceCurve);
            float force = 0.1f + 0.9f * u;
            float contactMs = g_cfg.softMs + (g_cfg.hardMs - g_cfg.softMs) * u;
            if (live) {
                g_engine.push({morphion::Event::Down, t.identifier, tr->field, fx, fy, force, contactMs, contactRadius(t)});
                g_flashTime[tr->field] = CFAbsoluteTimeGetCurrent();
                g_flashForce[tr->field] = force;
            }
            if (g_cfg.probe) {
                char nm[6];
                {
                    std::lock_guard<std::mutex> lock(g_layoutMutex);
                    std::memcpy(nm, g_layout.name[std::min(tr->field, g_layout.count - 1)], sizeof nm);
                }
                std::printf("  -> strike field %d (%s) at %.2f,%.2f peak size %.3f force %.2f contact %.2f ms radius %.2f%s\n",
                            tr->field, nm, fx, fy, tr->peakSize, force, contactMs,
                            contactRadius(t), live ? "" : "  [not captured: silent]");
            }
        } else if (contact && tr->down) {
            float fx, fy;
            localIn(tr->field, nx, ny, fx, fy);
            if (live) g_engine.push({morphion::Event::Move, t.identifier, tr->field, fx, fy, 0, 0, contactRadius(t)});
        } else if (!contact && tr->down) {
            tr->down = false;
            g_engine.push({morphion::Event::Up, t.identifier, 0, 0, 0, 0, 0, 0});
        }
    }

    for (auto& t : g_tracks) {
        if (t.used && !t.seen) {
            if (t.down) g_engine.push({morphion::Event::Up, t.id, 0, 0, 0, 0, 0, 0});
            t.used = false;
        }
    }

    std::lock_guard<std::mutex> lock(g_uiMutex);
    g_uiTouches.clear();
    for (int i = 0; i < n; ++i) {
        const MTTouch& t = touches[i];
        g_uiTouches.push_back({t.normalized.pos.x, t.normalized.pos.y, t.majorAxis, t.minorAxis, t.angle, t.size, t.state});
    }
    return 0;
}

// ---------------------------------------------------------------- audio

static AudioUnit g_unit;
static MTDeviceRef g_mtDev = nullptr;

// Stop touch input and audio before the process exits. [NSApp run] never returns:
// terminate: calls exit(), and static destructors (the engine) would otherwise run
// while the touch and audio threads are still calling into them.
static void shutdown() {
    static bool done = false;
    if (done) return;
    done = true;
    if (g_mtDev) {
        MTUnregisterContactFrameCallback(g_mtDev, touchCallback);
        MTDeviceStop(g_mtDev);
    }
    if (g_unit) {
        AudioOutputUnitStop(g_unit);
        AudioUnitUninitialize(g_unit);
        AudioComponentInstanceDispose(g_unit);
        g_unit = nullptr;
    }
}

static OSStatus renderCallback(void*, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames,
                               AudioBufferList* io) {
#if defined(__aarch64__)
    uint64_t fpcr;
    asm volatile("mrs %0, fpcr" : "=r"(fpcr));
    asm volatile("msr fpcr, %0" ::"r"(fpcr | (1ull << 24)));   // flush denormals to zero
#endif
    float* left = (float*)io->mBuffers[0].mData;
    float* right = io->mNumberBuffers > 1 ? (float*)io->mBuffers[1].mData : nullptr;
    g_engine.process(left, right, (int)frames);
    return noErr;
}

static double g_sr = 48000.0;

// Settings the engine reads live (atomics): safe to change while playing.
static void applyLiveSettings() {
    g_engine.gain = g_set.gain;
    g_engine.restStrength = g_set.mute;
    g_engine.restFloor = g_cfg.muteFloor;
    g_engine.coupling = g_set.coupling;
    g_engine.radiationTilt = g_set.tilt;
    g_sizeHard = g_set.sizeHard;
}

// Fields, links, cavity: Engine::configure allocates, so the audio unit must be stopped.
static void configureEngine() {
    std::vector<double> freqs(g_layout.freq, g_layout.freq + g_layout.count);
    morphion::CouplingParams cp;
    cp.gapHz = g_cfg.gap;
    cp.gap2xHz = g_cfg.gap2x;
    morphion::GuParams gp;
    gp.couple = g_set.gu;
    gp.f = g_cfg.guHz;
    morphion::FieldParams fp;
    fp.decayScale = g_set.sustain;
    g_engine.configure(g_sr, freqs, fp, cp, gp);
    applyLiveSettings();
    for (const auto& l : g_engine.links()) {
        double f = g_engine.fieldFreq(l.dst);
        std::printf("link: %s drives %s at %dx; %s retuned to %.2f Hz (%+.1f cents)\n", g_layout.name[l.src],
                    g_layout.name[l.dst], l.order, g_layout.name[l.dst], f,
                    1200.0 * std::log2(f / g_layout.freq[l.dst]));
    }
}

// Scale, key, layout or cavity changed: rebuild the fields. Ringing notes are cut.
static void reconfigure() {
    buildLayout();
    if (g_unit) AudioOutputUnitStop(g_unit);
    configureEngine();
    if (g_unit) AudioOutputUnitStart(g_unit);
}

static bool startAudio() {
    AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
                                      kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &g_unit) != noErr) return false;

    AudioStreamBasicDescription hw = {};
    UInt32 size = sizeof(hw);
    AudioUnitGetProperty(g_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hw, &size);
    double sr = hw.mSampleRate > 0 ? hw.mSampleRate : 48000.0;

    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = sr;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = 4;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 32;
    AudioUnitSetProperty(g_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));

    // smaller hardware buffer for lower latency
    AudioDeviceID dev = 0;
    size = sizeof(dev);
    if (AudioUnitGetProperty(g_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, &size) == noErr) {
        UInt32 frames = (UInt32)g_cfg.buffer;
        AudioObjectPropertyAddress addr = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
        AudioObjectSetPropertyData(dev, &addr, 0, nullptr, sizeof(frames), &frames);
    }

    g_sr = sr;
    configureEngine();
    applyLiveSettings();

    AURenderCallbackStruct cb = {renderCallback, nullptr};
    AudioUnitSetProperty(g_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (AudioUnitInitialize(g_unit) != noErr || AudioOutputUnitStart(g_unit) != noErr) return false;
    std::printf("audio: %.0f Hz, buffer %d frames (%.1f ms)\n", sr, g_cfg.buffer, 1000.0 * g_cfg.buffer / sr);
    return true;
}

// ---------------------------------------------------------------- UI

static void setCaptured(bool on, NSWindow* window) {
    if (on == g_captured.load()) return;
    if (on) {
        NSRect f = window.frame;
        CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
        CGWarpMouseCursorPosition(CGPointMake(NSMidX(f), primaryHeight - NSMidY(f)));
        CGAssociateMouseAndMouseCursorPosition(false);
        [NSCursor hide];
    } else {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
    }
    g_captured = on;
}

@interface PadView : NSView
@property bool hoverPlay, hoverGear, settingsOpen;
@end

static NSRect padRect(NSRect b) {
    CGFloat margin = 18;
    return NSMakeRect(margin, margin, b.size.width - 2 * margin, b.size.height - 2 * margin - kTitlebar);
}

static NSColor* rgb(double r, double g, double b, double a = 1.0) {
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a];
}
static NSColor* ink() { return rgb(0.07, 0.07, 0.075); }      // background, and text on light
static NSColor* amber(double a = 1.0) { return rgb(1.0, 0.76, 0.40, a); }

// Play and the settings gear sit side by side on a light strip across the middle of the
// window, drawn like the notes (no system styling). Only Play starts playing.
static void startRects(NSRect bounds, NSRect* play, NSRect* gear) {
    NSRect pad = padRect(bounds);
    int cells = g_set.single ? 1 : 3;
    CGFloat cw = pad.size.width / cells, ch = pad.size.height / cells;
    CGFloat w = std::clamp(cw * 0.5, 160.0, 320.0), h = std::clamp(ch * 0.32, 52.0, 88.0), gap = 14;
    CGFloat x0 = std::round(NSMidX(pad) - (w + gap + h) / 2), y = std::round(NSMidY(pad) - h / 2);
    if (play) *play = NSMakeRect(x0, y, w, h);
    if (gear) *gear = NSMakeRect(x0 + w + gap, y, h, h);
}

// ---------------------------------------------------------------- settings pane

// Controls are laid out while drawing and hit-tested on click, so drawing and input
// always agree. Choice rows are pills (selected = amber); sliders are a line and a knob.
enum CtlId { kCtlScale, kCtlKey, kCtlLayout, kCtlGain, kCtlSustain, kCtlSizeHard, kCtlMute, kCtlSwell, kCtlTilt, kCtlGu,
             kCtlReset, kCtlDone };
struct Ctl {
    CtlId id;
    int choice = -1;        // for choice pills
    NSRect r;               // pill / button / slider track hit area
    double lo = 0, hi = 1;  // sliders
};
struct SliderDef { CtlId id; const char* label; double lo, hi; float Settings::*field; const char* fmt; };
static const SliderDef kSliders[] = {
    {kCtlGain, "Volume", 0.2, 2.0, &Settings::gain, "%.2f"},
    {kCtlSustain, "Sustain", 0.5, 3.0, &Settings::sustain, "%.2fx"},
    {kCtlSizeHard, "Hit strength", 0.5, 2.0, &Settings::sizeHard, "%.2f"},
    {kCtlMute, "Resting mute", 0.0, 1.5, &Settings::mute, "%.2f"},
    {kCtlSwell, "Sympathetic swell", 0.0, 3.0, &Settings::coupling, "%.2f"},
    {kCtlTilt, "Low / high balance", -0.5, 0.5, &Settings::tilt, "%+.2f"},
    {kCtlGu, "Gu cavity", 0.0, 0.4, &Settings::gu, "%.2f"},
};
static const char* sliderHint(CtlId id) {
    switch (id) {
    case kCtlSustain: return "how long notes ring; 1x is a measured handpan";
    case kCtlSizeHard: return "lower: a lighter touch hits full force";
    case kCtlMute: return "how fast a resting finger stops a note";
    case kCtlSwell: return "how strongly notes ring in sympathy";
    case kCtlTilt: return "negative favours the low notes";
    case kCtlGu: return "the air resonance under the ding";
    default: return "";
    }
}

static std::vector<Ctl> g_ctls;
static int g_dragSlider = -1;

static NSRect paneRect(NSRect b) {
    CGFloat w = std::min<CGFloat>(700, b.size.width - 40), h = std::min<CGFloat>(520, b.size.height - kTitlebar - 24);
    return NSMakeRect(std::round(NSMidX(b) - w / 2), std::round((b.size.height - kTitlebar) / 2 - h / 2), w, h);
}

static void drawText(NSString* t, NSPoint p, CGFloat size, NSColor* c, NSFontWeight weight = NSFontWeightRegular) {
    [t drawAtPoint:p withAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:size weight:weight],
                                      NSForegroundColorAttributeName : c}];
}

// A pill with a label; selected pills fill amber with dark text.
static NSRect drawPill(NSString* label, CGFloat x, CGFloat y, CGFloat h, bool selected, CGFloat size = 13) {
    NSDictionary* at = @{NSFontAttributeName : [NSFont systemFontOfSize:size weight:NSFontWeightMedium]};
    NSSize ts = [label sizeWithAttributes:at];
    NSRect r = NSMakeRect(x, y, std::ceil(ts.width) + 26, h);
    NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:h / 2 yRadius:h / 2];
    if (selected) {
        [amber() setFill];
        [p fill];
    } else {
        [[NSColor colorWithWhite:0.45 alpha:1] setStroke];
        p.lineWidth = 1.2;
        [p stroke];
    }
    drawText(label, NSMakePoint(NSMidX(r) - ts.width / 2, NSMidY(r) - ts.height / 2), size,
             selected ? ink() : [NSColor colorWithWhite:0.85 alpha:1], NSFontWeightMedium);
    return r;
}

static void drawPane(NSRect b) {
    g_ctls.clear();
    [[NSColor colorWithWhite:0 alpha:0.6] setFill];
    NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
    NSRect pr = paneRect(b);
    NSBezierPath* panel = [NSBezierPath bezierPathWithRoundedRect:pr xRadius:18 yRadius:18];
    [rgb(0.10, 0.10, 0.105) setFill];
    [panel fill];
    [[NSColor colorWithWhite:0.35 alpha:1] setStroke];
    panel.lineWidth = 1.2;
    [panel stroke];

    const CGFloat left = pr.origin.x + 28, labelW = 104, ctlX = left + labelW, right = NSMaxX(pr) - 28;
    const CGFloat pillH = 26, rowGap = 12;
    CGFloat y = NSMaxY(pr) - 24;
    NSColor* labelC = [NSColor colorWithWhite:0.6 alpha:1];

    drawText(@"Settings", NSMakePoint(left, y - 22), 18, [NSColor colorWithWhite:0.95 alpha:1], NSFontWeightSemibold);
    y -= 22 + 18;

    // choice rows wrap onto more lines when they run out of width
    auto choiceRow = [&](NSString* label, CtlId id, int count, auto nameOf, int selected, CGFloat minW = 0) {
        drawText(label, NSMakePoint(left, y - pillH + 5), 13, labelC, NSFontWeightMedium);
        CGFloat x = ctlX;
        for (int i = 0; i < count; ++i) {
            NSString* n = nameOf(i);
            NSDictionary* at = @{NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]};
            CGFloat w = std::max(minW, std::ceil([n sizeWithAttributes:at].width) + 22);
            if (x + w > right && x > ctlX) { x = ctlX; y -= pillH + 6; }
            NSRect r = NSMakeRect(x, y - pillH, w, pillH);
            NSBezierPath* pp = [NSBezierPath bezierPathWithRoundedRect:r xRadius:pillH / 2 yRadius:pillH / 2];
            bool sel = i == selected;
            if (sel) {
                [amber() setFill];
                [pp fill];
            } else {
                [[NSColor colorWithWhite:0.45 alpha:1] setStroke];
                pp.lineWidth = 1.2;
                [pp stroke];
            }
            NSSize ts = [n sizeWithAttributes:at];
            drawText(n, NSMakePoint(NSMidX(r) - ts.width / 2, NSMidY(r) - ts.height / 2), 12,
                     sel ? ink() : [NSColor colorWithWhite:0.85 alpha:1], NSFontWeightMedium);
            g_ctls.push_back({id, i, r});
            x += w + 6;
        }
        y -= pillH + rowGap;
    };
    choiceRow(@"Scale", kCtlScale, kScaleCount, [](int i) { return [NSString stringWithUTF8String:kScales[i].name]; },
              g_set.scale);
    choiceRow(@"Key", kCtlKey, 12, [](int i) { return [NSString stringWithUTF8String:kKeys[i]]; }, g_set.key, 34);
    choiceRow(@"Layout", kCtlLayout, 2, [](int i) { return i == 0 ? @"Grid" : @"Single note"; }, g_set.single ? 1 : 0);
    y -= 8;

    // sliders in two columns: label and value on top, track, hint underneath
    const int n = int(sizeof(kSliders) / sizeof(kSliders[0]));
    const CGFloat colGap = 36, colW = (right - left - colGap) / 2, cellH = 62;
    for (int i = 0; i < n; ++i) {
        const SliderDef& sd = kSliders[i];
        CGFloat cx = left + (i % 2) * (colW + colGap), cy = y - (i / 2) * cellH;
        double v = g_set.*(sd.field);
        drawText([NSString stringWithUTF8String:sd.label], NSMakePoint(cx, cy - 16), 13, labelC, NSFontWeightMedium);
        char buf[16];
        std::snprintf(buf, sizeof buf, sd.fmt, v);
        NSString* vs = [NSString stringWithUTF8String:buf];
        NSDictionary* vat = @{NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular]};
        CGFloat vw = [vs sizeWithAttributes:vat].width;
        [vs drawAtPoint:NSMakePoint(cx + colW - vw, cy - 16)
            withAttributes:@{NSFontAttributeName : vat[NSFontAttributeName],
                             NSForegroundColorAttributeName : [NSColor colorWithWhite:0.85 alpha:1]}];
        CGFloat trackX = cx + 8, trackW = colW - 16, ty = cy - 30;
        [[NSColor colorWithWhite:0.4 alpha:1] setFill];
        NSRectFill(NSMakeRect(trackX, ty - 1, trackW, 2));
        double t = std::clamp((v - sd.lo) / (sd.hi - sd.lo), 0.0, 1.0);
        [amber() setFill];
        NSRectFill(NSMakeRect(trackX, ty - 1, trackW * t, 2));
        [[NSColor colorWithWhite:0.92 alpha:1] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(trackX + trackW * t - 7, ty - 7, 14, 14)] fill];
        const char* hint = sliderHint(sd.id);
        if (*hint) drawText([NSString stringWithUTF8String:hint], NSMakePoint(cx, cy - 52), 11,
                            [NSColor colorWithWhite:0.42 alpha:1]);
        g_ctls.push_back({sd.id, -1, NSMakeRect(trackX - 10, ty - 13, trackW + 20, 26), sd.lo, sd.hi});
    }

    // footer: reset on the left, done on the right
    CGFloat fy = pr.origin.y + 20;
    NSRect reset = drawPill(@"Reset to defaults", left, fy, 30, false);
    g_ctls.push_back({kCtlReset, -1, reset});
    NSDictionary* at = @{NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightMedium]};
    CGFloat doneW = std::ceil([@"Done" sizeWithAttributes:at].width) + 26;
    NSRect done = drawPill(@"Done", right - doneW, fy, 30, true);
    g_ctls.push_back({kCtlDone, -1, done});
}

@implementation PadView

- (void)updateTrackingAreas {
    for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:NSZeroRect
                                   options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                           NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                     owner:self
                                  userInfo:nil]];
    [super updateTrackingAreas];
}

- (void)mouseMoved:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect play, gear;
    startRects(self.bounds, &play, &gear);
    self.hoverPlay = !self.settingsOpen && NSPointInRect(p, play);
    self.hoverGear = !self.settingsOpen && NSPointInRect(p, gear);
}
- (void)mouseExited:(NSEvent*)e { self.hoverPlay = self.hoverGear = false; }

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return NO; }

- (void)setSlider:(const Ctl&)c fromX:(CGFloat)x {
    for (const auto& sd : kSliders) {
        if (sd.id != c.id) continue;
        double t = std::clamp((x - (c.r.origin.x + 10)) / (c.r.size.width - 20), 0.0, 1.0);
        g_set.*(sd.field) = float(sd.lo + t * (sd.hi - sd.lo));
        if (c.id != kCtlGu && c.id != kCtlSustain) applyLiveSettings();   // these two rebuild the fields: on release
    }
}

- (void)closeSettings {
    self.settingsOpen = false;
    g_dragSlider = -1;
    saveSettings();
}

- (void)mouseDown:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (p.y > self.bounds.size.height - kTitlebar) {   // the strip under the title bar drags the window
        [self.window performWindowDragWithEvent:e];
        return;
    }
    if (self.settingsOpen) {
        if (!NSPointInRect(p, paneRect(self.bounds))) { [self closeSettings]; return; }
        for (size_t i = 0; i < g_ctls.size(); ++i) {
            const Ctl& c = g_ctls[i];
            if (!NSPointInRect(p, c.r)) continue;
            switch (c.id) {
            case kCtlScale: g_set.scale = c.choice; reconfigure(); break;
            case kCtlKey: g_set.key = c.choice; reconfigure(); break;
            case kCtlLayout: g_set.single = c.choice == 1; reconfigure(); break;
            case kCtlReset: g_set = Settings{}; reconfigure(); break;
            case kCtlDone: [self closeSettings]; return;
            default: g_dragSlider = int(i); [self setSlider:c fromX:p.x]; break;
            }
            self.window.title = layoutTitle();
            saveSettings();
            return;
        }
        return;
    }
    if (g_captured.load()) return;
    NSRect play, gear;
    startRects(self.bounds, &play, &gear);
    if (NSPointInRect(p, play)) {
        self.hoverPlay = false;
        setCaptured(true, self.window);
    } else if (NSPointInRect(p, gear)) {
        self.hoverGear = false;
        self.settingsOpen = true;
    }
}

- (void)mouseDragged:(NSEvent*)e {
    if (!self.settingsOpen || g_dragSlider < 0 || g_dragSlider >= int(g_ctls.size())) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    [self setSlider:g_ctls[g_dragSlider] fromX:p.x];
}

- (void)mouseUp:(NSEvent*)e {
    if (g_dragSlider >= 0 && g_dragSlider < int(g_ctls.size()) &&
        (g_ctls[g_dragSlider].id == kCtlGu || g_ctls[g_dragSlider].id == kCtlSustain))
        reconfigure();
    if (g_dragSlider >= 0) saveSettings();
    g_dragSlider = -1;
}

- (void)keyDown:(NSEvent*)e {
    if (e.keyCode == 53) {   // Esc: close settings, or stop playing
        if (self.settingsOpen) [self closeSettings];
        else setCaptured(false, self.window);
        return;
    }
    if ((e.keyCode == 36 || e.keyCode == 76) && !g_captured.load() && !self.settingsOpen) {   // Return / Enter: play
        self.hoverPlay = false;
        setCaptured(true, self.window);
        return;
    }
    if (e.keyCode == 49 && g_captured.load()) {   // Space: slap the shell (keys have no velocity: fixed force)
        if (!e.isARepeat) {
            g_engine.push({morphion::Event::Slap, 0, 0, 0, 0, 0.8f, 0, 0});
            g_slapTime = CFAbsoluteTimeGetCurrent();
        }
        return;
    }
    [super keyDown:e];
}

// The canvas: clean outlines, no gradients. Each note is a rounded-rectangle outline
// inside its grid cell (its hit area is the full cell). A strike fills that note in
// solid amber, stronger for harder hits, fading out; touches are filled ellipses.
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSRect pad = padRect(b);
    bool live = g_captured.load();
    int cells = g_set.single ? 1 : 3;
    double dim = live ? 1.0 : 0.45;   // outlines fade while not playing

    [ink() setFill];
    NSRectFill(b);

    // while playing, a quiet reminder of the way out, centred in the title bar
    if (live) {
        NSDictionary* small = @{NSFontAttributeName : [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName : [NSColor colorWithWhite:0.82 alpha:1]};
        NSString* hint = @"Esc to stop";
        NSSize ss = [hint sizeWithAttributes:small];
        [hint drawAtPoint:NSMakePoint(NSMidX(b) - ss.width / 2, b.size.height - kTitlebar / 2 - ss.height / 2)
           withAttributes:small];
    }

    double now = CFAbsoluteTimeGetCurrent();
    CGFloat cw = pad.size.width / cells, ch = pad.size.height / cells;
    CGFloat inset = std::min(cw, ch) * 0.07;
    CGFloat fontSize = std::clamp(std::min(cw, ch) * 0.11, 13.0, 26.0);
    for (int row = 0; row < cells; ++row) {
        for (int col = 0; col < cells; ++col) {
            int field = row * cells + col;
            NSRect cell = NSMakeRect(pad.origin.x + col * cw, pad.origin.y + (cells - 1 - row) * ch, cw, ch);
            NSRect fr = NSInsetRect(cell, inset, inset);
            CGFloat rad = std::min(fr.size.width, fr.size.height) * 0.22;
            double age = now - g_flashTime[field].load();
            double glow = age < 2.0 ? std::exp(-age * 2.5) * (0.35 + 0.65 * g_flashForce[field].load()) : 0.0;
            double slapAge = now - g_slapTime.load();
            if (slapAge < 0.6) glow = std::max(glow, 0.25 * std::exp(-slapAge * 8.0));   // a slap lights the whole pan briefly

            NSBezierPath* note = [NSBezierPath bezierPathWithRoundedRect:fr xRadius:rad yRadius:rad];
            if (glow > 0.003) {
                [rgb(1.0, 0.72, 0.32, 0.55 * glow) setFill];
                [note fill];
            }
            [rgb(0.62 + 0.38 * glow, 0.60 + 0.20 * glow, 0.58 - 0.18 * glow, dim) setStroke];
            note.lineWidth = 1.5;
            [note stroke];

            NSString* name = [NSString stringWithUTF8String:g_layout.name[field]];
            NSDictionary* label = @{NSFontAttributeName : [NSFont systemFontOfSize:fontSize weight:NSFontWeightMedium],
                                    NSForegroundColorAttributeName :
                                        rgb(0.75 + 0.25 * glow, 0.73 + 0.27 * glow, 0.70 + 0.30 * glow, dim)};
            NSSize ls = [name sizeWithAttributes:label];
            [name drawAtPoint:NSMakePoint(NSMidX(fr) - ls.width / 2, NSMidY(fr) - ls.height / 2) withAttributes:label];
        }
    }

    if (!live && !self.settingsOpen) {
        // a solid strip across the window behind Play and the gear, so they stand apart from the pan
        NSRect play, gear;
        startRects(b, &play, &gear);
        CGFloat pad2 = play.size.height * 0.35;
        [[NSColor colorWithWhite:0.92 alpha:1] setFill];
        NSRectFill(NSMakeRect(0, play.origin.y - pad2, b.size.width, play.size.height + 2 * pad2));

        NSBezierPath* btn = [NSBezierPath bezierPathWithRoundedRect:play xRadius:play.size.height / 2
                                                            yRadius:play.size.height / 2];
        if (self.hoverPlay) {
            [amber() setFill];
            [btn fill];
        }
        [ink() setStroke];
        btn.lineWidth = 2;
        [btn stroke];
        NSDictionary* bl = @{NSFontAttributeName : [NSFont systemFontOfSize:std::round(play.size.height * 0.42)
                                                                      weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName : ink()};
        NSSize ts = [@"Play" sizeWithAttributes:bl];
        [@"Play" drawAtPoint:NSMakePoint(NSMidX(play) - ts.width / 2, NSMidY(play) - ts.height / 2) withAttributes:bl];

        NSBezierPath* gb = [NSBezierPath bezierPathWithOvalInRect:gear];
        if (self.hoverGear) {
            [amber() setFill];
            [gb fill];
        }
        [ink() setStroke];
        gb.lineWidth = 2;
        [gb stroke];
        NSImageSymbolConfiguration* sc = [[NSImageSymbolConfiguration configurationWithPointSize:gear.size.height * 0.42
                                                                                          weight:NSFontWeightMedium]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[ ink() ]]];
        NSImage* icon = [[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Settings"]
            imageWithSymbolConfiguration:sc];
        NSSize is = icon.size;
        [icon drawInRect:NSMakeRect(NSMidX(gear) - is.width / 2, NSMidY(gear) - is.height / 2, is.width, is.height)];
    }

    if (self.settingsOpen) drawPane(b);

    // live touches: filled ellipses, amber while in contact; only while playing
    std::vector<UiTouch> touches;
    if (live) {
        std::lock_guard<std::mutex> lock(g_uiMutex);
        touches = g_uiTouches;
    }
    for (const auto& t : touches) {
        CGFloat x = pad.origin.x + t.nx * pad.size.width, y = pad.origin.y + t.ny * pad.size.height;
        CGFloat rx = std::max(4.0f, t.major * 2.0f), ry = std::max(4.0f, t.minor * 2.0f);
        bool contact = (t.state == 3 || t.state == 4);
        NSAffineTransform* tf = [NSAffineTransform transform];
        [tf translateXBy:x yBy:y];
        [tf rotateByRadians:t.angle];
        NSBezierPath* p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-rx, -ry, 2 * rx, 2 * ry)];
        [p transformUsingAffineTransform:tf];
        [(contact ? rgb(1.0, 0.80, 0.45, 0.72) : [NSColor colorWithWhite:1 alpha:0.2]) setFill];
        [p fill];
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow* window;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification*)n {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 640)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    // the icon, also when launched through the build/morphion symlink (outside the bundle's view)
    NSString* exe = [NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath];
    NSString* icns = [[[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"Resources/AppIcon.icns"];
    if (NSImage* icon = [[NSImage alloc] initWithContentsOfFile:icns]) NSApp.applicationIconImage = icon;

    self.window.releasedWhenClosed = NO;
    self.window.contentMinSize = NSMakeSize(760, 610);   // room for the settings pane   // ARC owns it; AppKit releasing it on close crashed quit
    // one surface: the content runs under a transparent title bar, dark to match
    self.window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    self.window.titlebarAppearsTransparent = YES;
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.toolbar = [[NSToolbar alloc] initWithIdentifier:@"morphion"];   // empty: a taller bar,
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;                    // traffic lights inset
    self.window.title = layoutTitle();
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.backgroundColor = [NSColor colorWithCalibratedRed:0.07 green:0.07 blue:0.075 alpha:1];
    PadView* view = [[PadView alloc] initWithFrame:self.window.contentView.bounds];
    self.window.contentView = view;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer*) { [view setNeedsDisplay:YES]; }];
}
- (void)applicationDidResignActive:(NSNotification*)n { setCaptured(false, self.window); }
- (void)applicationWillTerminate:(NSNotification*)n {
    setCaptured(false, self.window);
    shutdown();
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a { return YES; }
@end

// ---------------------------------------------------------------- main

static void usage() {
    std::fprintf(stderr,
                 "usage: morphion [--layout grid|single] [--probe] [--mute X] [--mute-floor X] [--size-soft X] [--size-hard X]\n"
                 "                [--force-curve X] [--soft-ms X] [--hard-ms X] [--major-ref X]\n"
                 "                [--gain X] [--buffer N] [--coupling X] [--gap HZ] [--gap-2x HZ]\n"
                 "                [--tilt X] [--gu X] [--gu-hz HZ] [--snapshot DIR]\n");
}

// Draw the canvas offscreen to <dir>/idle.png and <dir>/playing.png and exit (no audio,
// no trackpad): for checking the layout without opening the window.
static int snapshot(const char* dir) {
    [NSApplication sharedApplication];
    buildLayout();
    NSRect frame = NSMakeRect(0, 0, 900, 640);
    PadView* view = [[PadView alloc] initWithFrame:frame];
    auto save = [&](NSString* name) {
        NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:frame];
        [view cacheDisplayInRect:frame toBitmapImageRep:rep];
        NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:[[NSString stringWithUTF8String:dir] stringByAppendingPathComponent:name] atomically:YES];
    };
    save(@"idle.png");
    double now = CFAbsoluteTimeGetCurrent();
    g_captured = true;
    g_flashTime[4] = now - 0.05;  g_flashForce[4] = 0.9f;   // ding just struck
    g_flashTime[1] = now - 0.30;  g_flashForce[1] = 0.3f;   // A4 swelling
    {
        std::lock_guard<std::mutex> lock(g_uiMutex);
        g_uiTouches = {{0.52f, 0.47f, 11.0f, 8.0f, 2.1f, 1.0f, 4}, {0.20f, 0.80f, 7.5f, 6.9f, 1.57f, 0.3f, 1}};
    }
    save(@"playing.png");
    g_captured = false;
    view.settingsOpen = true;
    save(@"settings.png");
    return 0;
}

int main(int argc, char** argv) {
    loadSettings();
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char* {
            if (i + 1 >= argc) { usage(); std::exit(1); }
            return argv[++i];
        };
        if (a == "--layout") g_set.single = std::string(next()) == "single";
        else if (a == "--probe") g_cfg.probe = true;
        else if (a == "--mute") g_set.mute = std::atof(next());
        else if (a == "--mute-floor") g_cfg.muteFloor = std::atof(next());
        else if (a == "--size-soft") g_cfg.sizeSoft = std::atof(next());
        else if (a == "--size-hard") g_set.sizeHard = std::atof(next());
        else if (a == "--force-curve") g_cfg.forceCurve = std::atof(next());
        else if (a == "--soft-ms") g_cfg.softMs = std::atof(next());
        else if (a == "--hard-ms") g_cfg.hardMs = std::atof(next());
        else if (a == "--major-ref") g_cfg.majorRef = std::atof(next());
        else if (a == "--gain") g_set.gain = std::atof(next());
        else if (a == "--buffer") g_cfg.buffer = std::atoi(next());
        else if (a == "--coupling") g_set.coupling = std::atof(next());
        else if (a == "--gap") g_cfg.gap = std::atof(next());
        else if (a == "--gap-2x") g_cfg.gap2x = std::atof(next());
        else if (a == "--tilt") g_set.tilt = std::atof(next());
        else if (a == "--gu") g_set.gu = std::atof(next());
        else if (a == "--gu-hz") g_cfg.guHz = std::atof(next());
        else if (a == "--snapshot") { const char* dir = next(); return snapshot(dir); }
        else { usage(); return 1; }
    }
    for (int i = 0; i < 9; ++i) { g_flashTime[i] = 0.0; g_flashForce[i] = 0.0f; }
    buildLayout();

    if (!loadMultitouch()) return 1;
    g_mtDev = MTDeviceCreateDefault();
    if (!g_mtDev) { std::fprintf(stderr, "no multitouch device\n"); return 1; }
    if (!startAudio()) { std::fprintf(stderr, "audio start failed\n"); return 1; }
    MTRegisterContactFrameCallback(g_mtDev, touchCallback);
    MTDeviceStart(g_mtDev, 0);

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu* bar = [NSMenu new];
        NSMenuItem* appItem = [NSMenuItem new];
        [bar addItem:appItem];
        NSMenu* appMenu = [NSMenu new];
        [appMenu addItemWithTitle:@"Quit morphion" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        app.mainMenu = bar;
        AppDelegate* delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }

    shutdown();
    return 0;
}
