// morphion trackpad prototype: play the handpan engine from the Mac trackpad.
//
//   make -C mac && open mac/build/morphion.app
//   mac/build/morphion [--probe] [--mute 0.6] [--mute-floor 0.15]
//            [--size-soft 0.2] [--size-hard 1.3] [--force-curve 1.15] [--major-ref 10]
//            [--gain 1.0] [--buffer 128]
//            [--coupling 1.0] [--gap 2.4] [--gap-2x 0.45] [--tilt -0.1]
//            [--gu 0.2] [--gu-hz 80]
//   mac/build/morphion --snapshot DIR   # draw the canvas to DIR/idle.png, playing.png, settings.png, error.png, exit
//   mac/build/morphion --frames DIR     # run the engine offline, draw 60 fps frames of a few strikes to DIR
//   mac/build/morphion --check-recording # record random touches, replay the take, check they match
//
// Play (or Return) starts playing: the cursor is frozen and hidden so taps land here.
// Esc stops, Space slaps the shell, R records, the gear opens settings. Touches only sound
// while playing. The folder (or Cmd-O, or a file dropped on the window) plays a score file.
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
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>

#include <algorithm>
#include <cstdarg>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "../engine/morphion.h"
#include "../engine/score.h"

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
static CFArrayRef (*MTDeviceCreateList)(void);              // every multitouch device (built-in, Magic Trackpads)
static int (*MTDeviceGetDeviceID)(MTDeviceRef, uint64_t*);   // stable per device, across reconnects
static bool (*MTDeviceIsRunning)(MTDeviceRef);
static int (*MTDeviceGetSensorDimensions)(MTDeviceRef, int* rows, int* cols);
static int (*MTDeviceGetSensorSurfaceDimensions)(MTDeviceRef, int* width, int* height);   // 0.01 mm

static bool loadMultitouch() {
    void* h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!h) { std::fprintf(stderr, "dlopen MultitouchSupport failed: %s\n", dlerror()); return false; }
    MTDeviceCreateDefault = (MTDeviceRef(*)(void))dlsym(h, "MTDeviceCreateDefault");
    MTRegisterContactFrameCallback = (void (*)(MTDeviceRef, MTFrameCallback))dlsym(h, "MTRegisterContactFrameCallback");
    MTUnregisterContactFrameCallback = (void (*)(MTDeviceRef, MTFrameCallback))dlsym(h, "MTUnregisterContactFrameCallback");
    MTDeviceStart = (int (*)(MTDeviceRef, int))dlsym(h, "MTDeviceStart");
    MTDeviceStop = (int (*)(MTDeviceRef))dlsym(h, "MTDeviceStop");
    MTDeviceCreateList = (CFArrayRef(*)(void))dlsym(h, "MTDeviceCreateList");
    MTDeviceGetDeviceID = (int (*)(MTDeviceRef, uint64_t*))dlsym(h, "MTDeviceGetDeviceID");
    MTDeviceIsRunning = (bool (*)(MTDeviceRef))dlsym(h, "MTDeviceIsRunning");
    MTDeviceGetSensorDimensions = (int (*)(MTDeviceRef, int*, int*))dlsym(h, "MTDeviceGetSensorDimensions");
    MTDeviceGetSensorSurfaceDimensions = (int (*)(MTDeviceRef, int*, int*))dlsym(h, "MTDeviceGetSensorSurfaceDimensions");
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
    float muteFloor = 0.15f; // resting-finger damping anywhere on a field, fraction of the center's
    float sizeSoft = 0.2f;   // peak touch size of the softest tap (force 0.1)
    float forceCurve = 1.15f; // >1: more room at the soft end, <1: reaches hard sooner
    float softMs = 1.6f;     // contact time passed to the engine for the softest tap
    float hardMs = 0.9f;     // ... and for the hardest (engine adds Hertz scaling on top)
    float majorRef = 10.0f;  // major axis of a typical fingertip (sets contact radius)
    int buffer = 128;
    double gap = 2.4;        // Hz below the source's 3rd harmonic that a listener is tuned to
    double gap2x = 0.45;     // same for 2nd-harmonic pairs
    double guHz = 80.0;      // cavity pitch: ~85 free, ~73 on the lap
};
static Config g_cfg;

// User settings: the settings pane edits these and they persist between launches
// (NSUserDefaults, domain kDefaults, shared by the app and the build/morphion symlink:
// see defaults()). Command-line flags override them for one run.
struct Settings {
    int scale = 0;           // index into kScales
    int key = 5;             // index into kKeys: D
    float gain = 1.0f;       // output volume
    float sizeHard = 1.3f;   // peak touch size of a full-force tap: lower = lighter touch reaches full force
    float mute = 0.6f;       // resting-finger damping relative to strike contact damping
    float coupling = 1.0f;   // scales every cross-field link (the sympathetic swell)
    float tilt = -0.1f;      // loudness balance: negative favors low notes
    float gu = 0.2f;         // Gu cavity coupling, 0 = off
    float sustain = 1.0f;    // multiplies every decay time (1 = the measured handpan values)
    float stereo = 0.5f;     // stereo width: side columns panned to +-this (0 = mono)
    float attack = 1.0f;     // strike click and shimmer level (0 = off)
    float slap = 1.0f;       // slap loudness (0 = off)
    int reverb = 0;          // index into morphion::kReverbs: dry, then longer and longer
};
static Settings g_set;

// Scales, keys and note names live with the score format (engine/score.h).
using morphion::score::kScales;
using morphion::score::kScaleCount;
using morphion::score::kKeys;

// The playable fields for the current settings, laid out by morphion::score::layout.
struct LayoutTable {
    int count = 9;
    int ding = 4;
    double freq[9] = {};
    char name[9][6] = {};
};
static LayoutTable g_layout;
static std::mutex g_layoutMutex;          // the touch thread reads names for --probe output
static std::atomic<float> g_sizeHard{1.3f};

// The user's pan, or the pan a score file is played on.
static void buildLayout(int scale, int key) {
    LayoutTable L;
    auto sl = morphion::score::layout(scale, key);
    L.count = sl.count;
    for (int i = 0; i < sl.count; ++i) {
        L.freq[i] = sl.freq[i];
        std::snprintf(L.name[i], sizeof L.name[i], "%s", morphion::score::noteName(sl.midi[i]).c_str());
    }
    std::lock_guard<std::mutex> lock(g_layoutMutex);
    g_layout = L;
}
static void buildLayout() { buildLayout(g_set.scale, g_set.key); }

static NSString* layoutTitle() {
    return [NSString stringWithFormat:@"morphion: %s %s", kKeys[g_set.key], kScales[g_set.scale].name];
}

static NSString* const kDefaults = @"io.github.sanghoonio.morphion";   // the bundle identifier

// The same domain either way: inside the bundle it is the standard defaults (macOS refuses a
// suite named after the app's own bundle identifier, and returns nil); outside it, through
// the build/morphion symlink, there is no bundle identifier, so it is opened by name.
static NSUserDefaults* defaults() {
    static NSUserDefaults* d = [NSBundle.mainBundle.bundleIdentifier isEqualToString:kDefaults]
                                   ? NSUserDefaults.standardUserDefaults
                                   : [[NSUserDefaults alloc] initWithSuiteName:kDefaults];
    return d;
}

static void loadSettings() {
    NSUserDefaults* d = defaults();
    // settings saved before the bundle identifier changed lived under "morphion"
    if (![d objectForKey:@"scale"]) {
        NSDictionary* old = [NSUserDefaults.standardUserDefaults persistentDomainForName:@"morphion"];
        for (NSString* k in old) [d setObject:old[k] forKey:k];
    }
    if (![d objectForKey:@"scale"]) return;
    g_set.scale = std::clamp(int([d integerForKey:@"scale"]), 0, kScaleCount - 1);
    g_set.key = std::clamp(int([d integerForKey:@"key"]), 0, 11);
    g_set.gain = [d floatForKey:@"gain"];
    g_set.sizeHard = [d floatForKey:@"sizeHard"];
    g_set.mute = [d floatForKey:@"mute"];
    g_set.coupling = [d floatForKey:@"coupling"];
    g_set.tilt = [d floatForKey:@"tilt"];
    g_set.gu = [d floatForKey:@"gu"];
    g_set.sustain = [d objectForKey:@"sustain"] ? [d floatForKey:@"sustain"] : 1.0f;
    if ([d objectForKey:@"stereo"]) g_set.stereo = [d floatForKey:@"stereo"];
    if ([d objectForKey:@"attack"]) g_set.attack = [d floatForKey:@"attack"];
    if ([d objectForKey:@"slap"]) g_set.slap = [d floatForKey:@"slap"];
    g_set.reverb = std::clamp(int([d integerForKey:@"reverb"]), 0, morphion::kReverbCount - 1);
}

static void saveSettings() {
    NSUserDefaults* d = defaults();
    [d setInteger:g_set.scale forKey:@"scale"];
    [d setInteger:g_set.key forKey:@"key"];
    [d setFloat:g_set.gain forKey:@"gain"];
    [d setFloat:g_set.sizeHard forKey:@"sizeHard"];
    [d setFloat:g_set.mute forKey:@"mute"];
    [d setFloat:g_set.coupling forKey:@"coupling"];
    [d setFloat:g_set.tilt forKey:@"tilt"];
    [d setFloat:g_set.gu forKey:@"gu"];
    [d setFloat:g_set.sustain forKey:@"sustain"];
    [d setFloat:g_set.stereo forKey:@"stereo"];
    [d setFloat:g_set.attack forKey:@"attack"];
    [d setFloat:g_set.slap forKey:@"slap"];
    [d setInteger:g_set.reverb forKey:@"reverb"];
}

static int fieldAt(float nx, float ny) {
    int col = std::clamp(int(nx * 3), 0, 2);
    int row = std::clamp(int((1 - ny) * 3), 0, 2);
    return row * 3 + col;
}

// Position in a field's own coordinates: [-1, 1] across the cell, x along the long (horizontal) axis.
static void localIn(int field, float nx, float ny, float& fx, float& fy) {
    int col = field % 3, row = field / 3;
    fx = (nx * 3 - col) * 2 - 1;
    fy = (ny * 3 - (2 - row)) * 2 - 1;
}

// The inverse: where on the trackpad (0..1, y up) a point in a field's coordinates lies.
static void fieldToPad(int field, float fx, float fy, float& nx, float& ny) {
    int col = field % 3, row = field / 3;
    nx = ((fx + 1) / 2 + col) / 3;
    ny = ((fy + 1) / 2 + (2 - row)) / 3;
}

// ---------------------------------------------------------------- shared state

static morphion::Engine g_engine;

// Every live event reaches the engine through the audio callback, which moves this queue into
// the engine at the start of each engine block and, while recording, logs each event with that
// block's first sample: where it took effect. One producer at a time: the touch thread, or the
// main thread holding g_touchMutex.
static morphion::SpscQueue<morphion::Event, 1024> g_input;

static const CGFloat kTitlebar = 52;   // the content runs under the transparent title bar (with toolbar)
// Full screen has no title bar (the toolbar is hidden, the menu bar slides over on demand):
// only a strip at the top for the player, drawn larger to match the larger pan.
static bool g_fullscreen = false;
static CGFloat titlebar() { return g_fullscreen ? 68 : kTitlebar; }
static CGFloat ui() { return g_fullscreen ? 1.3 : 1.0; }   // the player's scale

static std::atomic<bool> g_captured{false};

// Set when the app can't play (no trackpad, no multitouch support, no audio): the window
// opens anyway and shows this instead of the pan, so a double-clicked app doesn't just vanish.
struct StartupError { NSString* title; NSString* detail; };
static StartupError g_error{nil, nil};
static const StartupError kNoTrackpad{@"No trackpad found", @"morphion is played on a trackpad. Connect a Magic Trackpad and it will start."};
static bool g_scanTrackpads = false;   // multitouch and audio are up: look for trackpads every 2 s

