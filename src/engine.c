/*
 * AntiClick engine - see engine.h for the API.
 *
 * Why the click happens
 *   macOS starts an output device's IO when a sound begins and stops it about
 *   0.3-0.7 s after the sound ends. Many USB devices (e.g. the Behringer UMC22
 *   and its TI PCM2902 codec) pop whenever that stream starts or stops.
 *
 * What the engine does
 *   It keeps the device's IO running permanently, so there is nothing left to
 *   start or stop.
 *     - Output-only devices: AudioDeviceStart(device, NULL), which (per
 *       AudioHardware.h) "starts the hardware regardless of whether or not
 *       there are any IOProcs registered". No IOProc means no real-time audio
 *       thread in this process and no periodic wakeups.
 *     - Devices that also have inputs: a bare hardware start would make macOS
 *       ask for microphone access, so those get a silent IOProc with every
 *       input stream switched off instead (also used for all devices when
 *       ac_set_force_silence(true)).
 *   It also
 *     - sets kAudioHardwarePropertySleepingIsAllowed, so the running device
 *       does not stop the Mac from idle-sleeping,
 *     - asks for a large per-process IO buffer, which cuts the work coreaudiod
 *       does for the idle device about 4x,
 *     - follows the default output device, hot-plugging, sleep/wake, hog mode
 *       and coreaudiod restarts, identifying devices by UID.
 */

#include "engine.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <dispatch/dispatch.h>
#include <libproc.h>
#include <os/log.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#define AC_MAX_DEVICES      8
#define AC_MAX_MATCHES      8
#define AC_DEFAULT_FRAMES   4096u   /* per-process IO buffer we ask for */
#define AC_WATCHDOG_SECS    60      /* safety-net re-check interval */
#define AC_DEBOUNCE_MS      300     /* coalesce bursts of CoreAudio events */
#define AC_SETTLE_NS        (3ull * NSEC_PER_SEC)   /* grace period after a start */
#define AC_MAX_BACKOFF_SECS 300
#define AC_RECENT           16

#define GLOBAL kAudioObjectPropertyScopeGlobal
#define OUTPUT kAudioObjectPropertyScopeOutput
#define INPUT  kAudioObjectPropertyScopeInput
#define SYSTEM kAudioObjectSystemObject
#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

typedef struct {
    AudioObjectID       id;
    char                uid[256];
    char                name[128];
    AudioDeviceIOProcID proc;           /* silent mode only */
    bool                silent;         /* held with a silent IOProc */
    bool                running;        /* our start succeeded and is in effect */
    unsigned            failures;       /* consecutive failed starts */
    uint64_t            started_ns;
    uint64_t            next_try_ns;
} held_t;

static struct {
    /* configuration */
    char       *match[AC_MAX_MATCHES];
    int         nmatch;
    bool        enabled, always, any_transport, force_silence, verbose;
    uint32_t    frames;
    /* state */
    bool        started;
    ac_change_fn on_change;
    void       *context;
    held_t      held[AC_MAX_DEVICES];
    int         nheld;
    int         last_wanted;
    bool        reconcile_pending;
    char        output_name[128];
    char        output_transport[32];
    char        last_error[160];
    char        recent[AC_RECENT][192];
    int         recent_head, recent_n;
    os_log_t    oslog;
    io_connect_t          pm_root;
    IONotificationPortRef pm_port;
    io_object_t           pm_notifier;
} g = { .enabled = true, .last_wanted = -1 };

static void reconcile(void);
static void schedule_reconcile(void);

/* ------------------------------------------------------------------ logging */

void ac_log(const char *fmt, ...)
{
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);

    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char stamp[32], line[600];
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &tm);
    snprintf(line, sizeof line, "%s  %s\n", stamp, msg);
    fwrite(line, 1, strlen(line), stderr);

    if (!g.oslog) g.oslog = os_log_create(AC_LOG_SUBSYSTEM, "engine");
    os_log(g.oslog, "%{public}s", msg);

    strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);
    snprintf(g.recent[g.recent_head], sizeof g.recent[0], "%s  %s", stamp, msg);
    g.recent_head = (g.recent_head + 1) % AC_RECENT;
    if (g.recent_n < AC_RECENT) g.recent_n++;
}

