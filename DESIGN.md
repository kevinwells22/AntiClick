# AntiClick: design notes

This file covers the options explored, what was measured and why AntiClick is built the way
it is. Measurements were taken on a Mac mini (M2 Pro), macOS 27.2, with the Behringer UMC22
shown as "USB Audio CODEC" (TI PCM2902). The UMC22 is connected through the Dell U2723QE's
USB hub.

## 1. Requirements

1. No click when a sound starts or stops.
2. Runs from login, all the time. It must cost close to nothing in memory, CPU, wakeups and
   energy, and it must not stop the Mac from sleeping.
3. No microphone use and no privacy indicator. No admin rights, no kernel or driver
   installation.
4. Survives real life: output switching, hot-plugging, sleep/wake, the monitor's hub
   dropping out, and coreaudiod restarts.

## 2. Root cause (measured)

`tools/ca-probe.rb watch` recorded the UMC22's running state while alert sounds played:

| Sound | Length | Device running | Device stopped after the sound ended |
|---|---|---|---|
| Tink | 0.56 s | 0.85 s | ~0.3 s |
| Glass | 1.65 s | 2.37 s | ~0.7 s |

Every sound produces one start and one stop, and the UMC22 pops at both. The fix is to keep
the stream running so that there are no transitions. Periodically "pinging" the device
can't work: the device stops less than a second after each ping, so the ping itself clicks.

## 3. Options for keeping the device running

| # | Technique | Result |
|---|---|---|
| 1 | **Hardware hold**: `AudioDeviceStart(device, NULL)`. AudioHardware.h says this "starts the hardware regardless of whether or not there are any IOProcs registered". | **Chosen.** The device stayed running for the whole 34.6 s test while sounds played. No audio callback, so no real-time thread does work in our process. Officially documented behaviour. |
| 2 | **Silent IOProc**: a HAL callback writing zeros, with input streams switched off. | **Kept as fallback** (`--silence`). It sends real digital silence, in case some device or driver needs samples flowing. It costs a real-time callback about 12 times a second. |
| 3 | Audio framework playing silence (AVAudioEngine, AudioQueue, AUHAL). | Rejected. Same effect, but heavier (0.43% CPU for AVAudioEngine against 0.04%). AVAudioEngine also stops when the output device changes and has to be restarted, and `connect(_:to:format:)` is deprecated in macOS 27. |
| 4 | Loop a silent audio file (`afplay`, QuickTime, Music). | Rejected. 0.81% CPU and 4 wakeups/s, and it clicks every time the loop restarts. |
| 5 | Periodic inaudible "ping" (how older keep-alive tools worked). | Rejected. The device stops 0.3 to 0.7 s after each ping, so each ping clicks (section 2). |
| 6 | Virtual audio driver or aggregate device placed in front of the UMC22. | Rejected. Needs admin rights and code running inside coreaudiod, adds latency, and can break with macOS updates. It gains nothing over option 1. |
| 7 | Fix it in hardware. | Not possible. The pop is the codec reacting to the stream starting and stopping. |

## 4. Options for how it runs

| Option | Footprint (measured) | Notes |
|---|---|---|
| **Menu-bar app (chosen, v1.1)** | 12.5 MB for a minimal one; 22.5 MB for the real app, measured while its first-run dialog was open | Shows status next to the clock and has toggles. Opens at login through `SMAppService` (asked once, never silently). Shareable as a DMG. The engine runs inside the app, so quitting the app stops protection, which is what people expect from a menu-bar utility. |
| Headless LaunchAgent (v1.0, kept) | **~4 MB** | Invisible, starts at login, restarted by launchd if it crashes. No admin rights. The leanest option, kept as `anticlick` for people who want no UI. |
| Separate UI app + background agent | ~4 MB plus the UI while it's open | Rejected for now. Two processes, an IPC channel, and `SMAppService.agent` needs proper (Developer ID) signing. Not worth it to save about 10 MB. |
| System LaunchDaemon (root) | about the same as the agent | Rejected. Audio devices and defaults belong to the user session, and root isn't needed. |

Version 1.0 shipped as the headless agent. Once the goals included seeing its status and
handing it to other people, the menu-bar app became the better trade: it costs more memory
than the invisible agent, but still under 0.05% CPU with no measurable wakeups.

## 5. Options for what to build it with