struct UiTouch { float nx, ny, major, minor, angle, size; int state; int device = 0; };
static std::mutex g_uiMutex;
static std::vector<UiTouch> g_uiTouches;
static std::array<std::atomic<double>, 9> g_flashTime;
static std::atomic<double> g_slapTime{0.0};   // for a brief flash of the whole pan
static std::array<std::atomic<float>, 9> g_flashForce;
static std::array<float, 9> g_round{};      // how far each note's outline has rounded (0..1), smoothed
static bool g_roundPreview = false;         // --snapshot sets g_round directly (no audio)
static double g_clock = -1.0;               // --frames runs on its own clock
static int g_waves = 4;                     // ripple waves round a note for the fundamental (x2, x3 for octave, twelfth)
static double g_wobbleDiv = 40.0;           // ripple speed: the ding's fundamental swings at 146.83 Hz / this
static double g_wobbleExp = 0.0;            // how ripple speed follows pitch: 1 proportional, 0.5 sqrt, 0 the same for all
static double g_rippleSizeExp = 0.0;        // how ripple size falls with pitch: 0.5 sqrt, 0 the same for all
static double nowSec() { return g_clock >= 0.0 ? g_clock : CFAbsoluteTimeGetCurrent(); }

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
    return std::clamp(0.15f * t.majorAxis / g_cfg.majorRef, 0.05f, 0.8f);
}

// Timestamped lines on stderr for sleep/wake, audio device and trackpad events: run
// mac/build/morphion from Terminal to see them (the robustness tests in plans/).
static void logEvent(const char* fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    NSString* t = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle
                                                timeStyle:NSDateFormatterMediumStyle];
    std::fprintf(stderr, "[%s] %s\n", t.UTF8String, buf);
}
static std::atomic<bool> g_logNextFrame{true};   // log the first touch frame at start and after each wake

// Every trackpad gets a slot; touch ids are only unique per device, so a touch's id becomes
// slot * 1000 + its identifier. Slots are written on the main thread, read here.
constexpr int kMaxDevices = 8;
static std::array<std::atomic<MTDeviceRef>, kMaxDevices> g_devSlot{};
static std::mutex g_touchMutex;   // devices may call back on their own threads; the engine queue has one producer
// A touch's size is its signal summed over the electrodes under it, so trackpads with larger
// electrodes read heavier for the same finger. Each device's sizes are scaled by the electrode
// area of the trackpad the force mapping was tuned on (a 14" MacBook Pro: 124.8 x 76.8 mm over
// 24 x 18, 22.2 mm2) over its own (Magic Trackpad 2: 156.0 x 110.4 mm over 30 x 22, 26.1 mm2).
static std::array<std::atomic<float>, kMaxDevices> g_devSizeScale{};
constexpr double kRefElectrodeMm2 = (124.8 / 24) * (76.8 / 18);

static float sizeScaleFor(MTDeviceRef d) {
    int rows = 0, cols = 0, w = 0, h = 0;
    if (!MTDeviceGetSensorDimensions || !MTDeviceGetSensorSurfaceDimensions) return 1.0f;
    MTDeviceGetSensorDimensions(d, &rows, &cols);
    MTDeviceGetSensorSurfaceDimensions(d, &w, &h);
    if (rows <= 0 || cols <= 0 || w <= 0 || h <= 0) return 1.0f;
    double area = (w / 100.0 / cols) * (h / 100.0 / rows);
    return float(std::clamp(kRefElectrodeMm2 / area, 0.5, 2.0));
}

static int touchCallback(MTDeviceRef dev, const MTTouch* touches, int n, double, int) {
    std::lock_guard<std::mutex> serial(g_touchMutex);
    int slot = 0;
    for (int k = 0; k < kMaxDevices; ++k) if (g_devSlot[k].load() == dev) { slot = k; break; }
    if (g_logNextFrame.exchange(false)) logEvent("touch frames arriving from trackpad %d (%d contacts)", slot, n);
    bool live = g_captured.load();
    for (auto& t : g_tracks) if (t.id / 1000 == slot) t.seen = false;   // other devices' touches aren't in this frame

    for (int i = 0; i < n; ++i) {
        MTTouch t = touches[i];
        t.identifier += slot * 1000;
        t.size *= g_devSizeScale[slot].load(std::memory_order_relaxed);
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
                g_input.push({morphion::Event::Down, t.identifier, tr->field, fx, fy, force, contactMs, contactRadius(t)});
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
            if (live) g_input.push({morphion::Event::Move, t.identifier, tr->field, fx, fy, 0, 0, contactRadius(t)});
        } else if (!contact && tr->down) {
            tr->down = false;
            g_input.push({morphion::Event::Up, t.identifier, 0, 0, 0, 0, 0, 0});
        }
    }

    for (auto& t : g_tracks) {
        if (t.used && !t.seen && t.id / 1000 == slot) {
            if (t.down) g_input.push({morphion::Event::Up, t.id, 0, 0, 0, 0, 0, 0});
            t.used = false;
        }
    }

    std::lock_guard<std::mutex> lock(g_uiMutex);
    std::erase_if(g_uiTouches, [&](const UiTouch& u) { return u.device == slot; });
    for (int i = 0; i < n; ++i) {
        const MTTouch& t = touches[i];
        g_uiTouches.push_back({t.normalized.pos.x, t.normalized.pos.y, t.majorAxis, t.minorAxis, t.angle, t.size, t.state, slot});
    }
    return 0;
}

// ---------------------------------------------------------------- audio

static AudioUnit g_unit;
// Trackpads being listened to (main thread), one per slot. Rescanned every 2 s and whenever
// IOKit reports a multitouch device arriving or leaving (see watchTrackpads), so a Magic
// Trackpad connected, reconnected or switched between USB and Bluetooth while the app runs
// keeps playing. A trackpad's device ID differs between USB and Bluetooth, and a device
// object kept from before a disconnect can still claim to be running, so a trackpad that
// drops out of the list is stopped and forgotten, and starts fresh when it comes back.
struct MtDevice { MTDeviceRef ref = nullptr; uint64_t id = 0; };
static std::array<MtDevice, kMaxDevices> g_devices{};

static uint64_t deviceId(MTDeviceRef d) {
    uint64_t id = 0;
    if (MTDeviceGetDeviceID) MTDeviceGetDeviceID(d, &id);
    return id ? id : uint64_t(uintptr_t(d));
}

static void startDevice(MTDeviceRef d, int slot) {
    CFRetain(d);
    g_devSizeScale[slot] = sizeScaleFor(d);
    g_devSlot[slot] = d;
    g_devices[slot] = {d, deviceId(d)};
    MTRegisterContactFrameCallback(d, touchCallback);
    MTDeviceStart(d, 0);
    g_logNextFrame = true;
}

// Stop a slot's device and lift any of its fingers still down (no more frames will come).
static void dropDevice(int slot) {
    MtDevice& m = g_devices[slot];
    if (!m.ref) return;
    MTUnregisterContactFrameCallback(m.ref, touchCallback);
    MTDeviceStop(m.ref);
    CFRelease(m.ref);
    {
        std::lock_guard<std::mutex> serial(g_touchMutex);   // the engine queue's one producer at a time
        g_devSlot[slot] = nullptr;
        for (auto& t : g_tracks) {
            if (t.used && t.id / 1000 == slot) {
                if (t.down) g_input.push({morphion::Event::Up, t.id, 0, 0, 0, 0, 0, 0});
                t.used = false;
            }
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_uiMutex);
        std::erase_if(g_uiTouches, [&](const UiTouch& u) { return u.device == slot; });
    }
    m = {};
}

static int playingCount() {
    int n = 0;
    for (const auto& m : g_devices) n += m.ref != nullptr;
    return n;
}

// Start any trackpad not yet playing, or one that stopped; forget any that are gone. Returns
// the number of trackpads playing.
static int scanDevices() {
    if (!MTDeviceCreateList) {   // fall back to the default device only
        if (!g_devices[0].ref) {
            if (MTDeviceRef d = MTDeviceCreateDefault()) {
                startDevice(d, 0);
                CFRelease(d);
            }
        }
        return playingCount();
    }
    CFArrayRef list = MTDeviceCreateList();
    if (!list) return playingCount();
    const CFIndex n = CFArrayGetCount(list);
    std::vector<uint64_t> ids(n);
    for (CFIndex i = 0; i < n; ++i) ids[i] = deviceId((MTDeviceRef)CFArrayGetValueAtIndex(list, i));
    for (int k = 0; k < kMaxDevices; ++k) {
        if (g_devices[k].ref && std::find(ids.begin(), ids.end(), g_devices[k].id) == ids.end()) {
            logEvent("trackpad %d (id %llx) gone", k, (unsigned long long)g_devices[k].id);
            dropDevice(k);
        }
    }
    for (CFIndex i = 0; i < n; ++i) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        int slot = -1;
        for (int k = 0; k < kMaxDevices; ++k) if (g_devices[k].ref && g_devices[k].id == ids[i]) slot = k;
        if (slot >= 0) {
            if (!MTDeviceIsRunning || MTDeviceIsRunning(g_devices[slot].ref)) continue;
            dropDevice(slot);
            startDevice(d, slot);
            logEvent("trackpad %d (id %llx) restarted, touch sizes x%.2f", slot, (unsigned long long)ids[i], g_devSizeScale[slot].load());
            continue;
        }
        for (int k = 0; k < kMaxDevices; ++k) if (!g_devices[k].ref) { slot = k; break; }
        if (slot < 0) continue;
        startDevice(d, slot);
        logEvent("trackpad %d (id %llx) playing, touch sizes x%.2f", slot, (unsigned long long)ids[i], g_devSizeScale[slot].load());
    }
    CFRelease(list);
    return playingCount();
}

// Rescan shortly after IOKit sees a multitouch device arrive or leave (the multitouch list
// catches up a moment later), so a quick unplug and replug isn't missed between timer scans.
static void scanSoon() {
    for (double delay : {0.5, 1.5})
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (scanDevices() > 0 && g_error.title == kNoTrackpad.title) g_error = {nil, nil};
        });
}

static void trackpadsChanged(void*, io_iterator_t it) {
    while (io_object_t o = IOIteratorNext(it)) IOObjectRelease(o);   // drain, which also re-arms the notification
    scanSoon();
}

static void watchTrackpads() {
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
    for (const char* type : {kIOFirstMatchNotification, kIOTerminatedNotification}) {
        io_iterator_t it = 0;
        if (IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleMultitouchDevice"), trackpadsChanged,
                                             nullptr, &it) == KERN_SUCCESS) {
            while (io_object_t o = IOIteratorNext(it)) IOObjectRelease(o);   // the devices already there
        }
    }
}

// Stop touch input and audio before the process exits. [NSApp run] never returns:
// terminate: calls exit(), and static destructors (the engine) would otherwise run
// while the touch and audio threads are still calling into them.
static void shutdown() {
    static bool done = false;
    if (done) return;
    done = true;
    for (auto& d : g_devices) {
        if (!d.ref) continue;
        MTUnregisterContactFrameCallback(d.ref, touchCallback);
        MTDeviceStop(d.ref);
    }
    if (g_unit) {
        AudioOutputUnitStop(g_unit);
        AudioUnitUninitialize(g_unit);
        AudioComponentInstanceDispose(g_unit);
        g_unit = nullptr;
    }
}

// The engine always runs at the score format's rate; CoreAudio converts to the device's.
static const double g_sr = morphion::score::kRate;