#define vlog(...) do { if (g.verbose) ac_log(__VA_ARGS__); } while (0)

/* Render an OSStatus / selector as 'abcd' when printable, else as a number. */
static const char *fourcc(UInt32 v, char buf[16])
{
    char c[4] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v };
    bool printable = true;
    for (int i = 0; i < 4; i++)
        if (c[i] < 0x20 || c[i] > 0x7e) printable = false;
    if (printable) snprintf(buf, 16, "'%c%c%c%c'", c[0], c[1], c[2], c[3]);
    else           snprintf(buf, 16, "%d", (int)v);
    return buf;
}
#define FCC(v) fourcc((UInt32)(v), (char[16]){0})

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void notify(void)
{
    if (g.on_change) g.on_change(g.context);
}

/* -------------------------------------------------------- property helpers */

static AudioObjectPropertyAddress prop(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    return a;
}

static OSStatus get_u32(AudioObjectID obj, AudioObjectPropertySelector sel, UInt32 *out)
{
    AudioObjectPropertyAddress a = prop(sel, GLOBAL);
    UInt32 size = sizeof *out;
    return AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, out);
}

static UInt32 u32_or(AudioObjectID obj, AudioObjectPropertySelector sel, UInt32 fallback)
{
    UInt32 v;
    return get_u32(obj, sel, &v) == noErr ? v : fallback;
}

static OSStatus set_u32(AudioObjectID obj, AudioObjectPropertySelector sel, UInt32 value)
{
    AudioObjectPropertyAddress a = prop(sel, GLOBAL);
    return AudioObjectSetPropertyData(obj, &a, 0, NULL, sizeof value, &value);
}

static bool get_string(AudioObjectID obj, AudioObjectPropertySelector sel, char *buf, size_t len)
{
    AudioObjectPropertyAddress a = prop(sel, GLOBAL);
    CFStringRef s = NULL;
    UInt32 size = sizeof s;
    buf[0] = '\0';
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &s) != noErr || s == NULL)
        return false;
    bool ok = CFStringGetCString(s, buf, (CFIndex)len, kCFStringEncodingUTF8);
    CFRelease(s);
    if (!ok) buf[0] = '\0';
    return ok;
}

/* Fetch an array of object IDs. Returns the count; *out must be freed. */
static UInt32 get_ids(AudioObjectID obj, AudioObjectPropertySelector sel,
                      AudioObjectPropertyScope scope, AudioObjectID **out)
{
    AudioObjectPropertyAddress a = prop(sel, scope);
    UInt32 size = 0;
    *out = NULL;
    if (AudioObjectGetPropertyDataSize(obj, &a, 0, NULL, &size) != noErr || size == 0)
        return 0;
    AudioObjectID *ids = malloc(size);
    if (!ids) return 0;
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, ids) != noErr) {
        free(ids);
        return 0;
    }
    *out = ids;
    return size / (UInt32)sizeof(AudioObjectID);
}

static UInt32 channel_count(AudioObjectID dev, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = prop(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0, total = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || size < sizeof(UInt32))
        return 0;
    AudioBufferList *abl = malloc(size);
    if (!abl) return 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, abl) == noErr)
        for (UInt32 i = 0; i < abl->mNumberBuffers; i++)
            total += abl->mBuffers[i].mNumberChannels;
    free(abl);
    return total;
}

