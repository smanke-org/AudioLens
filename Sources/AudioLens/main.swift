import AppKit
import AudioLensKit
import SwiftUI

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
app.run()

/// Quits AudioLens without asking: for quitting itself (installing an update, ending a test).
@MainActor
enum QuitConfirmation {
    private(set) static var confirmed = false

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

/// Launch, menus, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// Links that arrive while AudioLens is still launching (the link that launched it), with
    /// the bundle id of the app that was in front then; nil once launching is done.
    private var pendingURLs: [(url: URL, frontmost: String?)]? = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        SettingsStore.shared.applyAppearance()

        #if DEBUG
        // Before sync, the engine and the updater, so a test copy touches none of them.
        if DebugHooks.runQuitTest() { return }
        // The update prompt, What's New and Settings drawn to PNGs; also starts nothing else.
        if DebugUpdateNotes.run() { return }
        #endif

        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !UserDefaults.standard.bool(forKey: "launchedBefore")
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()

        _ = CapturePermission.shared
        OutputDevices.shared.start()
        AudioEngine.shared.start()
        // ToolHUD lights its Mute button while the app it would mute is muted.
        ToolHUDFeatureStates.start {
            ["mute": AudioEngine.shared.hotKeyTarget.map { SettingsStore.shared.app($0.id).muted } ?? false]
        }
        MultiRoomStream.shared.apply()
        HotKeys.shared.apply()
        ShortcutsLensReport.start { HotKeys.shared.reportedShortcuts }

