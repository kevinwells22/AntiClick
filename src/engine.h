/*
 * AntiClick engine - keeps USB audio output devices running so they don't
 * click or pop when macOS starts and stops sounds. Shared by the command-line
 * agent (src/anticlick.c) and the menu-bar app (app/AntiClick.swift).
 *
 * Threading: call everything on the main thread. The engine receives CoreAudio
 * notifications on the main run loop and does its work on the main dispatch
 * queue, so the host must run the main run loop (CFRunLoopRun() or
 * NSApplication.run()).
 */
#ifndef ANTICLICK_ENGINE_H
#define ANTICLICK_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

#ifndef AC_VERSION
#define AC_VERSION "1.1.0"
#endif
/* Unified-log subsystem (filter for it in Console.app). */
#ifndef AC_LOG_SUBSYSTEM
#define AC_LOG_SUBSYSTEM "io.github.kevinwells22.anticlick"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---- configuration (may be changed at any time; takes effect immediately) */

/* false = pause: release every device. Default true. */
void ac_set_enabled(bool enabled);
/* Hold non-USB devices too (built-in, HDMI, Thunderbolt, ...). Default false. */
void ac_set_any_transport(bool any);
/* Hold matching devices even when they are not the current output. Default false. */
void ac_set_always(bool always);
/* Use a silent IOProc for every device instead of a bare hardware start.
 * (Devices with input streams always use the silent IOProc, with inputs
 * switched off, because a bare hardware start would make macOS ask for
 * microphone access.) Default false. */
void ac_set_force_silence(bool on);
/* Per-process IO buffer to request, in frames (0 = default 4096). */
void ac_set_buffer_frames(uint32_t frames);
/* Log every CoreAudio event. Default false. */
void ac_set_verbose(bool verbose);
/* Only hold devices whose name or UID contains text (case-insensitive).
 * Repeatable; returns false when the list is full. */
bool ac_add_match(const char *text);

/* ---- lifecycle */

typedef void (*ac_change_fn)(void *context);

/* Start watching and holding. on_change (may be NULL) is called on the main
 * thread whenever the status below may have changed. */
void ac_engine_start(ac_change_fn on_change, void *context);
/* Release every device (call before exiting). */
void ac_engine_stop(void);
/* Re-check devices now (e.g. after SIGHUP). */
void ac_engine_recheck(void);

/* ---- status */

bool        ac_status_enabled(void);
int         ac_status_held_count(void);
const char *ac_status_held_name(int index);
bool        ac_status_held_running(int index);   /* false while waiting/retrying */
bool        ac_status_held_silent(int index);    /* using the silent IOProc */
const char *ac_status_output_name(void);         /* current default output, "" if none */
const char *ac_status_output_transport(void);    /* "USB", "Built-in", ... */
const char *ac_status_last_error(void);          /* last start failure, "" if none */

/* Recent log lines, newest first ("HH:MM:SS  message"). */
int         ac_recent_count(void);
const char *ac_recent_line(int index);

/* ---- command-line helpers */

/* Print the device table used by `anticlick --list`. */
void ac_print_devices(void);
/* Log a line (timestamped, to stderr, the unified log and the recent list). */
void ac_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#ifdef __cplusplus
}
#endif
#endif