static const char *transport_name(UInt32 t)
{
    switch (t) {
    case kAudioDeviceTransportTypeUSB:          return "USB";
    case kAudioDeviceTransportTypeBuiltIn:      return "Built-in";
    case kAudioDeviceTransportTypeBluetooth:    return "Bluetooth";
    case kAudioDeviceTransportTypeBluetoothLE:  return "Bluetooth LE";
    case kAudioDeviceTransportTypeHDMI:         return "HDMI";
    case kAudioDeviceTransportTypeDisplayPort:  return "DisplayPort";
    case kAudioDeviceTransportTypeAirPlay:      return "AirPlay";
    case kAudioDeviceTransportTypeVirtual:      return "Virtual";
    case kAudioDeviceTransportTypeAggregate:
    case kAudioDeviceTransportTypeAutoAggregate: return "Aggregate";
    case kAudioDeviceTransportTypeThunderbolt:  return "Thunderbolt";
    case kAudioDeviceTransportTypePCI:          return "PCI";
    case kAudioDeviceTransportTypeFireWire:     return "FireWire";
    case kAudioDeviceTransportTypeAVB:          return "AVB";
    case kAudioDeviceTransportTypeContinuityCaptureWired:
    case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity";
    default:                                    return "Other";
    }
}

/* ------------------------------------------------------------------ policy */

static bool matches(const char *name, const char *uid)
{
    for (int i = 0; i < g.nmatch; i++)
        if (strcasestr(name, g.match[i]) || strcasestr(uid, g.match[i]))
            return true;
    return false;
}

/* Is this an output device AntiClick may hold (ignoring whether it is the
 * current output)? With matches the name decides; otherwise it must be USB
 * unless any_transport is set. */
static bool eligible(AudioObjectID dev)
{
    if (dev == kAudioObjectUnknown) return false;
    if (!u32_or(dev, kAudioDevicePropertyDeviceIsAlive, 0)) return false;
    if (u32_or(dev, kAudioDevicePropertyIsHidden, 0)) return false;
    if (channel_count(dev, OUTPUT) == 0) return false;
    if (g.nmatch > 0) {
        char name[128], uid[256];
        get_string(dev, kAudioObjectPropertyName, name, sizeof name);
        get_string(dev, kAudioDevicePropertyDeviceUID, uid, sizeof uid);
        return matches(name, uid);
    }
    return g.any_transport ||
           u32_or(dev, kAudioDevicePropertyTransportType, 0) == kAudioDeviceTransportTypeUSB;
}

static void add_unique(AudioObjectID *list, int *n, AudioObjectID dev)
{
    for (int i = 0; i < *n; i++)
        if (list[i] == dev) return;
    if (*n < AC_MAX_DEVICES) list[(*n)++] = dev;
}

/* The devices that should be held right now. */
static int wanted_devices(AudioObjectID *out)
{
    int n = 0;
    if (!g.enabled) return 0;
    if (g.always) {
        AudioObjectID *devs;
        UInt32 nd = get_ids(SYSTEM, kAudioHardwarePropertyDevices, GLOBAL, &devs);
        for (UInt32 i = 0; i < nd; i++)
            if (eligible(devs[i])) add_unique(out, &n, devs[i]);
        free(devs);
    } else {
        /* The current output device, plus the alert/sound-effects device when
         * "Play sound effects through" points somewhere else. */
        static const AudioObjectPropertySelector sels[] = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        };
        for (size_t i = 0; i < COUNT(sels); i++) {
            UInt32 dev = kAudioObjectUnknown;
            if (get_u32(SYSTEM, sels[i], &dev) == noErr && eligible(dev))
                add_unique(out, &n, dev);
        }
    }
    return n;
}

/* --------------------------------------------------------------- listeners */

static const AudioObjectPropertySelector kSystemEvents[] = {
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDefaultSystemOutputDevice,
    kAudioHardwarePropertyServiceRestarted,
};
static const AudioObjectPropertySelector kDeviceEvents[] = {
    kAudioDevicePropertyDeviceIsAlive,
    kAudioDevicePropertyDeviceIsRunning,
    kAudioDevicePropertyHogMode,
    kAudioDevicePropertyDeviceHasChanged,
    kAudioDevicePropertyIOStoppedAbnormally,
};

static void handle_service_restart(void *ctx);
static void schedule_reconcile_cb(void *ctx) { (void)ctx; schedule_reconcile(); }

/* Called by CoreAudio (on the main run loop by default). Never act inside the
 * callback: just queue a debounced reconcile on the main queue. */