// A score file playing (see playScore): set and cleared only while the audio unit is stopped.
static std::unique_ptr<morphion::score::Piece> g_piece;
static std::unique_ptr<morphion::score::Player> g_player;
static std::atomic<int64_t> g_playPos{0};   // how far the player has got, in samples
static std::atomic<bool> g_playGo{false};    // the count-in is over: the player runs

// Recording: the audio thread logs every event it hands the engine to g_take (drained on the
// main thread, see drainTake), stamped with the sample where it took effect.
struct Stamped { int64_t sample; morphion::Event e; };
static morphion::SpscQueue<Stamped, 65536> g_takeQueue;   // drained 60 times a second: minutes of headroom
static std::atomic<bool> g_recording{false};
static std::atomic<int> g_takeDropped{0};
static int64_t g_pos = 0;   // audio thread: samples handed out since the engine was configured
static std::atomic<int64_t> g_livePos{0};   // the next block's first sample, for the main thread

static void feedInput() {
    const bool rec = g_recording.load(std::memory_order_acquire);
    const int64_t at = g_engine.nextBlockSample();
    morphion::Event e;
    while (g_input.pop(e)) {
        g_engine.push(e);
        if (rec && !g_takeQueue.push({at, e})) g_takeDropped.fetch_add(1, std::memory_order_relaxed);
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
    if (g_player) {   // a score plays; the trackpad doesn't
        morphion::Event e;
        while (g_input.pop(e)) {}
        if (!g_playGo.load(std::memory_order_acquire)) {   // counting in: silence, the engine untouched
            std::memset(left, 0, frames * sizeof(float));
            if (right) std::memset(right, 0, frames * sizeof(float));
            return noErr;
        }
        g_player->process(left, right, (int)frames);
        g_playPos.store(g_engine.nextBlockSample(), std::memory_order_relaxed);
        return noErr;
    }
    // one engine block at a time, so each block's events go in just before it (as the player does)
    for (int done = 0; done < (int)frames;) {
        int into = int(g_pos % morphion::Engine::kBlock);
        if (into == 0) feedInput();
        int n = std::min((int)frames - done, morphion::Engine::kBlock - into);
        g_engine.process(left + done, right ? right + done : nullptr, n);
        g_pos += n;
        done += n;
    }
    g_livePos.store(g_engine.nextBlockSample(), std::memory_order_relaxed);
    return noErr;
}

// The user's settings as a score header: what configures the engine, and what a recording carries.
static morphion::score::Settings scoreSettings() {
    morphion::score::Settings s;
    s.scale = g_set.scale;
    s.key = g_set.key;
    s.gain = g_set.gain;
    s.sustain = g_set.sustain;
    s.swell = g_set.coupling;
    s.tilt = g_set.tilt;
    s.gu = g_set.gu;
    s.guHz = g_cfg.guHz;
    s.gap = g_cfg.gap;
    s.gap2x = g_cfg.gap2x;
    s.mute = g_set.mute;
    s.muteFloor = g_cfg.muteFloor;
    s.stereo = g_set.stereo;
    s.attack = g_set.attack;
    s.reverb = g_set.reverb;
    return s;
}

// Settings the engine reads live (atomics): safe to change while playing.
static void applyLiveSettings() {
    g_engine.gain = g_set.gain;
    g_engine.restStrength = g_set.mute;
    g_engine.restFloor = g_cfg.muteFloor;
    g_engine.coupling = g_set.coupling;
    g_engine.radiationTilt = g_set.tilt;
    g_engine.stereoWidth = g_set.stereo;
    g_engine.attackLevel = g_set.attack;
    g_engine.reverb = g_set.reverb;
    g_sizeHard = g_set.sizeHard;
}

// Fields, links, cavity: Engine::configure allocates, so the audio unit must be stopped.
// Configured exactly as a score with these settings is played, so a recording replays bit for bit.
static void configureEngine() {
    morphion::score::Piece p;
    p.settings = scoreSettings();
    morphion::score::configure(g_engine, p);
    g_sizeHard = g_set.sizeHard;
    g_pos = 0;
    for (const auto& l : g_engine.links()) {
        double f = g_engine.fieldFreq(l.dst);
        std::printf("link: %s drives %s at %dx; %s retuned to %.2f Hz (%+.1f cents)\n", g_layout.name[l.src],
                    g_layout.name[l.dst], l.order, g_layout.name[l.dst], f,
                    1200.0 * std::log2(f / g_layout.freq[l.dst]));
    }
}

// Scale, key, sustain or cavity changed: rebuild the fields. Ringing notes are cut.
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

    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = g_sr;   // the output unit resamples to the device's rate when they differ
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

    configureEngine();

    AURenderCallbackStruct cb = {renderCallback, nullptr};
    AudioUnitSetProperty(g_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (AudioUnitInitialize(g_unit) != noErr || AudioOutputUnitStart(g_unit) != noErr) return false;
    double devSr = hw.mSampleRate > 0 ? hw.mSampleRate : g_sr;
    std::printf("audio: engine %.0f Hz, device %.0f Hz, buffer %d frames (%.1f ms)\n", g_sr, devSr, g_cfg.buffer,
                1000.0 * g_cfg.buffer / devSr);
    return true;
}

// ---------------------------------------------------------------- recording and score playback (main thread)

using morphion::score::Line;

// A recording in progress. It starts from a freshly configured engine, as a score does, so
// it replays bit for bit; settings can't change during it (the pane only opens when stopped).
struct Take {
    bool on = false;
    double started = 0;                    // wall clock, for the time shown
    morphion::score::Settings settings;
    std::vector<Line> lines;
    std::vector<int> held;                 // fingers down in the take
};
static Take g_take;

// Move what the audio thread logged into the take. Lifts and slides of fingers that were
// already down when recording started are left out; the engine ignores them anyway.
static void drainTake() {
    Stamped st;
    while (g_takeQueue.pop(st)) {
        if (!g_take.on) continue;
        const morphion::Event& e = st.e;
        Line l;
        l.sample = st.sample;
        l.finger = e.finger;
        auto held = std::find(g_take.held.begin(), g_take.held.end(), e.finger);
        switch (e.type) {
        case morphion::Event::Down:
            l.kind = Line::Down;
            l.field = e.field;
            l.x = e.x, l.y = e.y, l.force = e.force, l.contactMs = e.contactMs, l.radius = e.radius;
            if (held == g_take.held.end()) g_take.held.push_back(e.finger);
            break;
        case morphion::Event::Move:
            if (held == g_take.held.end()) continue;
            l.kind = Line::Move;
            l.x = e.x, l.y = e.y, l.radius = e.radius;
            break;
        case morphion::Event::Up:
            if (held == g_take.held.end()) continue;
            l.kind = Line::Up;
            g_take.held.erase(held);
            break;
        case morphion::Event::Slap:
            l.kind = Line::Slap;
            l.force = e.force;
            break;
        }
        g_take.lines.push_back(l);
    }
}

static void startRecording() {
    if (g_take.on || !g_unit) return;
    // a fresh engine (ringing notes are cut), recording from its first block: the flag is up
    // before audio restarts, so nothing reaches the engine unlogged
    buildLayout();
    AudioOutputUnitStop(g_unit);
    configureEngine();
    g_livePos = 0;
    Stamped st;
    while (g_takeQueue.pop(st)) {}
    g_take = Take{};
    g_take.on = true;
    g_take.started = CFAbsoluteTimeGetCurrent();
    g_take.settings = scoreSettings();
    g_takeDropped = 0;
    g_recording.store(true, std::memory_order_release);
    AudioOutputUnitStart(g_unit);
    logEvent("recording");
}

// End the take and return it as a score file, or "" if nothing was played.
static std::string finishTake() {
    if (!g_take.on) return {};
    g_recording.store(false, std::memory_order_release);
    const int64_t stop = g_livePos.load(std::memory_order_relaxed);
    drainTake();
    g_take.on = false;
    std::vector<Line>& L = g_take.lines;
    if (int lost = g_takeDropped.load()) logEvent("recording: %d events lost (queue full)", lost);
    logEvent("recording stopped: %zu events", L.size());
    if (L.empty()) return {};
    for (int f : g_take.held) {   // still down when recording stopped: lift them there
        Line up;
        up.kind = Line::Up;
        up.finger = f;
        up.sample = std::max(stop, L.back().sample);
        L.push_back(up);
    }
    // start at the first event: an idle engine renders silence exactly, so this changes nothing
    const int64_t first = L.front().sample;
    for (Line& l : L) l.sample -= first;
    morphion::score::Piece p;
    p.settings = g_take.settings;
    p.lines = std::move(L);
    std::string text = morphion::score::write(p);
    NSString* when = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterLongStyle
                                                    timeStyle:NSDateFormatterShortStyle];
    text.insert(text.find('\n') + 1, std::string("# recorded ") + when.UTF8String + "\n");
    return text;
}

static void saveTake(NSWindow* window, const std::string& text) {
    NSString* scale = [[[NSString stringWithUTF8String:kScales[g_take.settings.scale].name] lowercaseString]
        stringByReplacingOccurrencesOfString:@" " withString:@"-"];
    NSString* key = [[[NSString stringWithUTF8String:kKeys[g_take.settings.key]] lowercaseString]
        stringByReplacingOccurrencesOfString:@"#" withString:@"s"];
    NSDateFormatter* df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd-HHmm";
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[ UTTypePlainText ];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"%@-%@-%@.txt", scale, key, [df stringFromDate:[NSDate date]]];
    panel.message = @" ";   // blank: a sheet has no top margin without a message line
    NSString* body = [NSString stringWithUTF8String:text.c_str()];
    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSError* err = nil;
        if (![body writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&err])
            [[NSAlert alertWithError:err] beginSheetModalForWindow:window completionHandler:nil];
    }];
}

// A score file playing: the pan is the file's, drawn from its events as the player reaches them.
struct Playback {
    bool on = false;
    NSString* name = nil;
    double length = 0;                     // seconds to the last event
    double goAt = 0;                       // wall clock: the count-in ends and the score starts
    size_t next = 0;                       // the next line to draw
    struct Dot { int finger, field; float x, y, radius; double down; bool up; };
    std::vector<Dot> dots;                 // fingers on the pan
};
static Playback g_play;

static void stopScore(NSWindow* window) {
    if (!g_play.on) return;
    g_play = Playback{};
    AudioOutputUnitStop(g_unit);
    g_playGo = false;
    g_player.reset();
    g_piece.reset();
    buildLayout();   // the user's own pan and settings again
    configureEngine();
    AudioOutputUnitStart(g_unit);
    window.title = layoutTitle();
}

static void playScore(NSURL* url, NSWindow* window) {
    if (!g_unit) return;
    NSString* name = url.lastPathComponent;
    auto fail = [&](NSString* why) {
        NSAlert* a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Can't Play %@", name];
        a.informativeText = why;
        [a beginSheetModalForWindow:window completionHandler:nil];
    };
    NSError* err = nil;
    NSString* text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&err];
    if (!text) { fail(err.localizedDescription); return; }
    auto piece = std::make_unique<morphion::score::Piece>();
    std::string why;
    if (!morphion::score::parse(text.UTF8String, *piece, why)) {
        fail([NSString stringWithUTF8String:why.c_str()]);
        return;
    }
    const morphion::score::Settings& ps = piece->settings;
    AudioOutputUnitStop(g_unit);
    g_player.reset();
    g_piece = std::move(piece);
    morphion::score::configure(g_engine, *g_piece);
    g_player = std::make_unique<morphion::score::Player>(g_engine, *g_piece);
    g_playPos = 0;
    g_playGo = false;
    AudioOutputUnitStart(g_unit);
    buildLayout(ps.scale, ps.key);
    g_play = Playback{};
    g_play.on = true;
    g_play.name = name.stringByDeletingPathExtension;
    g_play.length = double(g_piece->end()) / morphion::score::kRate;
    g_play.goAt = CFAbsoluteTimeGetCurrent() + 3.0;   // a 3, 2, 1 count-in
    for (int i = 0; i < 9; ++i) g_flashTime[i] = 0.0;
    window.title = [NSString stringWithFormat:@"morphion: %@", name];
    logEvent("playing %s (%zu events, %.1f s)", name.UTF8String, g_piece->lines.size(), g_play.length);
}

