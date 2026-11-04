// Alternative #3 - a menu-bar app (AppKit NSStatusItem) using the same
// hardware-hold technique as the C agent, with an on/off toggle.
// Built only to measure what a UI costs; see README.md.
import AppKit
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var holding = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        var allowSleep: UInt32 = 1
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertySleepingIsAllowed,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &allowSleep)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "speaker.wave.2",
                                     accessibilityDescription: "AntiClick")
        let menu = NSMenu()
        menu.addItem(withTitle: "Keep output device awake", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        setHolding(true)
    }

    @objc private func toggle() { setHolding(!holding) }

    private func setHolding(_ on: Bool) {
        if on {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
            var frames: UInt32 = 4096
            addr.mSelector = kAudioDevicePropertyBufferFrameSize
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
            AudioDeviceStart(device, nil)
        } else {
            AudioDeviceStop(device, nil)
        }
        holding = on
        item.menu?.item(at: 0)?.state = on ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