static OSStatus on_property(AudioObjectID obj, UInt32 n,
                            const AudioObjectPropertyAddress *addrs, void *ctx)
{
    (void)ctx;
    bool restarted = false;
    for (UInt32 i = 0; i < n; i++) {
        vlog("event: object %u changed %s", (unsigned)obj, FCC(addrs[i].mSelector));
        if (obj == SYSTEM && addrs[i].mSelector == kAudioHardwarePropertyServiceRestarted)
            restarted = true;
    }
    dispatch_async_f(dispatch_get_main_queue(), NULL,
                     restarted ? handle_service_restart : schedule_reconcile_cb);
    return noErr;
}

static void listen_all(AudioObjectID obj, const AudioObjectPropertySelector *sels, size_t n, bool add)
{
    for (size_t i = 0; i < n; i++) {
        AudioObjectPropertyAddress a = prop(sels[i], GLOBAL);
        OSStatus st = add ? AudioObjectAddPropertyListener(obj, &a, on_property, NULL)
                          : AudioObjectRemovePropertyListener(obj, &a, on_property, NULL);
        if (st != noErr && add)
            vlog("could not listen to %s on object %u: %s", FCC(sels[i]), (unsigned)obj, FCC(st));
    }
}

/* ----------------------------------------------------------- hold / release */

/* Silent mode: an IOProc that outputs silence. */
static OSStatus silence_ioproc(AudioObjectID dev, const AudioTimeStamp *now,
                               const AudioBufferList *in, const AudioTimeStamp *in_time,
                               AudioBufferList *out, const AudioTimeStamp *out_time, void *ctx)
{
    (void)dev; (void)now; (void)in; (void)in_time; (void)out_time; (void)ctx;
    if (out)
        for (UInt32 i = 0; i < out->mNumberBuffers; i++)
            if (out->mBuffers[i].mData)
                memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
    return noErr;
}

/* Never touch the input streams of a duplex device: no microphone use, no
 * orange privacy dot, no permission prompt. */
static void disable_input_streams(AudioObjectID dev, AudioDeviceIOProcID proc)
{
    AudioObjectPropertyAddress a = prop(kAudioDevicePropertyStreams, INPUT);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr) return;
    UInt32 n = size / (UInt32)sizeof(AudioStreamID);
    if (n == 0) return;
    size_t usize = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + n * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *u = calloc(1, usize);   /* all streams off */
    if (!u) return;
    u->mIOProc = (void *)proc;
    u->mNumberStreams = n;
    AudioObjectPropertyAddress ua = prop(kAudioDevicePropertyIOProcStreamUsage, INPUT);
    OSStatus st = AudioObjectSetPropertyData(dev, &ua, 0, NULL, (UInt32)usize, u);
    free(u);
    if (st != noErr) ac_log("warning: could not switch off input streams: %s", FCC(st));
}

/* Ask for a big IO buffer for this process. The setting is per-process (other
 * apps keep their own latency) and it reduces how often coreaudiod has to run
 * an IO cycle for us. */
static void request_buffer(const held_t *h)
{
    AudioObjectPropertyAddress a = prop(kAudioDevicePropertyBufferFrameSizeRange, GLOBAL);
    AudioValueRange r = { 0, 0 };
    UInt32 size = sizeof r;
    UInt32 want = g.frames ? g.frames : AC_DEFAULT_FRAMES;
    if (AudioObjectGetPropertyData(h->id, &a, 0, NULL, &size, &r) == noErr && r.mMaximum >= 1) {
        if (want > (UInt32)r.mMaximum) want = (UInt32)r.mMaximum;
        if (want < (UInt32)r.mMinimum) want = (UInt32)r.mMinimum;
    }
    OSStatus st = set_u32(h->id, kAudioDevicePropertyBufferFrameSize, want);
    if (st != noErr) vlog("could not set %u-frame buffer on \"%s\": %s", (unsigned)want, h->name, FCC(st));
}

static void reconcile_cb(void *ctx) { (void)ctx; reconcile(); }