// Each frame: draw the events the player has reached; stop once the last has rung out.
static void tickPlayback(NSWindow* window) {
    if (!g_play.on) return;
    const double now = CFAbsoluteTimeGetCurrent();
    if (!g_playGo.load(std::memory_order_relaxed)) {
        if (now < g_play.goAt) return;
        g_playGo.store(true, std::memory_order_release);
    }
    const int64_t pos = g_playPos.load(std::memory_order_relaxed);
    const auto& lines = g_piece->lines;
    auto dot = [&](int finger) {
        return std::find_if(g_play.dots.begin(), g_play.dots.end(), [&](const auto& d) { return d.finger == finger && !d.up; });
    };
    for (; g_play.next < lines.size() && lines[g_play.next].sample <= pos; ++g_play.next) {
        const Line& l = lines[g_play.next];
        switch (l.kind) {
        case Line::Down:
            g_flashTime[l.field] = now;
            g_flashForce[l.field] = l.force;
            g_play.dots.push_back({l.finger, l.field, l.x, l.y, l.radius, now, false});
            break;
        case Line::Move:
            if (auto d = dot(l.finger); d != g_play.dots.end()) d->x = l.x, d->y = l.y, d->radius = l.radius;
            break;
        case Line::Up:
            if (auto d = dot(l.finger); d != g_play.dots.end()) d->up = true;
            break;
        case Line::Slap: g_slapTime = now; break;
        case Line::Set: break;
        }
    }
    // a lifted finger stays drawn for at least 80 ms, so a tap written as an instant shows
    std::erase_if(g_play.dots, [&](const auto& d) { return d.up && now - d.down > 0.08; });
    if (g_play.next < lines.size() || pos < g_piece->end() + int64_t(morphion::score::kRate)) return;
    for (int i = 0; i < g_engine.fieldCount(); ++i)
        if (g_engine.fieldLevel(i) > 3e-4f) return;   // still ringing (above -70 dB)
    if (g_engine.outputLevel() > 1e-4f) return;       // or the reverb, the Gu or a slap still sounds (-80 dB)
    logEvent("finished playing");
    stopScore(window);
}

static std::string clockText(double seconds) {
    int s = int(std::max(0.0, seconds));
    char b[16];
    std::snprintf(b, sizeof b, "%d:%02d", s / 60, s % 60);
    return b;
}

// While playing, the title bar is a player: stop (Esc) at the right; in the middle, record (R)
// playing live, or a score's name and time.
static NSFont* scoreNameFont() { return [NSFont systemFontOfSize:13 * ui() weight:NSFontWeightSemibold]; }
static NSFont* scoreTimeFont() { return [NSFont monospacedDigitSystemFontOfSize:13 * ui() weight:NSFontWeightRegular]; }
static NSString* scoreTime(double t, double length) {
    return [NSString stringWithFormat:@"%s / %s", clockText(std::min(t, length)).c_str(), clockText(length).c_str()];
}
static NSFont* keyFont() { return [NSFont systemFontOfSize:11 * ui() weight:NSFontWeightSemibold]; }
static NSFont* pillFont() { return [NSFont systemFontOfSize:13 * ui() weight:NSFontWeightMedium]; }
static NSFont* takeTimeFont() { return [NSFont monospacedDigitSystemFontOfSize:13 * ui() weight:NSFontWeightSemibold]; }
static CGFloat badgeWidth(NSString* key) {
    return std::max<CGFloat>(18 * ui(), std::ceil([key sizeWithAttributes:@{NSFontAttributeName : keyFont()}].width + 10 * ui()));
}
// A link's contents: the label, 8 pt, the key badge (scaled by ui()).
static CGFloat pillContentWidth(NSString* label, NSFont* font, NSString* key) {
    return std::ceil([label sizeWithAttributes:@{NSFontAttributeName : font}].width) +
           std::ceil(8 * ui()) + badgeWidth(key);
}
static void overlayRects(NSRect b, NSRect* stop, NSRect* rec) {
    const CGFloat k = ui(), h = 30 * k, mid = b.size.height - titlebar() / 2, pad = 6 * k;
    const CGFloat sw = pillContentWidth(@"Exit", pillFont(), @"esc") + 2 * pad;
    const CGFloat rw = pillContentWidth(@"Record", pillFont(), @"r") + 2 * pad;
    // stop at the right; record in the middle playing live (where a score shows its name)
    const CGFloat right = b.size.width - (g_fullscreen ? 40 : 18) + pad, y = std::round(mid - h / 2);
    if (stop) *stop = NSMakeRect(right - sw, y, sw, h);
    if (rec) *rec = g_play.on ? NSZeroRect : NSMakeRect(std::round(NSMidX(b) - rw / 2), y, rw, h);
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
    if (!on) {   // stopping ends a recording: offer to save it
        std::string take = finishTake();
        if (!take.empty()) saveTake(window, take);
    }
}

@interface PadView : NSView
@property bool hoverInfo, hoverPlay, hoverOpen, hoverGear, hoverStop, settingsOpen, infoOpen;
@end

static NSRect padRect(NSRect b) {
    CGFloat margin = 18;
    return NSMakeRect(margin, margin, b.size.width - 2 * margin, b.size.height - 2 * margin - titlebar());
}

static NSColor* rgb(double r, double g, double b, double a = 1.0) {
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a];
}
static NSColor* ink() { return rgb(0.07, 0.07, 0.075); }      // background, and text on light
static NSColor* amber(double a = 1.0) { return rgb(1.0, 0.76, 0.40, a); }

// Info, Play, open a score (the folder) and the settings gear sit side by side on a light
// strip across the middle of the window, drawn like the notes (no system styling).
static void startRects(NSRect bounds, NSRect* info, NSRect* play, NSRect* open, NSRect* gear) {
    NSRect pad = padRect(bounds);
    const int cells = 3;
    CGFloat cw = pad.size.width / cells, ch = pad.size.height / cells;
    CGFloat w = std::clamp(cw * 0.5, 160.0, 320.0), h = std::clamp(ch * 0.32, 52.0, 88.0), gap = 14;
    CGFloat x0 = std::round(NSMidX(pad) - (w + 3 * (gap + h)) / 2), y = std::round(NSMidY(pad) - h / 2);
    if (info) *info = NSMakeRect(x0, y, h, h);
    if (play) *play = NSMakeRect(x0 + h + gap, y, w, h);
    if (open) *open = NSMakeRect(x0 + h + gap + w + gap, y, h, h);
    if (gear) *gear = NSMakeRect(x0 + h + gap + w + 2 * gap + h, y, h, h);
}

// ---------------------------------------------------------------- settings pane

// Controls are laid out while drawing and hit-tested on click, so drawing and input
// always agree. Choice rows are pills (selected = amber); sliders are a line and a knob.
enum CtlId { kCtlScale, kCtlKey, kCtlReverb, kCtlGain, kCtlSustain, kCtlSizeHard, kCtlMute, kCtlSwell, kCtlTilt, kCtlGu,
             kCtlStereo, kCtlAttack, kCtlSlap, kCtlReset, kCtlDone };
struct Ctl {
    CtlId id;
    int choice = -1;        // for choice pills
    NSRect r;               // pill / button / slider track hit area
    double lo = 0, hi = 1;  // sliders
};
struct SliderDef { CtlId id; const char* label; double lo, hi; float Settings::*field; const char* fmt; };
static const char* const kReverbNames[] = {"Dry", "Small room", "Medium room", "Hall", "Stairwell"};
static_assert(std::size(kReverbNames) == morphion::kReverbCount);
static const SliderDef kSliders[] = {
    {kCtlGain, "Volume", 0.2, 2.0, &Settings::gain, "%.2f"},
    {kCtlSustain, "Sustain", 0.5, 3.0, &Settings::sustain, "%.2fx"},
    {kCtlSizeHard, "Hit sensitivity", 2.0, 0.5, &Settings::sizeHard, "%.2f"},   // reversed: right is a lighter touch
    {kCtlMute, "Resting mute", 0.0, 1.5, &Settings::mute, "%.2f"},
    {kCtlSwell, "Sympathetic swell", 0.0, 3.0, &Settings::coupling, "%.2f"},
    {kCtlTilt, "Low / high balance", -0.5, 0.5, &Settings::tilt, "%+.2f"},
    {kCtlGu, "Gu cavity", 0.0, 0.4, &Settings::gu, "%.2f"},
    {kCtlStereo, "Stereo width", 0.0, 1.0, &Settings::stereo, "%.2f"},
    {kCtlAttack, "Strike click", 0.0, 2.0, &Settings::attack, "%.2f"},
    {kCtlSlap, "Slap", 0.0, 2.0, &Settings::slap, "%.2f"},
};
static const char* sliderHint(CtlId id) {
    switch (id) {
    case kCtlSustain: return "how long notes ring";
    case kCtlSizeHard: return "how forcefully a light touch hits";
    case kCtlMute: return "how fast a resting finger stops a note";
    case kCtlSwell: return "how strongly notes ring in sympathy";
    case kCtlTilt: return "negative favors the low notes";
    case kCtlGu: return "the air resonance under the ding";
    case kCtlStereo: return "how far the side notes sit left and right";
    case kCtlAttack: return "the finger-on-metal click of a strike";
    case kCtlSlap: return "how loud Space slaps the shell";
    default: return "";
    }
}

static std::vector<Ctl> g_ctls;
static int g_dragSlider = -1;

