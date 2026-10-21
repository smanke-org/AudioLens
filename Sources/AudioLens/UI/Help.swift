import AppKit
import AudioLensKit
import SwiftUI

// MARK: - Content

/// One page of Help. `{hotkey:up}`, `{hotkey:down}` and `{hotkey:mute}` show the user's own
/// hotkeys, so the text matches their settings.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    static func resolve(_ text: String) -> String {
        guard text.contains("{") else { return text }
        let store = SettingsStore.shared
        func key(_ shortcut: Shortcut?) -> String { shortcut?.display ?? "(no shortcut set)" }
        return text
            .replacingOccurrences(of: "{hotkey:up}", with: key(store.hotKeyUp))
            .replacingOccurrences(of: "{hotkey:down}", with: key(store.hotKeyDown))
            .replacingOccurrences(of: "{hotkey:mute}", with: key(store.hotKeyMute))
            .replacingOccurrences(of: "{step}", with: "\(Int((store.volumeStep * 100).rounded()))%")
    }

    /// The topic each Settings pane's Help button opens.
    static func topic(for pane: SettingsPane) -> String {
        switch pane {
        case .general: "getting-started"
        case .devices: "devices"
        case .apps: "apps"
        case .hotkeys: "hotkeys"
        case .sync: "sync"
        case .updates: "sync"
        }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("AudioLens gives every app that's playing its own volume, separate from your Mac's volume, from silent to 150%. It can send an app to a different speaker or headphones, and it remembers each output device's volume and EQ, so they come back the moment that device connects."),
            .heading("Allow System Audio Recording"),
            .text("The first time you change an app's volume, macOS asks for System Audio Recording permission. Allow it: AudioLens needs it to change an app's sound. The sound only passes through AudioLens on your Mac; nothing is recorded or sent anywhere. If you said no, Settings › General › Permission opens the right place in System Settings."),
            .text("Apps playing at 100% on the system output with no EQ are left alone, so AudioLens costs nothing until you change something."),
            .heading("Where to find it"),
            .keys([
                ("Menu bar icon", "Click for the compact panel; right-click or Control-click for the menu"),
                ("Dock icon", "Opens the window"),
                ("⌘0", "Bring the AudioLens window back"),
                ("⇧⌘C", "Shrink the window to the compact panel, or back"),
                ("⌘1 to ⌘4", "Choose a layout (View menu)"),
                ("⌘,", "Settings"),
                ("⌘?", "This Help"),
            ]),
            .tip("While ToolHUD is running, AudioLens's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings › General."),
        ]),

        HelpTopic(id: "apps", title: "App Volumes", symbol: "slider.horizontal.3", blocks: [
            .text("Every app that's playing gets a slider, from silent to 150%. Above 100% a soft limiter keeps boosted sound from distorting. Click the speaker beside an app to mute it. Volumes are remembered, across restarts too."),
            .tip("To change a slider with the scroll wheel or trackpad, hold Option while you scroll over it. Plain scrolling always scrolls the list."),
            .heading("Right-click an app"),
            .keys([
                ("Mute", "Mute or unmute the app"),
                ("Pin", "Keep the app listed while it's silent"),
                ("Play To", "Send the app to another output, or back to the system output"),
                ("Back to 100%", "Reset its volume and send it to the system output"),
                ("Ignore", "Leave the app completely alone: no volume change, no EQ, not listed"),
            ]),
            .heading("Recent apps"),
            .text("Apps that played before stay in a Recent list until you remove them, so you can set their volume or output before they play again. The x beside one removes it."),
            .text("Settings › Apps lists pinned and ignored apps, where you can unpin them or stop ignoring them. Settings › General › Apps list chooses whether pinned apps show while they're silent, and whether volumes can go above 100%."),
            .tip("Once AudioLens adjusts an app, it keeps handling that app's sound until the app quits."),
        ]),

        HelpTopic(id: "devices", title: "Devices", symbol: "hifispeaker.2", blocks: [
            .text("Each output device, such as speakers, headphones, AirPods, HomePods or a display, keeps its own volume on each Mac. When a device becomes the output again, AudioLens puts its volume back."),
            .keys([
                ("Restore when connected", "Put this device's volume back each time it becomes the output"),
                ("Lock volume", "Keep the device at this level even if something else changes it"),
                ("Use as Output", "Make the device the Mac's output"),
                ("Forget", "Remove a device AudioLens remembers but that isn't connected"),
            ]),
            .heading("Per-app output"),
            .text("Right-click an app and choose Play To to send it to a different device than the system output, for example a call to your AirPods while music plays on the speakers. If that device isn't connected, the app plays to the system output until it is."),
            .heading("When AudioLens quits"),
            .text("AudioLens keeps your Mac's own volume at the level of the loudest app it's adjusting, and turns quieter apps down from there. If AudioLens quits or crashes, nothing gets suddenly louder: the loudest app keeps its level, and the others rise only to it. Your device volume in AudioLens stays as you set it; only the number macOS shows moves. Turn this off in Settings › General."),
        ]),

        HelpTopic(id: "eq", title: "Equalizer", symbol: "slider.vertical.3", blocks: [
            .text("Each output device has its own 10-band equalizer with presets. It applies to every app playing to that device, except ignored apps. Use the switch to turn it on or off, and Flat to start over."),
            .heading("Headphone correction"),
            .text("Choose your headphone model to flatten its sound, from thousands of measurements in the AutoEQ project, or import a ParametricEQ.txt file. Correction and the EQ work together, and both are remembered for that device."),
            .tip("EQ and correction are kept per device, so your AirPods and your speakers can sound right without switching anything."),
        ]),

        HelpTopic(id: "airplay", title: "AirPlay", symbol: "airplayaudio", blocks: [
            .text("HomePods, Apple TVs and other AirPlay speakers on your network are listed with a Connect button. macOS plays its own sound to one AirPlay speaker at a time. With Accessibility permission, AudioLens picks the speaker for you in Control Center; without it, Connect opens Sound settings and shows which speaker to click."),
            .text("Once connected, a speaker is an ordinary output with its own remembered volume and EQ."),
            .heading("Play on several outputs"),
            .text("Turn on \"Play on several outputs at once\" and check two or more outputs, such as the Mac's speakers and a HomePod. AudioLens holds the faster outputs back to match AirPlay's delay. If one sounds ahead, use the Sync slider. Every app goes through AudioLens while this is on."),
            .tip("For several HomePods, check them together in Control Center › Sound; they join as one AirPlay output."),
            .heading("Multi-room AirPlay"),
            .text("To play on several HomePods or Apple TVs at once, as Music does, turn on Multi-room AirPlay and check every speaker to play on. Leave this Mac unchecked in that list, and turn on \"Also play on\" to add its own speakers, kept in sync."),
        ]),

        HelpTopic(id: "layouts", title: "Layouts", symbol: "rectangle.3.group", blocks: [
            .text("Choose a layout in Settings › General or the View menu. The choice is saved for this Mac only."),
            .keys([
                ("⌘1", "Source List, the default"),
                ("⌘2", "Mixing Desk"),
                ("⌘3", "Dial Board"),
                ("⌘4", "Device Inspector"),
                ("⇧⌘C", "Shrink any layout to the compact panel, or back"),
            ]),
            .text("The compact panel is a slim list of playing apps with the output device and its EQ. The menu bar icon opens the same panel. View › Keep Compact Panel on Top keeps it above other windows."),
            .text("Settings › General chooses whether AudioLens shows in the Dock, the menu bar, both or neither. With both off, open AudioLens again from Applications or Spotlight to get the window back."),
        ]),

        HelpTopic(id: "hotkeys", title: "Hotkeys", symbol: "keyboard", blocks: [
            .text("Change the volume of the app that's playing from anywhere, without opening AudioLens."),
            .keys([
                ("{hotkey:up}", "Turn the playing app up by {step}"),
                ("{hotkey:down}", "Turn it down by {step}"),
                ("{hotkey:mute}", "Mute or unmute it"),
            ]),
            .text("The playing app is the frontmost app if it's making sound, otherwise the app that started playing most recently. A volume indicator shows the app and its new level."),
            .text("Set the keys and the step in Settings › Hotkeys: click a shortcut, then press the new keys. Delete clears it. If another app already uses a shortcut, Settings says so."),
        ]),

        HelpTopic(id: "toolhud", title: "ToolHUD's Menu", symbol: "circle.circle", blocks: [
            .text("ToolHUD gathers the menu bar icons of the developer's apps into its own menu. While ToolHUD is running, AudioLens's menu becomes a submenu of ToolHUD's menu bar menu, and AudioLens's own icon leaves the menu bar."),
            .text("The submenu starts with Show Compact Panel, which opens the compact panel in its own window, since there's no menu bar icon for it to hang from. The rest is AudioLens's usual menu: Open AudioLens, AudioLens Help, Settings, updates, About and Quit."),
            .text("To keep AudioLens's icon in the menu bar, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings › General. If ToolHUD quits, the icon comes back right away."),
            .tip("A ToolHUD keystroke button can press AudioLens's hotkeys, to turn the playing app up, down or mute it from ToolHUD's ring."),
        ]),

        HelpTopic(id: "sync", title: "Sync and Updates", symbol: "icloud", blocks: [
            .text("Turn on sync in Settings › Sync to keep app volumes, mutes, pins, ignores and outputs, each device's EQ and headphone correction, and your options and hotkeys the same on every Mac signed in to the same iCloud account. They're encrypted with a passphrase you choose; enter the same one on each Mac."),
            .text("Each Mac keeps its own device volumes, window layout and open-at-login choice."),
            .heading("Updates"),
            .text("AudioLens checks for a new version once a day, or on the schedule you set in Settings › Updates. It can install automatically, ask first, or not check at all. Automatic installs wait until no adjusted app is playing and your Mac isn't in use."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .text("Shortcuts, scripts and other apps can open these links:"),
            .keys([
                ("audiolens://show", "Open the window"),
                ("audiolens://compact", "Open the compact panel"),
                ("audiolens://menubar", "Open the menu bar drop-down"),
                ("audiolens://settings", "Open Settings"),
                ("audiolens://volume?app=…&value=…", "Set an app's volume, 0 to 150"),
                ("audiolens://mute?app=…&on=1", "Mute (on=0 unmutes; leave on out to toggle)"),
                ("audiolens://eq?device=default&preset=…", "Choose an EQ preset for a device"),
            ]),
            .text("For app=, use the app's bundle identifier, or playing for the app the hotkeys act on. For device=, use default for the current output."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Changing an app's volume does nothing"),
            .text("AudioLens needs System Audio Recording permission. Check Settings › General › Permission, or turn AudioLens on in System Settings › Privacy & Security › Screen & System Audio Recording."),
            .heading("An app isn't listed"),
            .text("Only apps that are playing, recent apps and pinned apps are listed. If it still doesn't appear, check Settings › Apps: it may be ignored."),
            .heading("A hotkey does nothing"),
            .text("Another app may use the same keys. Settings › Hotkeys shows a warning; record a different shortcut."),
            .heading("An AirPlay speaker isn't listed"),
            .text("Make sure it's on and on the same network. macOS connects AirPlay speakers itself, so if Connect doesn't work, choose the speaker in Control Center › Sound."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("AudioLensHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