static bool start_device(held_t *h)
{
    OSStatus st;
    bool has_inputs = channel_count(h->id, INPUT) > 0;
    h->silent = g.force_silence || has_inputs;
    request_buffer(h);
    if (h->silent) {
        st = AudioDeviceCreateIOProcID(h->id, silence_ioproc, NULL, &h->proc);
        if (st == noErr) {
            disable_input_streams(h->id, h->proc);
            st = AudioDeviceStart(h->id, h->proc);
            if (st != noErr) {
                AudioDeviceDestroyIOProcID(h->id, h->proc);
                h->proc = NULL;
            }
        } else {
            h->proc = NULL;
        }
    } else {
        st = AudioDeviceStart(h->id, NULL);   /* hardware only, no IOProc */
    }

    if (st == noErr) {
        h->running = true;
        h->failures = 0;
        h->started_ns = now_ns();
        g.last_error[0] = '\0';
        ac_log("holding \"%s\" open (%s)", h->name,
               !h->silent ? "hardware start, no IOProc"
               : has_inputs ? "silent stream, inputs off" : "silent stream");
        return true;
    }

    h->failures++;
    unsigned delay = 5u << (h->failures < 7 ? h->failures - 1 : 6);
    if (delay > AC_MAX_BACKOFF_SECS) delay = AC_MAX_BACKOFF_SECS;
    h->next_try_ns = now_ns() + (uint64_t)delay * NSEC_PER_SEC;
    snprintf(g.last_error, sizeof g.last_error, "%s",
             st == kAudioDevicePermissionsError ? "another app has exclusive access" : FCC(st));
    ac_log("could not start \"%s\": %s; retrying in %us", h->name, g.last_error, delay);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * (int64_t)NSEC_PER_SEC),
                     dispatch_get_main_queue(), NULL, reconcile_cb);
    return false;
}

static void stop_device(held_t *h)
{
    if (h->running) {
        AudioDeviceStop(h->id, h->silent ? h->proc : NULL);
        h->running = false;
    }
    if (h->proc) {
        AudioDeviceDestroyIOProcID(h->id, h->proc);
        h->proc = NULL;
    }
}

static held_t *find_held(AudioObjectID id)
{
    for (int i = 0; i < g.nheld; i++)
        if (g.held[i].id == id) return &g.held[i];
    return NULL;
}

static void track(AudioObjectID id)
{
    held_t *h = &g.held[g.nheld++];
    memset(h, 0, sizeof *h);
    h->id = id;
    get_string(id, kAudioObjectPropertyName, h->name, sizeof h->name);
    get_string(id, kAudioDevicePropertyDeviceUID, h->uid, sizeof h->uid);
    listen_all(id, kDeviceEvents, COUNT(kDeviceEvents), true);
    start_device(h);
}

static void untrack(int idx, const char *why)
{
    held_t *h = &g.held[idx];
    stop_device(h);
    listen_all(h->id, kDeviceEvents, COUNT(kDeviceEvents), false);
    ac_log("released \"%s\" (%s)", h->name, why);
    g.held[idx] = g.held[--g.nheld];
}

/* ---------------------------------------------------------------- reconcile */

/* Bring the set of held devices in line with what should be held. Idempotent;
 * runs on every relevant CoreAudio event, on wake, from the watchdog and when
 * the configuration changes. */