// Centered in the whole window. Its top padding is empty, so at small window heights it can
// run a little under the title bar (clear of the traffic lights, which sit left of it).
static NSRect paneRect(NSRect b) {
    CGFloat w = std::min<CGFloat>(700, b.size.width - 40), h = std::min<CGFloat>(540, b.size.height - 80);
    return NSMakeRect(std::round(NSMidX(b) - w / 2), std::round(NSMidY(b) - h / 2), w, h);
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
    choiceRow(@"Reverb", kCtlReverb, morphion::kReverbCount,
              [](int i) { return [NSString stringWithUTF8String:kReverbNames[i]]; }, g_set.reverb);
    y -= 8;

    // sliders in two columns: label and value on top, track, hint underneath
    const int n = int(sizeof(kSliders) / sizeof(kSliders[0]));
    const CGFloat colGap = 36, colW = (right - left - colGap) / 2, cellH = 60;
    for (int i = 0; i < n; ++i) {
        const SliderDef& sd = kSliders[i];
        CGFloat cx = left + (i % 2) * (colW + colGap), cy = y - (i / 2) * cellH;
        double v = g_set.*(sd.field);
        drawText([NSString stringWithUTF8String:sd.label], NSMakePoint(cx, cy - 16), 13, labelC, NSFontWeightMedium);
        char buf[16];
        // hit sensitivity shows as the default touch size over this one: 1.00 by default, higher is lighter
        std::snprintf(buf, sizeof buf, sd.fmt, sd.id == kCtlSizeHard ? Settings{}.sizeHard / v : v);
        NSString* vs = [NSString stringWithUTF8String:buf];
        NSDictionary* vat = @{NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular]};
        CGFloat vw = [vs sizeWithAttributes:vat].width;
        [vs drawAtPoint:NSMakePoint(cx + colW - vw, cy - 16)
            withAttributes:@{NSFontAttributeName : vat[NSFontAttributeName],
                             NSForegroundColorAttributeName : [NSColor colorWithWhite:0.85 alpha:1]}];
        CGFloat trackX = cx, trackW = colW, ty = cy - 30;   // the track runs under the label and value, edge to edge
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

// ---------------------------------------------------------------- info panel

// The score guide (scores/AGENTS.md), copied into the bundle by the Makefile: what Copy guide
// for AI puts on the clipboard. Found beside the icon, also through the build/morphion symlink.
static NSString* scoreGuide() {
    static NSString* guide = [] {
        NSString* exe = [NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath];
        NSString* path = [[[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"Resources/score-guide.md"];
        return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    }();
    return guide;
}

static NSRect g_infoCopy, g_infoDone, g_infoTab[2];
static int g_infoTabOn = 0;
static double g_copiedAt = -10.0;

// The panel's wording, on two tabs (kInfoTabs). [key] is drawn as a key badge, as on the title
// bar's links, and *text* is set in italics (the name of a button). A section titled @"" is an introduction, a little larger; one with no title (nil)
// is a sample score, in monospace.
static NSString* const kInfoTabs[] = {@"Playing", @"Recording"};
struct InfoSection { NSString* title; NSString* body; int tab; };
static const InfoSection kInfo[] = {
    {@"", @"A virtual handpan you play on a Mac trackpad. The sound is generated by a real-time physics engine and "
          @"is responsive to how hard you tap (via contact area), how long you hold your finger, and where on the "
          @"note you play. No audio recordings are used for playing.", 0},
    {@"", @"Try letting a note ring, then resting a finger on it to quiet it.", 0},
    {@"Play", @"Click Play or press [return] to start. The cursor hides so your taps land on the pan. Press [esc] "
              @"to stop.", 0},
    {@"Strike", @"Tap harder for a louder, brighter sound. Try different spots on a note to hear its tone change. "
                @"Rest a finger on the note to mute it.", 0},
    {@"Slap", @"Press [space] to slap the shell between the notes.", 0},
    {@"Settings", @"Open the gear to choose a scale and key, or adjust the sound and how the pan responds to your "
                  @"touch.", 0},
    {@"Record", @"While playing, press [r] to start recording. Press [r] again or [esc] to stop, then choose where "
                @"to save the take. Each recording starts with a fresh pan. Anything still ringing is cut off.", 1},
    {@"Open a score", @"Click the folder button, press [\u2318O] or drop a file on the window. A countdown "
                      @"leads into the score, using its scale, key and settings. Press [esc] to stop.", 1},
    {@"The file", @"A score is a plain text file with settings and timed strikes, slaps and finger movements. "
                  @"A recording replays exactly as it sounded. You can edit a score or write one by hand.", 1},
    {nil, @"# morphion " MORPHION_VERSION "\nscale = Kurd\nkey = D\n0.000   D3   0.70\n0.500   A3   0.40  hold 250\n"
          @"1.000   slap 0.60", 1},
    {@"Write one with AI", @"Click *Copy guide for AI* and paste the guide into a chat with an AI model. Ask for a "
                           @"piece, then save the reply as a .txt file and open it here.", 1},
};

// A key badge as an inline image: light fill, dark text, sitting on the text's baseline.
static NSAttributedString* keyBadge(NSString* key, NSFont* body) {
    NSDictionary* at = @{NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                         NSForegroundColorAttributeName : ink()};
    NSSize ts = [key sizeWithAttributes:at];
    const CGFloat h = 18, w = std::max<CGFloat>(18, std::ceil(ts.width) + 10);
    NSImage* img = [NSImage imageWithSize:NSMakeSize(w, h) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor colorWithWhite:0.86 alpha:1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:4 yRadius:4] fill];
        [key drawAtPoint:NSMakePoint((w - ts.width) / 2, (h - ts.height) / 2) withAttributes:at];
        return YES;
    }];
    NSTextAttachment* a = [NSTextAttachment new];
    a.image = img;
    a.bounds = NSMakeRect(0, std::round((body.capHeight - h) / 2), w, h);   // centered on the capitals
    return [NSAttributedString attributedStringWithAttachment:a];
}

// One tab's text, laid out for drawing and measuring.
static NSAttributedString* infoText(int tab) {
    NSMutableParagraphStyle* para = [NSMutableParagraphStyle new];
    para.paragraphSpacing = 12;
    para.lineSpacing = 2;
    NSMutableParagraphStyle* head = [NSMutableParagraphStyle new];
    head.paragraphSpacing = 4;
    NSFont* hf = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    NSFont* bf = [NSFont systemFontOfSize:13];
    NSColor* hc = [NSColor colorWithWhite:0.92 alpha:1];
    NSColor* bc = [NSColor colorWithWhite:0.68 alpha:1];
    NSMutableAttributedString* t = [NSMutableAttributedString new];
    auto plain = [&](NSString* run, NSFont* f, NSColor* c, NSParagraphStyle* ps) {   // *text* in italics
        NSArray<NSString*>* parts = [run componentsSeparatedByString:@"*"];
        NSFont* it = [NSFontManager.sharedFontManager convertFont:f toHaveTrait:NSItalicFontMask];
        for (NSUInteger i = 0; i < parts.count; ++i)
            [t appendAttributedString:[[NSAttributedString alloc]
                                          initWithString:parts[i]
                                              attributes:@{NSFontAttributeName : i % 2 ? it : f, NSForegroundColorAttributeName : c,
                                                           NSParagraphStyleAttributeName : ps}]];
    };
    auto add = [&](NSString* str, NSFont* f, NSColor* c, NSParagraphStyle* ps) {
        NSDictionary* at = @{NSFontAttributeName : f, NSForegroundColorAttributeName : c, NSParagraphStyleAttributeName : ps};
        // [key] becomes a badge
        NSScanner* sc = [NSScanner scannerWithString:str];
        sc.charactersToBeSkipped = nil;
        while (!sc.atEnd) {
            NSString* run = nil;
            if ([sc scanUpToString:@"[" intoString:&run]) plain(run, f, c, ps);
            if (sc.atEnd) break;
            sc.scanLocation += 1;
            NSString* key = nil;
            if ([sc scanUpToString:@"]" intoString:&key] && !sc.atEnd) {
                sc.scanLocation += 1;
                NSMutableAttributedString* badge = [keyBadge(key, f) mutableCopy];
                [badge addAttributes:@{NSParagraphStyleAttributeName : ps} range:NSMakeRange(0, badge.length)];
                [t appendAttributedString:badge];
            } else {
                [t appendAttributedString:[[NSAttributedString alloc]
                                              initWithString:[@"[" stringByAppendingString:key ?: @""] attributes:at]];
            }
        }
    };
    NSFont* mono = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    for (const auto& sec : kInfo) {
        if (sec.tab != tab) continue;
        if (!sec.title) {   // one paragraph, its lines broken with line separators, so the spacing comes after it
            NSString* code = [sec.body stringByReplacingOccurrencesOfString:@"\n" withString:@"\u2028"];
            [t appendAttributedString:[[NSAttributedString alloc]
                                          initWithString:[code stringByAppendingString:@"\n"]
                                              attributes:@{NSFontAttributeName : mono, NSForegroundColorAttributeName : amber(0.85),
                                                           NSParagraphStyleAttributeName : para}]];
            continue;
        }
        if (sec.title.length == 0) {   // the introduction
            add([sec.body stringByAppendingString:@"\n"], [NSFont systemFontOfSize:14], [NSColor colorWithWhite:0.82 alpha:1], para);
            continue;
        }
        add([sec.title stringByAppendingString:@"\n"], hf, hc, head);
        add([sec.body stringByAppendingString:@"\n"], bf, bc, para);
    }
    if (t.length && [t.string hasSuffix:@"\n"]) [t deleteCharactersInRange:NSMakeRange(t.length - 1, 1)];   // no empty line at the end
    return t;
}

// The panel fits its tab's text, centered in the window. Never taller than the settings pane's room.
static const CGFloat kInfoHead = 24 + 40, kInfoFoot = 20 + 30 + 16;
static NSRect infoRect(NSRect b) {
    NSRect pr = paneRect(b);
    const CGFloat textW = pr.size.width - 56, room = b.size.height - 80;
    NSRect r = [infoText(g_infoTabOn) boundingRectWithSize:NSMakeSize(textW, 10000) options:NSStringDrawingUsesLineFragmentOrigin];
    CGFloat h = std::min<CGFloat>(room, kInfoHead + std::ceil(r.size.height) + kInfoFoot);
    return NSMakeRect(pr.origin.x, std::round(NSMidY(b) - h / 2), pr.size.width, h);
}

// About morphion: how to play, and (second tab) how to record and open scores, with the guide
// to give an AI model. Drawn like the settings pane.
static void drawInfo(NSRect b) {
    [[NSColor colorWithWhite:0 alpha:0.6] setFill];
    NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
    NSRect pr = infoRect(b);
    NSBezierPath* panel = [NSBezierPath bezierPathWithRoundedRect:pr xRadius:18 yRadius:18];
    [rgb(0.10, 0.10, 0.105) setFill];
    [panel fill];
    [[NSColor colorWithWhite:0.35 alpha:1] setStroke];
    panel.lineWidth = 1.2;
    [panel stroke];

    const CGFloat left = pr.origin.x + 28, right = NSMaxX(pr) - 28;
    CGFloat y = NSMaxY(pr) - 24;
    drawText(@"morphion", NSMakePoint(left, y - 22), 18, [NSColor colorWithWhite:0.95 alpha:1], NSFontWeightSemibold);
    // the tabs, at the top right
    CGFloat tx = right;
    for (int k = 1; k >= 0; --k) {
        NSDictionary* tat = @{NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]};
        CGFloat w = std::ceil([kInfoTabs[k] sizeWithAttributes:tat].width) + 26;
        tx -= w;
        g_infoTab[k] = drawPill(kInfoTabs[k], tx, y - 26, 26, k == g_infoTabOn, 12);
        tx -= 6;
    }
    y = NSMaxY(pr) - kInfoHead;
    const CGFloat footer = pr.origin.y + kInfoFoot;
    [infoText(g_infoTabOn) drawWithRect:NSMakeRect(left, footer, right - left, y - footer)
                                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];

    // footer: copy the guide on the left, done on the right
    CGFloat fy = pr.origin.y + 20;
    bool copied = CFAbsoluteTimeGetCurrent() - g_copiedAt < 2.0;
    g_infoCopy = g_infoTabOn == 1 && scoreGuide() ? drawPill(copied ? @"Copied" : @"Copy guide for AI", left, fy, 30, copied)
                                                  : NSZeroRect;
    NSDictionary* at = @{NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightMedium]};
    CGFloat doneW = std::ceil([@"Done" sizeWithAttributes:at].width) + 26;
    g_infoDone = drawPill(@"Done", right - doneW, fy, 30, true);
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
    NSRect stop;
    overlayRects(self.bounds, &stop, nullptr);
    self.hoverStop = g_play.on && NSPointInRect(p, stop);
    if (g_error.title) return;
    NSRect info, play, open, gear;
    startRects(self.bounds, &info, &play, &open, &gear);
    bool idle = !self.settingsOpen && !self.infoOpen && !g_play.on;
    self.hoverInfo = idle && NSPointInRect(p, info);
    self.hoverPlay = idle && NSPointInRect(p, play);
    self.hoverOpen = idle && NSPointInRect(p, open);
    self.hoverGear = idle && NSPointInRect(p, gear);
}
- (void)mouseExited:(NSEvent*)e { self.hoverInfo = self.hoverPlay = self.hoverOpen = self.hoverGear = self.hoverStop = false; }

