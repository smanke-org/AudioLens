import AppKit
import AudioLensKit
import SwiftUI

/// The panes, down the sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, devices, apps, hotkeys, sync, updates

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .devices: "Devices"
        case .apps: "Apps"
        case .hotkeys: "Hotkeys"
        case .sync: "Sync"
        case .updates: "Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .devices: "hifispeaker.2"
        case .apps: "square.grid.2x2"
        case .hotkeys: "keyboard"
        case .sync: "icloud"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// Settings in an AppKit window with a sidebar, so the Dock menu and the menu bar item can
/// open it (SwiftUI's Settings scene can't be opened from AppKit).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    fileprivate let selection = PaneSelection()

    func show(_ pane: SettingsPane? = nil) {
        LaunchAtLogin.shared.refresh()
        if let pane { selection.pane = pane }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRoot(selection: selection))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 600))
            window.contentMinSize = NSSize(width: 700, height: 460)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("AudioLensSettings")
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = "AudioLens Settings"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

@Observable
@MainActor
final class PaneSelection {
    var pane: SettingsPane = .general
}

struct SettingsRoot: View {
    @State var selection: PaneSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding<SettingsPane?>(get: { selection.pane },
                                                                          set: { if let p = $0 { selection.pane = p } })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                switch selection.pane {
                case .general: GeneralSettings()
                case .devices: DevicesPane()
                case .apps: AppsSettings()
                case .hotkeys: HotkeySettings()
                case .sync: SyncSettings()
                case .updates: UpdateSettings()
                }
                Text("\(AppInfo.name) \(AppInfo.displayVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            .navigationTitle(selection.pane.title)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var store = SettingsStore.shared
    @State private var presence = PresenceSettings.shared
    @State private var login = LaunchAtLogin.shared
    @State private var permission = CapturePermission.shared
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                LayoutPicker()
            } header: {
                Text("Window layout")
            } footer: {
                Text("Also in the View menu (⌘1 to ⌘4). Press ⇧⌘C in any layout to shrink to the compact panel. The layout is saved for this Mac only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Where AudioLens appears") {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "AudioLens", settingsName: "the AudioLens window"))
                        .font(.callout).foregroundStyle(.secondary)
                } else if presence.showInMenuBar {
                    Text("The menu bar icon opens the compact panel.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Open AudioLens at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval {
                    Button("Allow in Login Items…") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } footer: {
                Text("Per-app volumes and EQ only work while AudioLens is running, so opening it at login keeps them in effect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apps list") {
                Toggle("Show pinned apps when they're silent", isOn: $store.showPinnedWhenSilent)
                Toggle("Allow volume boost up to 150%", isOn: $store.allowBoost)
                if store.allowBoost {
                    Text("A limiter keeps boosted audio from distorting.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("System Audio Recording") {
                    switch permission.status {
                    case .authorized: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied: Button("Open Privacy & Security") { permission.openSettings() }
                    case .unknown: Button("Allow…") { permission.request() }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("AudioLens needs this to change an app's volume or apply an EQ. It processes the sound on your Mac and never records or sends it anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("About") {
                    HStack {
                        Button("About AudioLens") {
                            NSApp.activate(ignoringOtherApps: true)
                            NSApp.orderFrontStandardAboutPanel(nil)
                        }
                        Button("Our other apps…") {
                            if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                LabeledContent("Volumes, EQ and options") {
                    Button("Reset to Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh(); permission.refresh() }
        .confirmationDialog("Reset AudioLens settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.resetToDefaults() }
        } message: {
            Text("Every app goes back to 100% on the system output, every device's EQ and correction are cleared, and pins, ignores and hotkeys go back to how AudioLens started. Where it appears, login, sync and updates stay as they are.")
        }
    }
}

/// The four layouts as thumbnails.
struct LayoutPicker: View {
    @State private var store = SettingsStore.shared

    var body: some View {
        HStack(spacing: 14) {
            ForEach(WindowLayout.allCases) { layout in
                Button {
                    MainWindow.shared.setLayout(layout)
                } label: {
                    VStack(spacing: 6) {
                        LayoutThumbnail(layout: layout)
                            .frame(width: 96, height: 62)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(store.layout == layout ? Color.accentColor : Color.primary.opacity(0.15),
                                              lineWidth: store.layout == layout ? 2 : 1))
                        Text(layout.title).font(.caption)
                            .foregroundStyle(store.layout == layout ? Color.accentColor : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(layout.title)
                .accessibilityAddTraits(store.layout == layout ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// A schematic of each layout.
struct LayoutThumbnail: View {
    let layout: WindowLayout

    var body: some View {
        let fill = Color.primary.opacity(0.12)
        let accent = Color.accentColor.opacity(0.35)
        Group {
            switch layout {
            case .sourceList:
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(fill).frame(width: 22)
                    VStack(spacing: 3) { ForEach(0..<5, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(fill) } }
                }
            case .mixingDesk:
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(fill) }
                    RoundedRectangle(cornerRadius: 2).fill(accent)
                }
            case .dialBoard:
                VStack(spacing: 3) {
                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(fill) } }.frame(height: 9)
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(fill) } }
                    }
                }
            case .deviceInspector:
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(fill).frame(width: 18)
                    VStack(spacing: 3) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(fill) } }
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(fill)
                        RoundedRectangle(cornerRadius: 2).fill(accent)
                    }
                    .frame(width: 28)
                }
            }
        }
        .padding(5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Apps

struct AppsSettings: View {
    var body: some View {
        VStack(spacing: 0) {
            PinnedPane()
            IgnoredPane()
        }
    }
}

// MARK: - Hotkeys

struct HotkeySettings: View {
    @State private var store = SettingsStore.shared
    @State private var hotkeys = HotKeys.shared

    var body: some View {
        Form {
            Section {
                row("Turn the playing app up", $store.hotKeyUp, .up)
                row("Turn the playing app down", $store.hotKeyDown, .down)
                row("Mute or unmute the playing app", $store.hotKeyMute, .mute)
                Picker("Each press changes the volume by", selection: $store.volumeStep) {
                    ForEach([0.02, 0.05, 0.10, 0.20], id: \.self) { Text(percentText($0)).tag($0) }
                }
            } footer: {
                Text("The playing app is the frontmost app if it's making sound, otherwise the app that started playing most recently. Click a shortcut, then press the new keys; Delete clears it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ binding: Binding<Shortcut?>, _ action: HotKeys.Action) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) { ShortcutRecorder(shortcut: binding) }
            if hotkeys.isFailed(action), let key = binding.wrappedValue {
                Text("Another app is already using \(key.display). Pick another shortcut.").font(.caption).foregroundStyle(.red)
            } else if let key = binding.wrappedValue, let purpose = SystemShortcuts.purpose(of: key) {
                Text("\(key.display) is the macOS shortcut for \(purpose). Pick another one.").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Sync

struct SyncSettings: View {
    @State private var sync = SettingsSync.shared

    var body: some View {
        Form {
            Section {
                Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
                if sync.isEnabled {
                    switch sync.keyState {
                    case .ready:
                        LabeledContent {
                            Button("Sync Now") { sync.syncNow() }
                        } label: {
                            if let error = sync.lastError {
                                Text(error).foregroundStyle(.red)
                            } else if let date = sync.lastSynced {
                                Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == SettingsSync.deviceName ? "" : " from \($0)" } ?? "")")
                            } else {
                                Text("Waiting for iCloud Drive…")
                            }
                        }
                        SyncPassphraseForm(mode: .change)
                    case .needsNewPassphrase, .needsPassphrase:
                        SyncPassphraseForm(mode: sync.keyState == .needsPassphrase ? .enter : .create)
                            .id(sync.keyState == .needsPassphrase)
                    case .inactive:
                        Text(sync.lastError ?? "Checking iCloud Drive…").foregroundStyle(sync.lastError == nil ? Color.secondary : Color.red)
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("App volumes, mutes, pins, ignores and outputs, each device's EQ, headphone correction and restore choices, and your options and hotkeys follow you to every Mac signed in to the same iCloud account with sync turned on. They're encrypted on this Mac with your sync passphrase before they reach iCloud Drive, so neither Apple nor the developer can read them. Each Mac keeps its own device volumes, window layout and open-at-login choice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

struct UpdateSettings: View {
    @State private var updater = AutoUpdater.shared

    private var footer: String {
        switch updater.policy {
        case .automatic:
            "AudioLens checks \(updater.interval.phrase). A new version installs itself when no app is presenting or keeping the screen awake and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            "AudioLens checks \(updater.interval.phrase) and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            "AudioLens won't look for updates on its own. Use Check Now whenever you like."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if updater.policy != .off {
                    UpdateIntervalPicker(interval: $updater.interval)
                }
                if let staged = updater.staged {
                    LabeledContent("Version \(staged.version) is ready") {
                        Button("Install Now") { updater.installNow() }
                    }
                }
                LabeledContent("Version \(AppInfo.displayVersion)") {
                    Button("Check Now") { UpdateController.checkForUpdates() }
                }
                if let error = updater.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if updater.policy != .off && !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for AudioLens, so update news only shows in the menu.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { updater.refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.refreshNotificationStatus()
        }
    }
}