static void reconcile(void)
{
    AudioObjectID want[AC_MAX_DEVICES];
    int nw = wanted_devices(want);

    /* 1. Release devices that vanished or are no longer wanted. An ID that now
     *    reports a different UID belongs to a different device. */
    for (int i = 0; i < g.nheld;) {
        held_t *h = &g.held[i];
        char uid[256];
        bool same = get_string(h->id, kAudioDevicePropertyDeviceUID, uid, sizeof uid) &&
                    strcmp(uid, h->uid) == 0;
        bool wanted = false;
        for (int j = 0; j < nw; j++)
            if (want[j] == h->id) wanted = true;
        if (!same || !wanted) {
            untrack(i, !same ? "device went away" : !g.enabled ? "paused" : "no longer the selected output");
            continue;
        }
        i++;
    }

    /* 2. Hold newly wanted devices. */
    for (int j = 0; j < nw; j++)
        if (!find_held(want[j]) && g.nheld < AC_MAX_DEVICES)
            track(want[j]);

    /* 3. Health check: restart anything that stopped behind our back (after
     *    sleep/wake, a hog-mode app quitting, ...) and retry failed starts. */
    uint64_t now = now_ns();
    for (int i = 0; i < g.nheld; i++) {
        held_t *h = &g.held[i];
        if (h->running && now - h->started_ns > AC_SETTLE_NS &&
            !u32_or(h->id, kAudioDevicePropertyDeviceIsRunning, 1)) {
            ac_log("\"%s\" stopped unexpectedly; restarting", h->name);
            stop_device(h);
            h->next_try_ns = 0;
        }
        if (!h->running && now >= h->next_try_ns)
            start_device(h);
    }

    /* 4. Status for the UI. */
    UInt32 dout = kAudioObjectUnknown;
    g.output_name[0] = g.output_transport[0] = '\0';
    if (get_u32(SYSTEM, kAudioHardwarePropertyDefaultOutputDevice, &dout) == noErr &&
        dout != kAudioObjectUnknown) {
        get_string(dout, kAudioObjectPropertyName, g.output_name, sizeof g.output_name);
        strlcpy(g.output_transport, transport_name(u32_or(dout, kAudioDevicePropertyTransportType, 0)),
                sizeof g.output_transport);
    }
    if (g.enabled && nw == 0 && nw != g.last_wanted)
        ac_log("idle: current output \"%s\" is not a device AntiClick holds",
               g.output_name[0] ? g.output_name : "none");
    g.last_wanted = nw;
    notify();
}

static void reconcile_now(void *ctx)
{
    (void)ctx;
    g.reconcile_pending = false;
    reconcile();
}

static void schedule_reconcile(void)
{
    if (g.reconcile_pending) return;
    g.reconcile_pending = true;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)AC_DEBOUNCE_MS * (int64_t)NSEC_PER_MSEC),
                     dispatch_get_main_queue(), NULL, reconcile_now);
}

/* ----------------------------------------------------- process-wide setup */

static void configure_process(void)
{
    OSStatus st;
    /* Keep audio IO running without holding a "prevent idle sleep" assertion. */
    st = set_u32(SYSTEM, kAudioHardwarePropertySleepingIsAllowed, 1);
    if (st != noErr) ac_log("warning: could not allow idle sleep: %s", FCC(st));
    /* We care about power, not latency. */
    st = set_u32(SYSTEM, kAudioHardwarePropertyPowerHint, kAudioHardwarePowerHintFavorSavingPower);
    if (st != noErr) vlog("could not set power hint: %s", FCC(st));
}

static void handle_service_restart(void *ctx)
{
    (void)ctx;
    ac_log("coreaudiod restarted; re-establishing everything");
    while (g.nheld > 0)
        untrack(g.nheld - 1, "audio service restarted");
    listen_all(SYSTEM, kSystemEvents, COUNT(kSystemEvents), false);
    listen_all(SYSTEM, kSystemEvents, COUNT(kSystemEvents), true);
    configure_process();
    schedule_reconcile();
}

static void on_power(void *refcon, io_service_t service, natural_t type, void *arg)
{
    (void)refcon; (void)service;
    switch (type) {
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(g.pm_root, (long)arg);
        break;
    case kIOMessageSystemWillSleep:
        ac_log("system is going to sleep");
        IOAllowPowerChange(g.pm_root, (long)arg);
        break;
    case kIOMessageSystemHasPoweredOn:
        ac_log("system woke up; re-checking devices");
        /* USB devices may take a few seconds to come back after wake. */
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * (int64_t)NSEC_PER_SEC),
                         dispatch_get_main_queue(), NULL, reconcile_cb);
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 10 * (int64_t)NSEC_PER_SEC),
                         dispatch_get_main_queue(), NULL, reconcile_cb);
        break;
    default:
        break;
    }
}

