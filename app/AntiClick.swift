// AntiClick menu-bar app: keeps USB audio devices running so they don't click
// or pop, and shows what it's doing next to the clock. The audio work is done
// by the shared C engine (src/engine.c), imported through src/engine.h.
import AppKit
import ServiceManagement

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "PreventClicks"
        static let anyTransport = "IncludeNonUSBDevices"
        static let silentStream = "CompatibilityMode"
        static let offeredLogin = "OfferedOpenAtLogin"
    }

    private enum State {
        case paused
        case holding([String])
        case waiting(String, String)    // device, reason
        case idle(String)               // current output ("" = none)
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if anotherCopyIsRunning() {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: [Key.enabled: true, Key.anyTransport: false, Key.silentStream: false])

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        ac_set_enabled(defaults.bool(forKey: Key.enabled))
        ac_set_any_transport(defaults.bool(forKey: Key.anyTransport))
        ac_set_force_silence(defaults.bool(forKey: Key.silentStream))
        ac_engine_start({ context in
            // The engine always calls back on the main thread.
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<AppController>.fromOpaque(context).takeUnretainedValue().refreshIcon()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        refreshIcon()

        DispatchQueue.main.async { self.offerOpenAtLoginOnce() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ac_engine_stop()
    }

    private func anotherCopyIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me }
    }

    // MARK: Status

    private var state: State {
        guard ac_status_enabled() else { return .paused }
        let count = Int(ac_status_held_count())
        if count == 0 { return .idle(String(cString: ac_status_output_name())) }
        var names: [String] = []
        for i in 0..<count {
            let name = String(cString: ac_status_held_name(Int32(i)))
            if !ac_status_held_running(Int32(i)) {
                return .waiting(name, String(cString: ac_status_last_error()))
            }
            names.append(name)
        }
        return .holding(names)
    }

    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let icon: MenuBarIcon.State
        let tip: String
        switch state {
        case .paused:
            icon = .paused
            tip = "AntiClick is paused"
        case .holding(let names):
            icon = .active
            tip = "AntiClick is keeping \(Self.list(names)) awake"
        case .waiting(let name, _):
            icon = .waiting
            tip = "AntiClick is waiting for \(Self.quoted(name))"
        case .idle(let output):
            icon = .idle
            tip = output.isEmpty ? "AntiClick: no output device"
                                 : "AntiClick: \(Self.quoted(output)) doesn't need holding"
        }
        button.image = MenuBarIcon.image(for: icon, description: tip)
        button.toolTip = tip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusLine: String
        switch state {
        case .paused:
            statusLine = "Paused: clicks are not being prevented"
        case .holding(let names):
            statusLine = "Keeping \(Self.list(names)) awake"
        case .waiting(let name, let reason):
            statusLine = "Waiting for \(Self.quoted(name))" + (reason.isEmpty ? "" : ": \(reason)")
        case .idle(let output):
            if output.isEmpty {
                statusLine = "No output device"
            } else if defaults.bool(forKey: Key.anyTransport) {
                statusLine = "Idle"
            } else {
                statusLine = "Idle: \(Self.quoted(output)) isn't a USB device"
            }
        }
        menu.addItem(info(statusLine))
        let output = String(cString: ac_status_output_name())
        if !output.isEmpty {
            menu.addItem(info("Output: \(output) (\(String(cString: ac_status_output_transport())))"))
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Prevent Clicks", on: ac_status_enabled(), action: #selector(toggleEnabled)))

        menu.addItem(.separator())
        menu.addItem(toggle("Include Non-USB Devices", on: defaults.bool(forKey: Key.anyTransport),
                            action: #selector(toggleAnyTransport),
                            tip: "Also keep built-in, HDMI, Thunderbolt and other output devices running. Not recommended for Bluetooth headphones."))
        menu.addItem(toggle("Compatibility Mode", on: defaults.bool(forKey: Key.silentStream),
                            action: #selector(toggleSilentStream),
                            tip: "Play digital silence instead of only starting the hardware. Try this if a device still clicks."))
        menu.addItem(toggle("Open at Login", on: SMAppService.mainApp.status == .enabled,
                            action: #selector(toggleOpenAtLogin)))

        menu.addItem(.separator())
        let activity = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let lines = Int(ac_recent_count())
        if lines == 0 { submenu.addItem(info("Nothing yet")) }
        for i in 0..<min(lines, 12) {
            submenu.addItem(info(String(cString: ac_recent_line(Int32(i)))))
        }
        activity.submenu = submenu
        menu.addItem(activity)

        let about = NSMenuItem(title: "About AntiClick", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit AntiClick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(_ title: String, on: Bool, action: Selector, tip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.toolTip = tip
        return item
    }

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }
    private static func list(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names.map(quoted))
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        let on = !ac_status_enabled()
        defaults.set(on, forKey: Key.enabled)
        ac_set_enabled(on)
    }

    @objc private func toggleAnyTransport() {
        let on = !defaults.bool(forKey: Key.anyTransport)
        defaults.set(on, forKey: Key.anyTransport)
        ac_set_any_transport(on)
    }

    @objc private func toggleSilentStream() {
        let on = !defaults.bool(forKey: Key.silentStream)
        defaults.set(on, forKey: Key.silentStream)
        ac_set_force_silence(on)
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showError("Couldn't change Open at Login", error)
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func showAbout() {
        activate()
        let credits = NSAttributedString(
            string: "Keeps USB audio interfaces and DACs running so they don't click or pop when macOS starts and stops sounds.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Open at Login

    /// Ask once, on first launch, instead of adding a login item silently.
    private func offerOpenAtLoginOnce() {
        guard !defaults.bool(forKey: Key.offeredLogin) else { return }
        defaults.set(true, forKey: Key.offeredLogin)
        guard SMAppService.mainApp.status != .enabled else { return }

        activate()
        let alert = NSAlert()
        alert.messageText = "Open AntiClick automatically when you log in?"
        alert.informativeText = "AntiClick only prevents clicks while it's running. It lives in the menu bar and uses almost no CPU. You can change this any time from its menu."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            showError("Couldn't add AntiClick to Login Items", error)
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func showError(_ title: String, _ error: Error) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct AntiClickMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let controller = AppController()
            app.delegate = controller
            app.run()
        }
    }
}
