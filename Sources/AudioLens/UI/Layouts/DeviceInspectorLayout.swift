import AudioLensKit
import SwiftUI

/// Option 4: devices first. Pick one on the left, see what plays to it in the middle, and
/// edit its volume, connect behavior and EQ on the right.
struct DeviceInspectorLayout: View {
    enum Selection: Hashable { case device(String), allApps, pinned, ignored }

    @State private var selection: Selection?
    @State private var devices = OutputDevices.shared
    @State private var engine = AudioEngine.shared
    @State private var store = SettingsStore.shared

    private var current: Selection { selection ?? .device(devices.defaultUID ?? "") }

    /// The device the inspector shows: the selected one, or the system output.
    private var inspectedUID: String? {
        if case .device(let uid) = current, !uid.isEmpty { return uid }
        return devices.defaultUID
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { current }, set: { selection = $0 })) {
                Section("Output Devices") {
                    ForEach(knownDeviceUIDs(), id: \.self) { uid in
                        HStack {
                            DeviceSummary(uid: uid, compact: true)
                        }
                        .tag(Selection.device(uid))
                    }
                }
                ForEach(SettingsStore.shared.multiRoom.enabled ? [] : AirPlayBrowser.shared.groupedForList, id: \.kind) { group in
                    Section("AirPlay · \(group.kind.title)") {
                        ForEach(group.speakers) { AirPlaySpeakerRow(speaker: $0, compact: true) }
                    }
                }
                Section("Apps") {
                    Label("All Playing Apps", systemImage: "square.grid.2x2").badge(engine.visibleApps.count).tag(Selection.allApps)
                    Label("Pinned", systemImage: "pin").badge(store.apps.values.filter(\.pinned).count).tag(Selection.pinned)
                    Label("Ignored", systemImage: "eye.slash").badge(store.apps.values.filter(\.ignored).count).tag(Selection.ignored)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 270)
            .safeAreaInset(edge: .bottom) {
                SyncStatusLabel().frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
            }
        } detail: {
            // Two panes side by side in the detail column rather than a three-column split
            // view, which laid itself out wider than the window and clipped both edges.
            HStack(spacing: 0) {
                Group {
                    switch current {
                    case .device(let uid): appsFor(uid: uid)
                    case .allApps: AppsList(showRoute: true)
                    case .pinned: PinnedPane()
                    case .ignored: IgnoredPane()
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
                Divider()
                Group {
                    if let uid = inspectedUID {
                        DeviceInspector(uid: uid)
                    } else {
                        Text("No output device").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 400)
                .clipped()
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .navigationTitle(devices.device(uid: inspectedUID)?.name ?? "AudioLens")
    }

    private func appsFor(uid: String) -> some View {
        let apps = engine.visibleApps
        let here = apps.filter { engine.outputDevice(for: $0.id)?.uid == uid && engine.isAudible($0) }
        let elsewhere = apps.filter { engine.outputDevice(for: $0.id)?.uid != uid && engine.isAudible($0) }
        let silent = apps.filter { !engine.isAudible($0) }
        let name = devices.device(uid: uid)?.name ?? store.device(uid).name ?? "this device"
        return Form {
            PermissionBanner()
            Section("Playing to \(name)") {
                if here.isEmpty { Text("Nothing is playing here.").foregroundStyle(.secondary) }
                ForEach(here) { CompactAppRow(app: $0) }
            }
            if !elsewhere.isEmpty {
                Section("Playing Elsewhere") { ForEach(elsewhere) { CompactAppRow(app: $0) } }
            }
            if !silent.isEmpty {
                Section("Pinned · Silent") { ForEach(silent) { CompactAppRow(app: $0) } }
            }
            let recent = engine.recentApps
            if !recent.isEmpty {
                Section("Recent") { ForEach(recent) { CompactAppRow(app: $0, recent: true) } }
            }
        }
        .formStyle(.grouped)
    }
}

/// A narrower app row for the middle column and the compact panel.
struct CompactAppRow: View {
    let app: AudioApp
    var recent = false
    @State private var engine = AudioEngine.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                AppIcon(app: app, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 60, idealWidth: 118, maxWidth: 150, alignment: .leading)
                PlayingIndicator(playing: engine.isAudible(app) && !store.app(app.id).muted)
                AppVolumeSlider(app: app)
                VolumeText(app: app)
                if recent { RemoveRecentButton(app: app) }
            }
            FailureNote(app: app).padding(.leading, 36)
        }
        .contextMenu { AppContextMenu(app: app) }
    }

    private var subtitle: String {
        let s = store.app(app.id)
        if s.muted { return "Muted" }
        if !engine.isAudible(app) { return appStatusLine(app) }
        if let uid = s.outputUID { return "Always \(OutputDevices.shared.device(uid: uid)?.name ?? store.device(uid).name ?? "chosen device")" }
        return "System Output"
    }
}

/// The right column: one device's volume, connect behavior and EQ.
struct DeviceInspector: View {
    let uid: String
    @State private var devices = OutputDevices.shared

    var body: some View {
        let device = devices.device(uid: uid)
        Form {
            Section {
                HStack(spacing: 12) {
                    DeviceBadge(symbol: device?.symbol ?? "speaker.wave.2", active: uid == devices.defaultUID, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device?.name ?? SettingsStore.shared.device(uid).name ?? "Device").font(.headline)
                        Text(details(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device != nil, uid != devices.defaultUID {
                        Button("Use as Output") { devices.makeDefault(uid) }.controlSize(.small)
                    } else if device == nil, SettingsStore.shared.device(uid).airPlay {
                        AirPlayConnectButton(name: SettingsStore.shared.device(uid).name)
                    }
                }
            }
            Section {
                DeviceVolumeSlider(uid: uid, thick: true)
                DeviceMemoryToggles(uid: uid)
            }
            Section("Several Outputs") { OutputGroupControls() }
            Section { MultiRoomControls() }
            Section { DeviceEQPanel(uid: uid, graphHeight: 170) }
        }
        .formStyle(.grouped)
    }

    private func details(_ device: OutputDevice?) -> String {
        guard let device else { return "Not connected" }
        let rate = CA.nominalSampleRate(device.objectID)
        let state = device.uid == devices.defaultUID ? "In use" : "Available"
        return "\(device.transportName) · \(Int(rate / 1000)) kHz · \(state)"
    }
}