// Cmd-O, the folder button: pick a score file and play it.
- (void)openScore:(id)sender {
    if (g_take.on) { setCaptured(false, self.window); return; }   // save the recording first
    setCaptured(false, self.window);
    if (self.settingsOpen) [self closeSettings];
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[ UTTypePlainText ];
    panel.message = @" ";   // blank: a sheet has no top margin without a message line
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK) playScore(panel.URL, self.window);
    }];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item { return item.action != @selector(openScore:) || g_unit; }

// A score file dropped on the window plays.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    return g_unit && !g_take.on && !self.settingsOpen ? NSDragOperationCopy : NSDragOperationNone;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSURL* url = [NSURL URLFromPasteboard:info.draggingPasteboard];
    if (!url || g_take.on) return NO;
    setCaptured(false, self.window);
    playScore(url, self.window);
    return YES;
}

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
    NSRect stop;
    overlayRects(self.bounds, &stop, nullptr);
    if (g_play.on && NSPointInRect(p, stop)) {
        self.hoverStop = false;
        stopScore(self.window);
        return;
    }
    if (g_error.title || (!g_fullscreen && p.y > self.bounds.size.height - kTitlebar)) {   // the strip under the title bar drags the window
        [self.window performWindowDragWithEvent:e];
        return;
    }
    if (self.infoOpen) {
        if (!NSPointInRect(p, infoRect(self.bounds)) || NSPointInRect(p, g_infoDone)) self.infoOpen = false;
        else if (NSPointInRect(p, g_infoTab[0])) g_infoTabOn = 0;
        else if (NSPointInRect(p, g_infoTab[1])) g_infoTabOn = 1;
        else if (NSPointInRect(p, g_infoCopy) && scoreGuide()) {
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:scoreGuide() forType:NSPasteboardTypeString];
            g_copiedAt = CFAbsoluteTimeGetCurrent();
        }
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
            case kCtlReverb: g_set.reverb = c.choice; applyLiveSettings(); break;
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
    if (g_captured.load() || g_play.on) return;
    NSRect info, play, open, gear;
    startRects(self.bounds, &info, &play, &open, &gear);
    if (NSPointInRect(p, info)) {
        self.hoverInfo = false;
        self.infoOpen = true;
    } else if (NSPointInRect(p, play)) {
        self.hoverPlay = false;
        setCaptured(true, self.window);
    } else if (NSPointInRect(p, open)) {
        self.hoverOpen = false;
        [self openScore:nil];
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
    if (e.keyCode == 53 && g_play.on) {   // Esc: stop the score
        stopScore(self.window);
        return;
    }
    if (g_error.title || g_play.on) return;
    if (e.keyCode == 53) {   // Esc: close info or settings, or stop playing
        if (self.infoOpen) self.infoOpen = false;
        else if (self.settingsOpen) [self closeSettings];
        else setCaptured(false, self.window);
        return;
    }
    if (e.keyCode == 15 && g_captured.load() && !e.isARepeat) {   // R: record; again to stop and save
        if (g_take.on) setCaptured(false, self.window);
        else startRecording();
        return;
    }
    if ((e.keyCode == 36 || e.keyCode == 76) && !g_captured.load() && !self.settingsOpen && !self.infoOpen) {   // Return / Enter: play
        self.hoverPlay = false;
        setCaptured(true, self.window);
        return;
    }
    if (e.keyCode == 49 && g_captured.load()) {   // Space: slap the shell (keys have no velocity: fixed force)
        if (!e.isARepeat) {
            std::lock_guard<std::mutex> serial(g_touchMutex);   // g_input's one producer at a time
            g_input.push({morphion::Event::Slap, 0, 0, 0, 0, 0.8f * g_set.slap, 0, 0});
            g_slapTime = CFAbsoluteTimeGetCurrent();
        }
        return;
    }
    [super keyDown:e];
}

// A note's outline while it rings. The corners grow from the resting radius into the
// half-width and half-height (at m = 1 the note is the ellipse inscribed in it), and the
// outline ripples: standing waves running round the edge, one per main mode, with g_waves,
// twice and three times as many waves round the note for the fundamental, octave and
// twelfth (the 1:2:3 of their pitches). d0, d1, d2 are each wave's current displacement in points, along the normal.
static NSBezierPath* morphedNote(NSRect fr, CGFloat rad, double m, double d0 = 0, double d1 = 0, double d2 = 0) {
    const double a = fr.size.width / 2, b = fr.size.height / 2, cx = NSMidX(fr), cy = NSMidY(fr);
    const double rx = rad + (a - rad) * m, ry = rad + (b - rad) * m;
    if (std::fabs(d0) + std::fabs(d1) + std::fabs(d2) < 0.05)
        return [NSBezierPath bezierPathWithRoundedRect:fr xRadius:rx yRadius:ry];
    // walk the outline counterclockwise from the right edge, a straight run then a quarter
    // ellipse for each side, points about 1.5 pt apart, noting the distance traveled
    struct P { double x, y, nx, ny, s; };
    std::vector<P> pts;
    double s = 0;
    auto put = [&](double x, double y, double nx, double ny) {
        if (!pts.empty()) s += std::hypot(x - pts.back().x, y - pts.back().y);
        pts.push_back({x, y, nx, ny, s});
    };
    const double sx[4] = {1, -1, -1, 1}, sy[4] = {1, 1, -1, -1};   // corner quadrants, counterclockwise from top right
    for (int q = 0; q < 4; ++q) {
        double ox = cx + sx[q] * (a - rx), oy = cy + sy[q] * (b - ry);   // corner ellipse center
        bool vertical = q % 2 == 0;   // the straight side leading into this corner
        double len = vertical ? 2 * (b - ry) : 2 * (a - rx);
        int n = std::max(1, int(len / 1.5));
        for (int i = 0; i < n; ++i) {
            double t = double(i) / n;
            if (vertical) put(cx + sx[q] * a, oy - sy[q] * len * (1 - t), sx[q], 0);
            else put(ox - sx[q] * len * (1 - t), cy + sy[q] * b, 0, sy[q]);
        }
        int k = std::max(16, int((rx + ry) * 1.2));
        for (int i = 0; i < k; ++i) {
            double th = q * M_PI / 2 + M_PI / 2 * i / k, c = std::cos(th), sn = std::sin(th);
            double nx = c / rx, ny = sn / ry, nl = std::hypot(nx, ny);
            put(ox + rx * c, oy + ry * sn, nx / nl, ny / nl);
        }
    }
    const double perimeter = s + std::hypot(pts.front().x - pts.back().x, pts.front().y - pts.back().y);
    NSBezierPath* p = [NSBezierPath bezierPath];
    for (size_t i = 0; i < pts.size(); ++i) {
        double u = 2 * M_PI * pts[i].s / perimeter;   // whole numbers of waves, so the ripple closes
        const int w = g_waves;
        double d = d0 * std::sin(w * u) + d1 * std::sin(2 * w * u) + d2 * std::sin(3 * w * u);
        NSPoint pt = NSMakePoint(pts[i].x + pts[i].nx * d, pts[i].y + pts[i].ny * d);
        if (i == 0) [p moveToPoint:pt]; else [p lineToPoint:pt];
    }
    [p closePath];
    p.lineJoinStyle = NSLineJoinStyleRound;
    return p;
}

// Target roundness from how loudly the note rings: -50 dB square, 0 dB (the hardest hit)
// the roundest. A gentle term carries light and medium hits, a steep one lifts firm and
// hard hits; fitted so light, medium and firm ding strikes peak near 0.19, 0.32 and 0.52.
static double roundnessFor(float level) {
    double db = 20.0 * std::log10(level + 1e-9);
    double x = std::clamp((db + 50.0) / 50.0, 0.0, 1.0);
    return 0.85 * (0.44 * std::pow(x, 1.6) + 0.56 * std::pow(x, 12.0));
}

// Ripple size in points for one mode's level: nothing at -60 dB, maxPts at -4 dB.
static double wobbleFor(float level, double maxPts) {
    double db = 20.0 * std::log10(level + 1e-9);
    return maxPts * std::pow(std::clamp((db + 60.0) / 56.0, 0.0, 1.0), 1.5);
}

// The title bar while playing: stop at the right; in the middle, record playing live, or a
// score's name and time, filling the line under the bar as it plays. Live playing hides the cursor, so
// the links show their keys.
- (void)drawPlayer:(NSRect)b {
    NSRect stop, rec;
    overlayRects(b, &stop, &rec);
    const CGFloat mid = NSMidY(stop), k = ui();
    NSColor* soft = [NSColor colorWithWhite:0.82 alpha:1];
    auto text = [&](NSString* t, CGFloat x, NSFont* f, NSColor* c) {
        NSDictionary* at = @{NSFontAttributeName : f, NSForegroundColorAttributeName : c};
        NSSize ts = [t sizeWithAttributes:at];
        [t drawAtPoint:NSMakePoint(x, mid - ts.height / 2) withAttributes:at];
        return ts.width;
    };

    // a key on a small light badge
    auto badge = [&](NSString* key, CGFloat x) {
        NSDictionary* at = @{NSFontAttributeName : keyFont(), NSForegroundColorAttributeName : ink()};
        NSSize ts = [key sizeWithAttributes:at];
        NSRect r = NSMakeRect(x, mid - 9 * k, badgeWidth(key), 18 * k);
        [[NSColor colorWithWhite:0.86 alpha:1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:4 * k yRadius:4 * k] fill];
        [key drawAtPoint:NSMakePoint(NSMidX(r) - ts.width / 2, mid - ts.height / 2) withAttributes:at];
    };
    // a link's contents, against the right of its hit area or centered in it: a label and a key badge
    auto contents = [&](NSRect r, NSString* label, NSFont* font, NSString* key, NSColor* fg, bool centered = false) {
        CGFloat w = pillContentWidth(label, font, key);
        CGFloat x = std::round(centered ? NSMidX(r) - w / 2 : NSMaxX(r) - 6 * k - w);
        x += std::ceil(text(label, x, font, fg)) + std::ceil(8 * k);
        badge(key, x);
    };

    // stop: Exit, esc
    NSColor* fg = self.hoverStop ? amber() : soft;   // links, not buttons: hover lights the text
    contents(stop, @"Exit", pillFont(), @"esc", fg);

    if (g_play.on) {
        double t = double(g_playPos.load(std::memory_order_relaxed)) / morphion::score::kRate;
        NSString* name = g_play.name ?: @"";   // the score's name and time, centered
        CGFloat x = std::round(NSMidX(b) - ([name sizeWithAttributes:@{NSFontAttributeName : scoreNameFont()}].width + 12 * k +
                                            [scoreTime(g_play.length, g_play.length)
                                                sizeWithAttributes:@{NSFontAttributeName : scoreTimeFont()}].width) / 2);
        x += text(name, x, scoreNameFont(), soft) + 12 * k;
        text(scoreTime(t, g_play.length), x, scoreTimeFont(), [NSColor colorWithWhite:0.55 alpha:1]);
        [amber() setFill];   // over the title bar's line: how far the score has got
        double done = std::clamp(g_play.length > 0 ? t / g_play.length : 1.0, 0.0, 1.0);
        NSRectFill(NSMakeRect(0, b.size.height - titlebar(), b.size.width * done, 2));
        return;
    }

    // record: Record, r; recording, the time in red
    NSColor* red = rgb(0.95, 0.27, 0.23);
    const bool on = g_take.on;
    const double t = on ? CFAbsoluteTimeGetCurrent() - g_take.started : 0;
    contents(rec, on ? [NSString stringWithUTF8String:clockText(t).c_str()] : @"Record",
                          on ? takeTimeFont() : pillFont(), @"r", on ? red : soft, true);
}

