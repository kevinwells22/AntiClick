# Changelog

## 1.1.0 (2026-11-04)

First public release.

- **Menu-bar app.** AntiClick.app shows its status next to the clock. Its menu has: Prevent
  Clicks (pause/resume), Include Non-USB Devices, Compatibility Mode (play digital silence),
  Open at Login (asked once on first launch, never added silently), Recent Activity, About
  and Quit.
- **No microphone access, ever.** Devices that have inputs as well as outputs are held with a
  silent stream that has its inputs switched off. A bare hardware start on those devices
  makes macOS ask for microphone access. Output-only devices still use the zero-overhead
  hardware hold.
- **Shared engine.** The app and the command-line agent run the same C engine
  (`src/engine.c`).
- **Packaging.** `make app`, `make install-app`, `make dmg`, and `make notarize` for Developer
  ID builds.

## 1.0.0 (2026-11-03)

- Command-line login agent (`anticlick`). It keeps the current USB output device running with
  a bare `AudioDeviceStart(device, NULL)`: no IOProc, no wakeups.
- Lets the Mac idle-sleep (`kAudioHardwarePropertySleepingIsAllowed`) and requests a
  4096-frame per-process IO buffer, which cuts coreaudiod's cost about 4x.
- Follows output switching, hot-plugging, sleep/wake, hog mode and coreaudiod restarts, and
  identifies devices by UID.