/* ------------------------------------------------------------ public API */

void ac_set_enabled(bool on)
{
    if (g.enabled == on) return;
    g.enabled = on;
    if (!g.started) return;
    if (on) ac_log("resumed");
    else    ac_log("paused");
    reconcile();
}

void ac_set_any_transport(bool on)
{
    if (g.any_transport == on) return;
    g.any_transport = on;
    if (g.started) reconcile();
}

void ac_set_always(bool on)
{
    if (g.always == on) return;
    g.always = on;
    if (g.started) reconcile();
}

void ac_set_force_silence(bool on)
{
    if (g.force_silence == on) return;
    g.force_silence = on;
    if (!g.started) return;
    while (g.nheld > 0)
        untrack(g.nheld - 1, "switching mode");
    reconcile();
}

void ac_set_buffer_frames(uint32_t frames) { g.frames = frames; }
void ac_set_verbose(bool verbose) { g.verbose = verbose; }

bool ac_add_match(const char *text)
{
    if (!text || g.nmatch == AC_MAX_MATCHES) return false;
    g.match[g.nmatch++] = strdup(text);
    return true;
}

void ac_engine_start(ac_change_fn on_change, void *context)
{
    if (g.started) return;
    g.started = true;
    g.on_change = on_change;
    g.context = context;

    configure_process();
    listen_all(SYSTEM, kSystemEvents, COUNT(kSystemEvents), true);

    /* Wake notifications, delivered on the main queue. */
    g.pm_root = IORegisterForSystemPower(NULL, &g.pm_port, on_power, &g.pm_notifier);
    if (g.pm_root != MACH_PORT_NULL)
        IONotificationPortSetDispatchQueue(g.pm_port, dispatch_get_main_queue());
    else
        ac_log("warning: no sleep/wake notifications; relying on the watchdog");

    /* Safety net in case a notification is ever missed: a lazy timer that the
     * OS may coalesce (generous leeway), about one wakeup per minute. */
    dispatch_source_t wd = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(wd, dispatch_time(DISPATCH_TIME_NOW, AC_WATCHDOG_SECS * (int64_t)NSEC_PER_SEC),
                              AC_WATCHDOG_SECS * NSEC_PER_SEC, (AC_WATCHDOG_SECS / 2) * NSEC_PER_SEC);
    dispatch_source_set_event_handler_f(wd, reconcile_cb);
    dispatch_resume(wd);

    char what[200] = "";
    for (int i = 0; i < g.nmatch; i++) {
        strlcat(what, i ? ", \"" : " matching \"", sizeof what);
        strlcat(what, g.match[i], sizeof what);
        strlcat(what, "\"", sizeof what);
    }
    ac_log("AntiClick %s started (pid %d): %s%s%s%s", AC_VERSION, (int)getpid(),
           g.always ? "all devices" : "current output", what,
           (g.nmatch == 0 && !g.any_transport) ? " if USB" : "",
           g.force_silence ? ", silent-stream mode" : "");
    reconcile();
}

void ac_engine_stop(void)
{
    g.enabled = false;              /* nothing gets re-held while we exit */
    while (g.nheld > 0)
        untrack(g.nheld - 1, "shutting down");
    notify();
}

void ac_engine_recheck(void)
{
    if (g.started) reconcile();
}

bool ac_status_enabled(void) { return g.enabled; }
int ac_status_held_count(void) { return g.nheld; }
const char *ac_status_held_name(int i) { return (i >= 0 && i < g.nheld) ? g.held[i].name : ""; }
bool ac_status_held_running(int i) { return i >= 0 && i < g.nheld && g.held[i].running; }
bool ac_status_held_silent(int i) { return i >= 0 && i < g.nheld && g.held[i].silent; }
const char *ac_status_output_name(void) { return g.output_name; }
const char *ac_status_output_transport(void) { return g.output_transport; }
const char *ac_status_last_error(void) { return g.last_error; }

