/*
 * anticlick - command-line / login-agent front end for the AntiClick engine.
 * The menu-bar app (app/AntiClick.swift) uses the same engine.
 *
 * Build:  make            List devices:  build/anticlick --list
 */

#include "engine.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <getopt.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void usage(FILE *f)
{
    fprintf(f,
        "AntiClick %s - keeps USB audio devices running so they don't click/pop\n"
        "when macOS starts or stops a sound.\n\n"
        "Usage: anticlick [options]         run (normally started at login by launchd)\n"
        "       anticlick --list [options]  show output devices and what would be held\n\n"
        "Options:\n"
        "  -m, --match TEXT     only hold devices whose name or UID contains TEXT\n"
        "                       (case-insensitive, repeatable, any transport)\n"
        "  -a, --always         hold matching devices even when they are not the\n"
        "                       current output (default: current output + alert device)\n"
        "  -t, --any-transport  also hold non-USB devices (built-in, HDMI, Bluetooth...)\n"
        "  -s, --silence        play digital silence on every device instead of a bare\n"
        "                       hardware start (devices with inputs always use it)\n"
        "  -b, --buffer FRAMES  IO buffer to request (default 4096, clamped to device)\n"
        "  -v, --verbose        log every CoreAudio event\n"
        "  -l, --list           list output devices and exit\n"
        "  -d, --duration SECS  exit after SECS seconds (for testing)\n"
        "  -V, --version        print version and exit\n"
        "  -h, --help           show this help\n",
        AC_VERSION);
}

static void on_signal(void *ctx)
{
    int sig = (int)(intptr_t)ctx;
    if (sig == SIGHUP) {
        ac_log("SIGHUP: re-checking devices");
        ac_engine_recheck();
        return;
    }
    ac_engine_stop();
    ac_log("stopped (%s)", sig == SIGTERM ? "SIGTERM" : sig == SIGINT ? "SIGINT" : "time limit");
    exit(0);
}

int main(int argc, char *argv[])
{
    static const struct option opts[] = {
        { "match",         required_argument, NULL, 'm' },
        { "always",        no_argument,       NULL, 'a' },
        { "any-transport", no_argument,       NULL, 't' },
        { "silence",       no_argument,       NULL, 's' },
        { "buffer",        required_argument, NULL, 'b' },
        { "verbose",       no_argument,       NULL, 'v' },
        { "list",          no_argument,       NULL, 'l' },
        { "duration",      required_argument, NULL, 'd' },
        { "version",       no_argument,       NULL, 'V' },
        { "help",          no_argument,       NULL, 'h' },
        { NULL, 0, NULL, 0 },
    };
    bool list = false;
    double duration = 0;
    int c;
    while ((c = getopt_long(argc, argv, "m:atsb:vld:Vh", opts, NULL)) != -1) {
        switch (c) {
        case 'm':
            if (!ac_add_match(optarg)) { fprintf(stderr, "too many --match options\n"); return 1; }
            break;
        case 'a': ac_set_always(true); break;
        case 't': ac_set_any_transport(true); break;
        case 's': ac_set_force_silence(true); break;
        case 'b': ac_set_buffer_frames((uint32_t)strtoul(optarg, NULL, 10)); break;
        case 'v': ac_set_verbose(true); break;
        case 'l': list = true; break;
        case 'd': duration = strtod(optarg, NULL); break;
        case 'V': printf("anticlick %s\n", AC_VERSION); return 0;
        case 'h': usage(stdout); return 0;
        default:  usage(stderr); return 1;
        }
    }
    if (optind < argc) { usage(stderr); return 1; }

    if (list) {
        ac_print_devices();
        return 0;
    }

    /* Clean shutdown on TERM/INT, re-check on HUP. */
    static const int sigs[] = { SIGTERM, SIGINT, SIGHUP };
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) {
        signal(sigs[i], SIG_IGN);
        dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sigs[i], 0,
                                                     dispatch_get_main_queue());
        dispatch_set_context(s, (void *)(intptr_t)sigs[i]);
        dispatch_source_set_event_handler_f(s, on_signal);
        dispatch_resume(s);
    }
    if (duration > 0)
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), (void *)(intptr_t)0, on_signal);

    ac_engine_start(NULL, NULL);

    /* CoreAudio delivers notifications on the main run loop (10.6+), and the
     * run loop also drains the main dispatch queue. Sleep here forever. */
    CFRunLoopRun();
    return 0;
}