        setUpStatusItem()
        // ToolHUD can take the menu into its own while it runs.
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = MenuHub.shared.showsOwnIcon }
        }
        // ToolHUD gets the right-click menu, led by the compact panel in its own window,
        // since the drop-down needs the menu bar icon to hang from.
        MenuHub.shared.onChange = { SettingsSync.shared.localDidChange() }
        MenuHub.shared.start(menu: { [weak self] in
            let menu = NSMenu()
            guard let self else { return menu }
            menuNeedsUpdate(menu)
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item("Show Compact Panel", #selector(showCompactPanel)).showIcon("arrow.down.right.and.arrow.up.left"), at: 0)
            return menu
        }, icon: { [weak self] in self?.statusItem?.button?.image })

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
        // Launched by a link (ToolHUD's buttons), it does what the link asks and no more, so a
        // volume button doesn't bring the window up over the app you're in.
        let atLogin = Self.launchedAsLoginItem
        let early = pendingURLs ?? []
        pendingURLs = nil
        if newInstall || (early.isEmpty && (!atLogin || (!AppPresence.showInMenuBar && !AppPresence.showInDock))) {
            MainWindow.shared.show()
        }
        for (url, frontmost) in early { run(url, frontmost: frontmost) }
    }

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when AudioLens quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard SettingsStore.shared.confirmQuit, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }
        closePopover()

        // Without a Dock icon AudioLens needs to be a regular app for the alert to come to the
        // front; the old policy goes back a runloop turn later, once the alert is gone (AppKit
        // ignores it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.name)?"
        alert.informativeText = "App volumes, EQ and hotkeys stop working until you open \(AppInfo.name) again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { SettingsStore.shared.confirmQuit = false }
        return .terminateNow
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

    /// `audiolens://` links, for ToolHUD, Shortcuts, scripts and our other apps; `URLCommand`
    /// lists them. Nothing here brings AudioLens forward unless the link opens a window, so
    /// the app in front when the link arrives is still the one the hotkey actions see.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Captured now, before anything AudioLens does can change it.
        let candidate = NSWorkspace.shared.frontmostApplication
        let frontmost = candidate?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : candidate?.bundleIdentifier
        if pendingURLs != nil {
            // Launching: the engine hasn't looked for playing apps yet.
            pendingURLs?.append(contentsOf: urls.map { ($0, frontmost) })
            return
        }
        for url in urls { run(url, frontmost: frontmost) }
    }

    private func run(_ url: URL, frontmost: String?) {
        guard let command = URLCommand(url: url) else { return }
        switch command {
        case .showWindow: MainWindow.shared.show()
        case .compactPanel: MainWindow.shared.show(compact: true)
        case .menuBarPanel:
            // After the URL's own activation settles, or the transient popover closes at once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                // With the icon in ToolHUD's menu there's nothing to hang it from.
                if MenuHub.shared.isHosted { return MainWindow.shared.show(compact: true) }
                guard let self, let button = self.statusItem?.button, self.statusItem?.isVisible == true else { return }
                if self.popover?.isShown != true { self.togglePopover(button) }
            }
        case .settings: SettingsWindow.shared.show()
        case .nudge(let nudge):
            let action: HotKeys.Action = switch nudge { case .up: .up; case .down: .down; case .mute: .mute }
            HotKeys.shared.perform(action, on: AudioEngine.shared.hotKeyTarget(frontmost: frontmost))
        case .nextOutput:
            guard let device = OutputDevices.shared.makeNextDefault() else { return NSSound.beep() }
            VolumeHUD.shared.show(device: device)
        case .setVolume(let target, let percent):
            adjustApp(target, frontmost: frontmost) { s, maxVolume in
                guard let percent else { return }
                s.volume = min(max(percent / 100, 0), maxVolume)
                if percent > 0 { s.muted = false }
            }
        case .setMuted(let target, let muted):
            adjustApp(target, frontmost: frontmost) { s, _ in s.muted = muted ?? !s.muted }
        case .eq(let device, let preset, let enabled):
            adjustEQ(device: device, preset: preset, enabled: enabled)
        }
    }

    private func targetApp(_ target: URLCommand.Target, frontmost: String?) -> (id: String, name: String?)? {
        switch target {
        case .playing:
            return AudioEngine.shared.hotKeyTarget(frontmost: frontmost).map { ($0.id, $0.name) }
        case .app(let key):
            let running = AudioEngine.shared.running.values.first { $0.id == key || $0.bundleID == key || $0.name == key }
            return (running?.id ?? key, running?.name)
        }
    }

    private func adjustApp(_ target: URLCommand.Target, frontmost: String?, _ change: (inout AppAudioSettings, Double) -> Void) {
        guard let (id, name) = targetApp(target, frontmost: frontmost) else { return NSSound.beep() }
        let store = SettingsStore.shared
        store.updateApp(id) { s in
            if s.name == nil { s.name = name }
            change(&s, store.maxVolume)
        }
    }

    private func adjustEQ(device: String?, preset name: String?, enabled: Bool?) {
        let devices = OutputDevices.shared
        guard let uid = device.flatMap({ $0 == "default" ? devices.defaultUID : $0 }) ?? devices.defaultUID else { return }
        SettingsStore.shared.updateDevice(uid) { s in
            if let name, let preset = EQPreset.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                s.eqGains = preset.gains
                s.eqEnabled = true
            }
            if let enabled { s.eqEnabled = enabled }
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

        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(item("AudioLens Help", #selector(showHelp), key: "?"))
        helpItem.submenu = help
        NSApp.helpMenu = help
        main.addItem(helpItem)
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
        menu.addItem(item("Open AudioLens", #selector(showWindow)).showIcon("slider.horizontal.3"))
        let helpEntry = item("AudioLens Help", #selector(showHelp))
        helpEntry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(helpEntry)
        menu.addItem(item("Settings…", #selector(showSettings), key: ",").showIcon("gearshape"))
        menu.addItem(.separator())
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)).showIcon("arrow.down.circle"))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)).showIcon("arrow.down.circle"))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)).showIcon("arrow.down.circle"))
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
        item.isVisible = MenuHub.shared.showsOwnIcon
        statusItem = item
    }

    @objc private func showCompactPanel() { MainWindow.shared.show(compact: true) }

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
    @objc func showHelp() { closePopover(); HelpWindow.shared.show() }
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
        AppInfo.showAbout()
    }
}