| Language / stack | Result |
|---|---|
| **C engine + thin front ends (chosen)** | The audio logic is one C file (`src/engine.c`) talking straight to the CoreAudio HAL. The agent wraps it in a 54 KB binary (4 MB footprint). The menu-bar app wraps it in Swift/AppKit (572 KB bundle, most of it the icon). One tested engine, two front ends. |
| Swift | Also small, because the Swift runtime ships with macOS. The measured cost comes from the frameworks pulled in (AVFoundation: 5.3 MB, AppKit: 12.5 MB), not the language, so a Swift version using only the HAL would likely land near the C one (not measured). |
| Scripting (macOS's built-in Ruby + Fiddle, or JavaScript for Automation) | Works with no compiler, which is how the approach was first validated before the Command Line Tools were installed. 25.7 MB footprint, and Apple has deprecated the system Ruby, so it's fine for diagnostics (`tools/ca-probe.rb`) but not for a permanent agent. |
| Rust, Zig, Go | Possible, but each needs an extra toolchain and has no advantage for about 600 lines of HAL calls. |

## 6. Measurements

### What each implementation costs (`experiments/bench.sh`, 30 s windows)

| Implementation | Memory footprint | CPU | Wakeups/s | Threads |
|---|---|---|---|---|
| (baseline: idle `sleep` process) | 1.0 MB | 0 | 0 | 1 |
| **C agent, hardware hold (default)** | **4.2 MB** | **0.044%** | **0.2** | 6 |
| C agent, `--silence` IOProc | 3.9 MB | 0.022% | 0.1 | 7 |
| Swift AVAudioEngine playing silence | 5.3 MB | 0.43% | 0.1 | 7 |
| Swift AppKit menu-bar app (hold) | 12.5 MB | 0.026% | 0.2 | 7 |
| `afplay` of a silent file | 6.1 MB | 0.81% | 4.0 | 8 |
| Ruby/Fiddle prototype (hold) | 25.7 MB | 0.019% | 0.1 | 6 |

The UMC22 dropped off the bus (Dell hub) about 30 s into this run, so most variants ended up
holding the built-in speakers. The per-process figures above don't depend on the device. The
coreaudiod figures from this run were therefore discarded; the system-side cost is in the next
table. "Memory footprint" is the process's own memory, the figure Activity Monitor shows. Resident
size is larger (about 15 MB for the agent) because it also counts the shared system frameworks
every process maps. The wakeups column counts only timer and interrupt wakeups. IOProc threads
are woken by coreaudiod and aren't counted here, so use the CPU column to compare energy.

### What keeping a device running costs the system

This is where the real cost is. While a device runs, coreaudiod does an IO cycle for it, and on
macOS 27 the user-space USB audio driver (`usbaudiod`) streams USB packets to it every
millisecond. Measured with the C agent on the UMC22, in 25 s windows alternated twice so
background load affected every condition equally:

| UMC22 state | coreaudiod | usbaudiod | Total |
|---|---|---|---|
| idle (nothing held) | 0% | 0% | 0% |
| held, default 512-frame buffer | 1.04 to 1.12% | 1.92 to 2.12% | ~3.1% of one core |
| **held by AntiClick (4096-frame buffer)** | **0.24 to 0.27%** | **1.77 to 1.92%** | **~2.1% of one core** |

For comparison, holding the Mac mini's built-in speakers costs coreaudiod about 2%, because
the speaker DSP runs whenever that device is on.

- **The USB streaming part (~1.9%) is unavoidable.** It's what keeps the codec from popping,
  and it's the same cost the UMC22 incurs whenever any app plays audio. Every keep-alive
  approach pays it. On an M2 Pro it's about 0.2% of total CPU capacity.
- **The large buffer removes most of the rest.** AntiClick's per-process 4096-frame request
  cuts coreaudiod's share about 4x. The setting is per process: while AntiClick held the
  device at 4096 frames, other processes still saw 512, so nobody else's latency changes.
- **Why only USB by default.** The built-in speaker figure is why AntiClick leaves non-USB
  devices alone, and why it releases the UMC22 when you switch output elsewhere.

### Sleep

Without `kAudioHardwarePropertySleepingIsAllowed`, keeping the device running makes
coreaudiod hold a `PreventUserIdleSystemSleep` assertion:

```
pid 7578(coreaudiod): PreventUserIdleSystemSleep named:
  "com.apple.audio.AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:142000:1.context.preventuseridlesleep"
```

That means the Mac would never idle-sleep, which is easily the biggest hidden cost of any
"keep the audio device awake" tool. With the property set, as AntiClick does, `pmset -g
assertions` shows no audio assertion while the device is held.

### Microphone

The UMC22's output is a separate, output-only CoreAudio device. Its input is another device,
so holding the output never touches the microphone. CoreAudio's process object confirms it:
`IsRunningOutput=1 IsRunningInput=0`, and no microphone prompt appeared in the privacy (TCC)
log.

Many interfaces, though, appear as one device with inputs and outputs. Tested on a device
like that (the "Microsoft Teams Audio" virtual device):

| Technique on an input+output device | Result |
|---|---|
| Bare hardware start, `AudioDeviceStart(dev, NULL)` | coreaudiod asks the privacy system for **microphone** access. That produced a real "would like to access the microphone" prompt (attributed to the terminal app that launched the test). |
| Silent IOProc with input streams switched off (`kAudioDevicePropertyIOProcStreamUsage`) | Device held, `IsRunningInput=0`, no microphone use. |

So the engine picks per device: a bare hardware start for output-only devices (zero
overhead), and the silent IOProc with inputs off for devices that have inputs. That keeps the
app safe to give to people with different hardware.

## 7. Details that matter

1. **Allow idle sleep.** See section 6.
2. **Ask for a large per-process IO buffer** (4096 frames). It cuts coreaudiod's cost for the
   held device by about 4x (1.1% to 0.25%) without affecting other apps. The ~1.9% that
   macOS's USB audio driver spends streaming is the irreducible price of keeping the device on.
3. **Only USB devices by default.** Built-in speakers don't click and are expensive to keep
   on. Bluetooth would drain headphone batteries.
4. **Device IDs are not stable.** Every time the Dell monitor's hub or a sleep/wake
   re-enumerates USB, every CoreAudio device gets a new ID (the UMC22 was 123, then 93, then
   134). AntiClick tracks devices by UID and re-checks on device-list, default-device,
   alive, running, hog-mode and service-restart notifications, on wake, and from a lazy 60 s
   watchdog with 30 s leeway.
5. **CoreAudio delivers notifications on the main run loop** (since 10.6), so the agent sleeps
   in `CFRunLoopRun()`. A pure `dispatch_main()` would never hear about device changes.
6. **Never act inside a CoreAudio callback.** Callbacks only queue a debounced (300 ms)
   reconcile on the main queue, which is idempotent.
7. **Back off politely.** If an app takes exclusive (hog) access, starts fail with `'!hog'`.
   AntiClick retries after 5 s, then 10 s, and so on up to 5 minutes, and again when hog mode
   is released.
8. **Hub dropouts.** In this setup the UMC22 vanishes whenever the Dell monitor powers its hub
   down. During one hour of testing that happened twice (around 20:53 and at 21:07:12, when
   the kernel logged "upstream hub is terminating"), plus a full re-enumeration after a system
   sleep. AntiClick releases the device and re-holds it when it returns. The device's own power-on pop at that moment can't be prevented in
   software. Plugging the UMC22 into the Mac mini directly avoids it.

## 8. Development notes

- **Prototype without a compiler.** The approach was first validated with macOS's built-in
  Ruby (Fiddle FFI) calling CoreAudio directly, with constants checked against the CoreAudio
  BridgeSupport metadata that ships with macOS. That work became `tools/ca-probe.rb`. The
  real builds use the Xcode Command Line Tools (clang 21, Swift 6.4, macOS 27.2 SDK).
- **Apple silicon only.** The development Mac has no Rosetta installed, which is also why an
  older Intel-only anti-pop app stopped working on it. A universal build is possible, but
  its Intel half couldn't be tested.
- **Network share.** The project lives on an SMB share. Shell `-x` tests report runnable
  files as not executable there, and `codesign` refuses app bundles on it ("Finder
  information ... not allowed"). So the scripts test with `-f`, the app is assembled in
  `~/Library/Caches/AntiClick-build`, and the installed agent and app never run from the
  share. That share may not be mounted at login.
- **Real-device verification (2026-11-04).** With the agent and then the app, the UMC22 stayed
  in one continuous `RUNNING` state while test sounds played. The installed agent was killed
  with `kill -9`; launchd restarted it within about 1 s and it re-held the device after a
  0.12 s gap.
- **Distribution.** Without a Developer ID the app is ad-hoc signed, and Gatekeeper rejects a
  downloaded copy until the user clicks "Open Anyway" in System Settings. `make notarize`
  handles Developer ID signing and notarization once an Apple Developer account exists.

## 9. Possible next steps

- Per-device choice in the menu (for example "always hold the UMC22"), like the agent's
  `--match/--always`.
- Developer ID signing and notarization (`make notarize`) before sharing publicly.
- An automatic update check for shared copies (for example Sparkle).
- Test the universal build on an Intel Mac before advertising Intel support.
