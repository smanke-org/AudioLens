import AppKit
import AudioLensKit
import SwiftUI

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
app.run()

/// Launch, menus, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !UserDefaults.standard.bool(forKey: "launchedBefore")
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()

        _ = CapturePermission.shared
        OutputDevices.shared.start()
        AudioEngine.shared.start()
        MultiRoomStream.shared.apply()
        HotKeys.shared.apply()

        setUpStatusItem()
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = AppPresence.showInMenuBar }
        }

        #if DEBUG
        if DebugHooks.run() { return }
        #endif

        if let file = ProcessInfo.processInfo.environment["AUDIOLENS_AIRPLAY_LAB"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AirPlayLab.shared.show(file: file) }
        }
        // Testing: AUDIOLENS_AIRPLAY_SELECT="Bathroom" (or "-" for off, "?" to just read).
        if let name = ProcessInfo.processInfo.environment["AUDIOLENS_AIRPLAY_SELECT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                switch name {
                case "?": AirPlaySpeakers.shared.refresh()
                case "-": AirPlaySpeakers.shared.select(nil)
                default: AirPlaySpeakers.shared.select(name)
                }
            }
        }
        AutoUpdater.shared.start()
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        // At login, AudioLens starts quietly in the background unless it has no icon to click.
        let atLogin = Self.launchedAsLoginItem
        if newInstall || !atLogin || (!AppPresence.showInMenuBar && !AppPresence.showInDock) {
            MainWindow.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Every app back to playing straight to its device.
        AudioEngine.shared.stopAll()
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("Open AudioLens", #selector(showWindow)))
        menu.addItem(item("Compact Panel", #selector(showCompact)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings)))
        return menu
    }

    /// Opening the app again (from Applications, Spotlight, or the Dock tile) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// For Shortcuts, scripts and our other apps:
    ///
    ///     audiolens://show                        the window
    ///     audiolens://compact                     the compact panel
    ///     audiolens://menubar                     the menu bar drop-down
    ///     audiolens://settings                    Settings
    ///     audiolens://volume?app=<bundle id>&value=<0–150>
    ///     audiolens://mute?app=<bundle id>&on=<1|0>   (no "on" toggles)
    ///     audiolens://eq?device=<UID|default>&preset=<name>&on=<1|0>
    ///
    /// `app` may also be `playing`, the app the hotkeys act on.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "audiolens" {
            let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .compactMap { item in item.value.map { (item.name, $0) } } ?? [], uniquingKeysWith: { _, b in b })
            switch url.host {
            case "compact": MainWindow.shared.show(compact: true)
            case "menubar":
                // After the URL's own activation settles, or the transient popover closes at once.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, let button = self.statusItem?.button, self.statusItem?.isVisible == true else { return }
                    if self.popover?.isShown != true { self.togglePopover(button) }
                }
            case "settings": SettingsWindow.shared.show()
            case "volume", "mute": adjustApp(url.host!, query)
            case "eq": adjustEQ(query)
            default: MainWindow.shared.show()
            }
        }
    }

    private func targetApp(_ query: [String: String]) -> (id: String, name: String?)? {
        guard let key = query["app"] else { return nil }
        if key == "playing" { return AudioEngine.shared.hotKeyTarget.map { ($0.id, $0.name) } }
        let running = AudioEngine.shared.running.values.first { $0.id == key || $0.bundleID == key || $0.name == key }
        return (running?.id ?? key, running?.name)
    }

    private func adjustApp(_ action: String, _ query: [String: String]) {
        guard let (id, name) = targetApp(query) else { return NSSound.beep() }
        let store = SettingsStore.shared
        store.updateApp(id) { s in
            if s.name == nil { s.name = name }
            if action == "volume", let value = query["value"].flatMap(Double.init) {
                s.volume = min(max(value / 100, 0), store.maxVolume)
                if value > 0 { s.muted = false }
            } else if action == "mute" {
                s.muted = query["on"].map { $0 == "1" || $0 == "true" } ?? !s.muted
            }
        }
    }

    private func adjustEQ(_ query: [String: String]) {
        let devices = OutputDevices.shared
        guard let uid = query["device"].flatMap({ $0 == "default" ? devices.defaultUID : $0 }) ?? devices.defaultUID else { return }
        SettingsStore.shared.updateDevice(uid) { s in
            if let name = query["preset"], let preset = EQPreset.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                s.eqGains = preset.gains
                s.eqEnabled = true
            }
            if let on = query["on"] { s.eqEnabled = on == "1" || on == "true" }
        }
    }

    // MARK: - Menus

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("About AudioLens", #selector(showAbout)))
        appMenu.addItem(item("Our other apps…", #selector(showOtherApps)))
        appMenu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AudioLens", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AudioLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.delegate = self
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("AudioLens", #selector(showWindow), key: "0"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        main.addItem(windowItem)
        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "View" {
            let store = SettingsStore.shared
            for (i, layout) in WindowLayout.allCases.enumerated() {
                let entry = item(layout.title, #selector(chooseLayout(_:)), key: "\(i + 1)")
                entry.tag = i
                entry.state = !store.compact && store.layout == layout ? .on : .off
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let compact = item("Compact Panel", #selector(toggleCompact), key: "C")
            compact.keyEquivalentModifierMask = [.command, .shift]
            compact.state = store.compact ? .on : .off
            menu.addItem(compact)
            let float = item("Keep Compact Panel on Top", #selector(toggleFloat))
            float.state = MainWindow.shared.compactFloats ? .on : .off
            menu.addItem(float)
            return
        }

        // The status item's menu, for a right-click or Control-click.
        menu.addItem(item("Open AudioLens", #selector(showWindow)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(item("About AudioLens", #selector(showAbout)))
        menu.addItem(item("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "AudioLens \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit AudioLens", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "AudioLens")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.isVisible = AppPresence.showInMenuBar
        statusItem = item
    }

    /// A click opens the compact panel; a right-click or Control-click opens the menu.
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.delegate = self
            menuNeedsUpdate(menu)
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
            return
        }
        togglePopover(sender)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = self.popover ?? {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            let hosting = NSHostingController(rootView: CompactPanel(mode: .menuBar))
            // A fixed size set here, not SwiftUI's ideal size: the panel's scrolling list has no
            // natural height, and a popover taller than the room under the menu bar gets pushed
            // up over it.
            hosting.sizingOptions = []
            p.contentViewController = hosting
            return p
        }()
        self.popover = popover
        AirPlayBrowser.shared.start()
        let room = (sender.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        popover.contentSize = NSSize(width: CompactPanel.width, height: min(560, max(room - 30, 300)))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() { popover?.performClose(nil) }

    // MARK: - Actions

    @objc func showWindow() { closePopover(); MainWindow.shared.show() }
    @objc func showCompact() { MainWindow.shared.show(compact: true) }
    @objc func showSettings() { closePopover(); SettingsWindow.shared.show() }
    @objc func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc func installUpdateNow() { AutoUpdater.shared.installNow() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func chooseLayout(_ sender: NSMenuItem) {
        MainWindow.shared.setLayout(WindowLayout.allCases[sender.tag])
    }

    @objc func toggleCompact() {
        MainWindow.shared.setCompact(!SettingsStore.shared.compact)
    }

    @objc func toggleFloat() {
        MainWindow.shared.compactFloats.toggle()
    }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