// The canvas: clean outlines, no gradients. Each note is a rounded-rectangle outline
// inside its grid cell (its hit area is the full cell). A strike fills that note in
// solid amber, stronger for harder hits, fading out; touches show a patch of dot mesh.
// While a note rings (struck or in sympathy) its outline rounds toward an ellipse.
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSRect pad = padRect(b);
    bool live = g_captured.load() || g_play.on;
    const int cells = 3;
    double dim = live ? 1.0 : 0.45;   // outlines fade while not playing

    [ink() setFill];
    NSRectFill(b);

    if (g_error.title && !g_play.on) {   // can't play: say why, centered, in place of the pan
        NSMutableParagraphStyle* centered = [NSMutableParagraphStyle new];
        centered.alignment = NSTextAlignmentCenter;
        NSDictionary* head = @{NSFontAttributeName : [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold],
                               NSForegroundColorAttributeName : [NSColor colorWithWhite:0.92 alpha:1],
                               NSParagraphStyleAttributeName : centered};
        NSDictionary* body = @{NSFontAttributeName : [NSFont systemFontOfSize:15],
                               NSForegroundColorAttributeName : [NSColor colorWithWhite:0.62 alpha:1],
                               NSParagraphStyleAttributeName : centered};
        CGFloat w = std::min<CGFloat>(440, b.size.width - 80);
        NSRect hr = [g_error.title boundingRectWithSize:NSMakeSize(w, 1000) options:NSStringDrawingUsesLineFragmentOrigin attributes:head];
        NSRect br = [g_error.detail boundingRectWithSize:NSMakeSize(w, 1000) options:NSStringDrawingUsesLineFragmentOrigin attributes:body];
        CGFloat gap = 12, total = hr.size.height + gap + br.size.height, top = NSMidY(b) + total / 2;
        [g_error.title drawWithRect:NSMakeRect(NSMidX(b) - w / 2, top - hr.size.height, w, hr.size.height)
                            options:NSStringDrawingUsesLineFragmentOrigin attributes:head];
        [g_error.detail drawWithRect:NSMakeRect(NSMidX(b) - w / 2, top - hr.size.height - gap - br.size.height, w, br.size.height)
                             options:NSStringDrawingUsesLineFragmentOrigin attributes:body];
        return;
    }

    [[NSColor colorWithWhite:0.2 alpha:1] setFill];   // the line under the title bar
    NSRectFill(NSMakeRect(0, b.size.height - titlebar(), b.size.width, 2));
    if (live) [self drawPlayer:b];

    double now = nowSec();
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

            if (!g_roundPreview) {   // rise within a frame or two, settle a little slower
                double target = live ? roundnessFor(g_engine.fieldLevel(field)) : 0.0;
                g_round[field] += float((target - g_round[field]) * (target > g_round[field] ? 0.6 : 0.2));
            }
            // ripple: the fundamental, octave and twelfth swing at 1:2:3 of a base speed of
            // 146.83 / g_wobbleDiv = 3.7 Hz, scaled across notes by (pitch / 146.83)^g_wobbleExp
            // (0: the same on every note). Capped at 15 Hz, four frames a cycle: the eye stops
            // seeing small motion near 15-20 Hz. Each note starts at its own phase.
            // Size goes as (D4 / pitch)^g_rippleSizeExp: steel at equal loudness moves further on
            // lower notes (as 1 / pitch); 0.5 gives ding 1.41x, F4 0.92x; 0 the same on every note.
            double d0 = 0, d1 = 0, d2 = 0;
            if (live && field < g_engine.fieldCount()) {
                double hz = g_engine.fieldFreq(field), f1 = 146.83 * std::pow(hz / 146.83, g_wobbleExp) / g_wobbleDiv, off = field * 1.7;
                double size = std::pow(293.66 / hz, g_rippleSizeExp);
                auto swing = [&](int n) { return std::sin(2 * M_PI * std::min(n * f1, 15.0) * now + n * off); };
                d0 = wobbleFor(g_engine.modeLevel(field, 0), 2.1 * size) * swing(1);
                d1 = wobbleFor(g_engine.modeLevel(field, 1), 3.5 * size) * swing(2);
                d2 = wobbleFor(g_engine.modeLevel(field, 2), 2.8 * size) * swing(3);
            }
            NSBezierPath* note = morphedNote(fr, rad, g_round[field], d0, d1, d2);
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

    if (g_play.on && !g_playGo.load(std::memory_order_relaxed)) {   // the count-in: 3, 2, 1 over the pan
        double left = g_play.goAt - now;
        if (left > 0) {
            int n = int(std::ceil(left));
            double frac = left - (n - 1);   // 1 -> 0 through each number
            NSString* digit = [NSString stringWithFormat:@"%d", std::min(n, 3)];
            NSDictionary* at = @{NSFontAttributeName : [NSFont systemFontOfSize:std::min(pad.size.width, pad.size.height) * 0.3
                                                                         weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName : amber(0.25 + 0.75 * frac)};
            NSSize ds = [digit sizeWithAttributes:at];
            [digit drawAtPoint:NSMakePoint(NSMidX(pad) - ds.width / 2, NSMidY(pad) - ds.height / 2) withAttributes:at];
        }
    }

    if (!live && !self.settingsOpen && !self.infoOpen) {
        // a solid strip across the window behind Play and the buttons, so they stand apart from the pan
        NSRect info, play, open, gear;
        startRects(b, &info, &play, &open, &gear);
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

        auto round = [&](NSRect r, bool hover, NSString* symbol, NSString* what, CGFloat size) {
            NSBezierPath* rb = [NSBezierPath bezierPathWithOvalInRect:r];
            if (hover) {
                [amber() setFill];
                [rb fill];
            }
            [ink() setStroke];
            rb.lineWidth = 2;
            [rb stroke];
            NSImageSymbolConfiguration* sc = [[NSImageSymbolConfiguration configurationWithPointSize:r.size.height * size
                                                                                              weight:NSFontWeightMedium]
                configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[ ink() ]]];
            NSImage* icon = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:what]
                imageWithSymbolConfiguration:sc];
            NSSize is = icon.size;
            [icon drawInRect:NSMakeRect(NSMidX(r) - is.width / 2, NSMidY(r) - is.height / 2, is.width, is.height)];
        };
        round(info, self.hoverInfo, @"info", @"About morphion", 0.42);
        round(open, self.hoverOpen, @"folder", @"Open a score", 0.36);
        round(gear, self.hoverGear, @"gearshape", @"Settings", 0.42);
    }

    if (self.settingsOpen) drawPane(b);
    if (self.infoOpen) drawInfo(b);

    // touches in contact: a patch of dot mesh; only while playing (a score's fingers when it plays)
    std::vector<UiTouch> touches;
    if (g_play.on) {
        for (const auto& d : g_play.dots) {
            float nx, ny;
            fieldToPad(d.field, d.x, d.y, nx, ny);
            float major = d.radius * g_cfg.majorRef / 0.15f;   // contactRadius inverted
            touches.push_back({nx, ny, major, major * 0.85f, 0.0f, 1.0f, 4});
        }
    } else if (live) {
        std::lock_guard<std::mutex> lock(g_uiMutex);
        touches = g_uiTouches;
    }
    for (const auto& t : touches) {
        CGFloat x = pad.origin.x + t.nx * pad.size.width, y = pad.origin.y + t.ny * pad.size.height;
        CGFloat rx = std::max(4.0f, t.major * 2.0f), ry = std::max(4.0f, t.minor * 2.0f);
        bool contact = (t.state == 3 || t.state == 4);
        if (!contact) continue;   // hovering fingers aren't drawn
        // a dot mesh fixed to the pad shows through where the finger presses, at full strength
        // inside 0.6x the touch's ellipse and fading out by 1.95x its size. With pull > 0 the mesh
        // dents: dots are pulled toward the middle (most at the center, none beyond the fade).
        const CGFloat step = 5.0, reach = 1.95, pull = 0.0;   // pull > 0 dents the mesh (0.1 subtle)
        const double ca = std::cos(t.angle), sa = std::sin(t.angle);
        CGFloat R = std::max(rx, ry) * reach;
        long i0 = long(std::floor((x - R - pad.origin.x) / step)), i1 = long(std::ceil((x + R - pad.origin.x) / step));
        long j0 = long(std::floor((y - R - pad.origin.y) / step)), j1 = long(std::ceil((y + R - pad.origin.y) / step));
        for (long i = i0; i <= i1; ++i) {
            for (long j = j0; j <= j1; ++j) {
                CGFloat gx = pad.origin.x + i * step, gy = pad.origin.y + j * step;
                double dx = gx - x, dy = gy - y;
                double lx = dx * ca + dy * sa, ly = -dx * sa + dy * ca;   // into the touch's own axes
                double d = std::hypot(lx / rx, ly / ry);
                if (d >= reach) continue;
                double k = std::clamp((reach - d) / (reach - 0.6), 0.0, 1.0);
                k = k * k * (3 - 2 * k);
                double squeeze = 1.0 - pull * std::exp(-d * d / 0.8) * (1.0 - d / reach);
                CGFloat px = x + dx * squeeze, py = y + dy * squeeze;
                CGFloat r = 0.5 + 0.6 * k;
                [[NSColor colorWithWhite:1 alpha:0.9 * k] setFill];
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(px - r, py - r, 2 * r, 2 * r)] fill];
            }
        }
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
    self.window.contentMinSize = NSMakeSize(760, 620);   // room for the settings pane
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
    NSWindow* window = self.window;
    // in the common modes, so it keeps draining a take while a menu or a drag tracks the mouse
    NSTimer* frame = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer*) {
        drainTake();
        tickPlayback(window);
        [view setNeedsDisplay:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:frame forMode:NSRunLoopCommonModes];
    [view registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:NSWindowWillEnterFullScreenNotification object:window queue:nil usingBlock:^(NSNotification*) {
        g_fullscreen = true;
        window.toolbar.visible = NO;
    }];
    [nc addObserverForName:NSWindowWillExitFullScreenNotification object:window queue:nil usingBlock:^(NSNotification*) {
        g_fullscreen = false;
        window.toolbar.visible = YES;
    }];

    // pick up trackpads connected (or reconnected) while running
    if (g_scanTrackpads) {
        watchTrackpads();
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer*) {
            if (scanDevices() > 0 && g_error.title == kNoTrackpad.title) g_error = {nil, nil};
        }];
    }

    // log sleep, wake and output-device changes, for the robustness tests
    NSNotificationCenter* wc = NSWorkspace.sharedWorkspace.notificationCenter;
    [wc addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil
                usingBlock:^(NSNotification*) { logEvent("sleeping"); }];
    [wc addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil usingBlock:^(NSNotification*) {
        logEvent("woke; touch the trackpad to check frames still arrive");
        g_logNextFrame = true;
    }];
    AudioObjectPropertyAddress def = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                      kAudioObjectPropertyElementMain};
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &def, dispatch_get_main_queue(),
                                        ^(UInt32, const AudioObjectPropertyAddress*) {
        AudioObjectID dev = 0;
        UInt32 size = sizeof dev;
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &def, 0, nullptr, &size, &dev);
        Float64 rate = 0;
        AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        size = sizeof rate;
        AudioObjectGetPropertyData(dev, &ra, 0, nullptr, &size, &rate);
        logEvent("default output device changed (device %u, %.0f Hz; engine runs at %.0f Hz)", dev, rate, g_sr);
    });
}
- (void)applicationDidResignActive:(NSNotification*)n { setCaptured(false, self.window); }
// Quitting mid-recording stops it and offers to save it instead; quit again afterwards.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)a {
    if (!g_take.on) return NSTerminateNow;
    setCaptured(false, self.window);
    return NSTerminateCancel;
}
- (void)applicationWillTerminate:(NSNotification*)n {
    setCaptured(false, self.window);
    shutdown();
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a { return YES; }
@end

// ---------------------------------------------------------------- main

static void usage() {
    std::fprintf(stderr,
                 "usage: morphion [--probe] [--mute X] [--mute-floor X] [--size-soft X] [--size-hard X]\n"
                 "                [--force-curve X] [--soft-ms X] [--hard-ms X] [--major-ref X]\n"
                 "                [--gain X] [--buffer N] [--coupling X] [--gap HZ] [--gap-2x HZ]\n"
                 "                [--tilt X] [--gu X] [--gu-hz HZ] [--snapshot DIR] [--frames DIR] [--waves N] [--wobble-div X] [--wobble-exp X]\n"
                 "                [--ripple-size-exp X]\n");
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
    g_roundPreview = true;
    g_round[4] = 0.8f;  g_round[1] = 0.35f;  g_round[3] = 0.2f;
    {
        std::lock_guard<std::mutex> lock(g_uiMutex);
        g_uiTouches = {{0.52f, 0.47f, 11.0f, 8.0f, 2.1f, 1.0f, 4}, {0.20f, 0.80f, 7.5f, 6.9f, 1.57f, 0.3f, 1}};
    }
    save(@"playing.png");
    g_take.on = true;
    g_take.started = now - 42;
    save(@"recording.png");
    g_take = Take{};
    g_captured = false;
    g_play.on = true;
    g_play.name = @"kurd-d-a-score";
    g_play.length = 130;
    g_playPos = int64_t(42 * morphion::score::kRate);
    g_play.dots = {{1, 4, 0.2f, 0.1f, 0.12f, now, false}, {2, 6, -0.3f, 0.2f, 0.18f, now, false}};
    g_playGo = true;
    save(@"score.png");
    g_playGo = false;
    g_play.goAt = CFAbsoluteTimeGetCurrent() + 1.6;
    save(@"count-in.png");
    g_playGo = true;
    g_fullscreen = true;
    save(@"score-fullscreen.png");
    g_play = Playback{};
    g_playGo = false;
    g_captured = true;
    save(@"playing-fullscreen.png");
    g_fullscreen = false;
    g_captured = false;
    view.settingsOpen = true;
    save(@"settings.png");
    view.settingsOpen = false;
    view.infoOpen = true;
    save(@"info.png");
    g_infoTabOn = 1;
    save(@"info-recording.png");
    g_infoTabOn = 0;
    view.infoOpen = false;
    view.settingsOpen = false;
    g_error = kNoTrackpad;
    save(@"error.png");
    g_error = {nil, nil};
    return 0;
}

// Run the engine offline and draw the canvas at 60 fps to <dir>/frame_NNNN.png (no audio,
// no trackpad), for judging the note animation. Default settings, D Kurd grid.
static int frames(const char* dir) {
    [NSApplication sharedApplication];
    g_set = Settings{};
    buildLayout();
    configureEngine();
    NSRect frame = NSMakeRect(0, 0, 900, 640);
    PadView* view = [[PadView alloc] initWithFrame:frame];
    g_captured = true;
    for (int i = 0; i < 9; ++i) { g_flashTime[i] = -10.0; g_flashForce[i] = 0.0f; }
    g_slapTime = -10.0;
    struct Hit { double t; int field; float x, y, force; };
    // the ding near its center, then hard and near the edge (more octave), then D4 at its edge,
    // then F4 (the highest) with the ding, to compare speeds
    const Hit hits[] = {{0.2, 4, 0.15f, 0.1f, 0.7f}, {2.6, 4, 0.6f, 0.1f, 0.9f}, {5.0, 3, 0.6f, 0.0f, 0.7f},
                        {7.2, 0, 0.5f, 0.0f, 0.8f}, {7.2, 4, 0.5f, 0.0f, 0.8f}};
    const double seconds = 9.5, fps = 60.0;
    const int block = 64;
    std::vector<float> buf(block), audio;
    long done = 0;
    size_t next = 0;
    for (int f = 0; f < int(seconds * fps); ++f) {
        double t = f / fps;
        while (next < std::size(hits) && hits[next].t <= t) {
            const Hit& h = hits[next++];
            float ms = 1.6f - 0.7f * (h.force - 0.1f) / 0.9f;
            g_engine.push({morphion::Event::Down, int(next), h.field, h.x, h.y, h.force, ms, 0.12f});
            g_engine.push({morphion::Event::Up, int(next), 0, 0, 0, 0, 0, 0});
            g_flashTime[h.field] = t;
            g_flashForce[h.field] = h.force;
        }
        for (long target = long(t * g_sr); done < target; done += block) {
            g_engine.process(buf.data(), nullptr, block);
            audio.insert(audio.end(), buf.begin(), buf.end());
        }
        g_clock = t;
        NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:frame];
        [view cacheDisplayInRect:frame toBitmapImageRep:rep];
        NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString* name = [NSString stringWithFormat:@"frame_%04d.png", f];
        [png writeToFile:[[NSString stringWithUTF8String:dir] stringByAppendingPathComponent:name] atomically:YES];
    }
    // and the sound of the same run, 16-bit mono, for muxing with the frames
    std::string wav = std::string(dir) + "/audio.wav";
    if (FILE* fp = std::fopen(wav.c_str(), "wb")) {
        uint32_t sr = uint32_t(g_sr), bytes = uint32_t(audio.size() * 2), riff = 36 + bytes, fmtLen = 16, rate = sr * 2;
        uint16_t pcm = 1, ch = 1, align = 2, bits = 16;
        std::fwrite("RIFF", 1, 4, fp); std::fwrite(&riff, 4, 1, fp); std::fwrite("WAVEfmt ", 1, 8, fp);
        std::fwrite(&fmtLen, 4, 1, fp); std::fwrite(&pcm, 2, 1, fp); std::fwrite(&ch, 2, 1, fp);
        std::fwrite(&sr, 4, 1, fp); std::fwrite(&rate, 4, 1, fp); std::fwrite(&align, 2, 1, fp); std::fwrite(&bits, 2, 1, fp);
        std::fwrite("data", 1, 4, fp); std::fwrite(&bytes, 4, 1, fp);
        for (float v : audio) { int16_t x = int16_t(std::clamp(v, -1.0f, 1.0f) * 32767.0f); std::fwrite(&x, 2, 1, fp); }
        std::fclose(fp);
    }
    std::printf("wrote %d frames and audio.wav to %s\n", int(seconds * fps), dir);
    return 0;
}