int ac_recent_count(void) { return g.recent_n; }
const char *ac_recent_line(int i)
{
    if (i < 0 || i >= g.recent_n) return "";
    return g.recent[(g.recent_head - 1 - i + 2 * AC_RECENT) % AC_RECENT];
}

/* ------------------------------------------------------------------ --list */

void ac_print_devices(void)
{
    UInt32 dout = 0, sout = 0;
    get_u32(SYSTEM, kAudioHardwarePropertyDefaultOutputDevice, &dout);
    get_u32(SYSTEM, kAudioHardwarePropertyDefaultSystemOutputDevice, &sout);

    AudioObjectID want[AC_MAX_DEVICES];
    int nw = wanted_devices(want);

    /* Which devices are held by a running AntiClick (agent or app) right now? */
    AudioObjectID held_dev[64];
    pid_t held_pid[64];
    int nh = 0;
    if (__builtin_available(macOS 14.0, *)) {
        AudioObjectID *procs;
        UInt32 np = get_ids(SYSTEM, kAudioHardwarePropertyProcessObjectList, GLOBAL, &procs);
        for (UInt32 i = 0; i < np; i++) {
            UInt32 pid = 0;
            char pname[64] = "";
            if (get_u32(procs[i], kAudioProcessPropertyPID, &pid) != noErr) continue;
            if (proc_name((int)pid, pname, sizeof pname) <= 0 || strcasecmp(pname, "anticlick") != 0) continue;
            AudioObjectID *devs;
            UInt32 nd = get_ids(procs[i], kAudioProcessPropertyDevices, OUTPUT, &devs);
            for (UInt32 j = 0; j < nd && nh < 64; j++) {
                held_dev[nh] = devs[j];
                held_pid[nh++] = (pid_t)pid;
            }
            free(devs);
        }
        free(procs);
    }

    printf("AntiClick %s - audio output devices\n\n", AC_VERSION);
    printf("  %-4s %-28s %-12s %6s  %-8s %s\n", "ID", "Device", "Transport", "Rate", "State", "Notes");
    AudioObjectID *devs;
    UInt32 nd = get_ids(SYSTEM, kAudioHardwarePropertyDevices, GLOBAL, &devs);
    for (UInt32 i = 0; i < nd; i++) {
        AudioObjectID d = devs[i];
        if (channel_count(d, OUTPUT) == 0) continue;
        char name[128], notes[256] = "";
        get_string(d, kAudioObjectPropertyName, name, sizeof name);
        AudioObjectPropertyAddress ra = prop(kAudioDevicePropertyNominalSampleRate, GLOBAL);
        Float64 rate = 0;
        UInt32 size = sizeof rate;
        AudioObjectGetPropertyData(d, &ra, 0, NULL, &size, &rate);
        if (d == dout) strlcat(notes, "default output; ", sizeof notes);
        if (d == sout) strlcat(notes, "alert sounds; ", sizeof notes);
        if (channel_count(d, INPUT) > 0) strlcat(notes, "has inputs; ", sizeof notes);
        for (int j = 0; j < nh; j++)
            if (held_dev[j] == d) {
                char tmp[48];
                snprintf(tmp, sizeof tmp, "HELD by AntiClick pid %d; ", (int)held_pid[j]);
                strlcat(notes, tmp, sizeof notes);
            }
        bool would = false;
        for (int j = 0; j < nw; j++)
            if (want[j] == d) would = true;
        size_t len = strlen(notes);
        if (len >= 2) notes[len - 2] = '\0';
        printf("%s %-4u %-28.28s %-12s %6.0f  %-8s %s\n", would ? "*" : " ", (unsigned)d, name,
               transport_name(u32_or(d, kAudioDevicePropertyTransportType, 0)), rate,
               u32_or(d, kAudioDevicePropertyDeviceIsRunningSomewhere, 0) ? "running" : "idle", notes);
    }
    free(devs);
    printf("\n* = would be held with these options%s\n",
           nw == 0 ? " (none right now: the current output is not a matching device)" : "");
}