// Play random touches through the real audio callback and recorder, in uneven host buffers,
// save the take as a score file, replay that file and compare: they must match sample for sample.
static int checkRecording() {
    g_set = Settings{};
    g_set.scale = 2;
    g_set.key = 4;
    g_set.gu = 0.25f;
    g_set.reverb = 3;
    buildLayout();
    configureEngine();
    g_take = Take{};
    g_take.on = true;
    g_take.settings = scoreSettings();
    g_recording = true;
    uint32_t rng = 1;
    auto rnd = [&] { rng = rng * 1664525u + 1013904223u; return (rng >> 8) / double(1 << 24); };
    std::vector<float> L(2048), R(2048), live;
    struct { AudioBufferList list; AudioBuffer second; } io;
    io.list.mNumberBuffers = 2;
    int fingers[4] = {}, nextId = 1;
    for (int64_t pos = 0; pos < 20 * 48000;) {
        if (pos > 12000) {   // silence first: the take starts at its first event
            for (int k = 0; k < 4; ++k) {
                float x = float(rnd() * 1.2 - 0.6), y = float(rnd() * 1.2 - 0.6), r = float(0.08 + rnd() * 0.1);
                if (!fingers[k] && rnd() < 0.01) {
                    fingers[k] = nextId++;
                    float force = float(0.1 + 0.9 * rnd());
                    g_input.push({morphion::Event::Down, fingers[k], int(rnd() * 9), x, y, force, 1.6f - 0.7f * force, r});
                } else if (fingers[k] && rnd() < 0.3) {
                    g_input.push({morphion::Event::Move, fingers[k], 0, x, y, 0, 0, r});
                } else if (fingers[k] && rnd() < 0.05) {
                    g_input.push({morphion::Event::Up, fingers[k], 0, 0, 0, 0, 0, 0});
                    fingers[k] = 0;
                }
            }
            if (rnd() < 0.003) g_input.push({morphion::Event::Slap, 0, 0, 0, 0, float(0.3 + rnd() * 0.6), 0, 0});
        }
        UInt32 n = 1 + UInt32(rnd() * 700);
        io.list.mBuffers[0] = {1, n * 4, L.data()};
        io.second = {1, n * 4, R.data()};
        renderCallback(nullptr, nullptr, nullptr, 0, n, &io.list);
        for (UInt32 i = 0; i < n; ++i) { live.push_back(L[i]); live.push_back(R[i]); }
        pos += n;
        drainTake();
    }
    const int64_t first = g_take.lines.empty() ? 0 : g_take.lines.front().sample;
    std::string text = finishTake();
    morphion::score::Piece piece;
    std::string err;
    if (!morphion::score::parse(text, piece, err)) { std::printf("recording doesn't parse: %s\n", err.c_str()); return 1; }
    morphion::score::configure(g_engine, piece);
    morphion::score::Player player(g_engine, piece);
    size_t frames = live.size() / 2 - size_t(first), mismatch = 0;
    std::vector<float> l(frames), r(frames);
    player.process(l.data(), r.data(), int(frames));
    for (size_t i = 0; i < frames; ++i)
        mismatch += l[i] != live[2 * (first + i)] || r[i] != live[2 * (first + i) + 1];
    std::printf("%zu events recorded, take starts at sample %lld, %zu frames compared: %s\n", piece.lines.size(),
                (long long)first, frames, mismatch ? "DIFFERENT" : "identical");
    if (mismatch) std::printf("%zu frames differ\n", mismatch);
    return mismatch ? 1 : 0;
}

int main(int argc, char** argv) {
    loadSettings();
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char* {
            if (i + 1 >= argc) { usage(); std::exit(1); }
            return argv[++i];
        };
        if (a == "--probe") g_cfg.probe = true;
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
        else if (a == "--waves") g_waves = std::max(1, std::atoi(next()));
        else if (a == "--wobble-div") g_wobbleDiv = std::max(1.0, std::atof(next()));
        else if (a == "--wobble-exp") g_wobbleExp = std::atof(next());
        else if (a == "--ripple-size-exp") g_rippleSizeExp = std::atof(next());
        else if (a == "--frames") { const char* dir = next(); return frames(dir); }
        else if (a == "--check-recording") return checkRecording();
        else { usage(); return 1; }
    }
    for (int i = 0; i < 9; ++i) { g_flashTime[i] = 0.0; g_flashForce[i] = 0.0f; }
    buildLayout();

    if (!loadMultitouch()) {
        g_error = {@"Can't read the trackpad",
                   @"morphion couldn't load macOS's multitouch support. This version of macOS may not be supported."};
    } else if (!startAudio()) {
        std::fprintf(stderr, "audio start failed\n");
        g_error = {@"No sound output", @"morphion couldn't start audio. Check your sound output in System Settings and open morphion again."};
    } else {
        g_scanTrackpads = true;
        int n = scanDevices();
        logEvent("started: %d trackpad(s) playing; audio at %.0f Hz", n, g_sr);
        if (n == 0) g_error = kNoTrackpad;   // cleared when one appears (see the rescan timer)
    }

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu* bar = [NSMenu new];
        NSMenuItem* appItem = [NSMenuItem new];
        [bar addItem:appItem];
        NSMenu* appMenu = [NSMenu new];
        [appMenu addItemWithTitle:@"Quit morphion" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        NSMenuItem* fileItem = [NSMenuItem new];
        [bar addItem:fileItem];
        NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
        [fileMenu addItemWithTitle:@"Open Score…" action:@selector(openScore:) keyEquivalent:@"o"];
        fileItem.submenu = fileMenu;
        app.mainMenu = bar;
        AppDelegate* delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }

    shutdown();
    return 0;
}
