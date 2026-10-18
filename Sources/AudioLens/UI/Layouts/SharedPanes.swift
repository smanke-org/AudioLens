import AudioLensKit
import SwiftUI

/// One app as a full-width row: icon, name and state, output, mute, slider, value.
struct AppRow: View {
    let app: AudioApp
    var showRoute = true
    var recent = false
    @State private var engine = AudioEngine.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                AppIcon(app: app)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).lineLimit(1)
                    Text(appStatusLine(app)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 170, alignment: .leading)
                PlayingIndicator(playing: engine.isAudible(app) && !store.app(app.id).muted)
                if showRoute { RoutePicker(app: app) }
                MuteButton(app: app)
                AppVolumeSlider(app: app)
                VolumeText(app: app)
                if recent { RemoveRecentButton(app: app) }
            }
            FailureNote(app: app).padding(.leading, 40)
        }
        .padding(.vertical, 4)
        .opacity(engine.isAudible(app) ? 1 : 0.7)
        .contextMenu { AppContextMenu(app: app) }
    }
}

/// Playing apps, then pinned silent ones, in grouped sections.
struct AppsList: View {
    var showRoute = true
    @State private var engine = AudioEngine.shared

    var body: some View {
        let apps = engine.visibleApps
        let playing = apps.filter(engine.isAudible)
        let silent = apps.filter { !engine.isAudible($0) }
        let recent = engine.recentApps
        if apps.isEmpty && recent.isEmpty {
            VStack(spacing: 0) {
                PermissionBanner().padding()
                EmptyAppsView()
            }
        } else {
            Form {
                PermissionBanner()
                if !playing.isEmpty {
                    Section("Playing Now") { ForEach(playing) { AppRow(app: $0, showRoute: showRoute) } }
                }
                if !silent.isEmpty {
                    Section("Pinned · Silent") { ForEach(silent) { AppRow(app: $0, showRoute: showRoute) } }
                }
                if !recent.isEmpty {
                    Section {
                        ForEach(recent) { AppRow(app: $0, showRoute: showRoute, recent: true) }
                    } header: {
                        Text("Recent")
                    } footer: {
                        Text("Apps that played before. Their volume and output apply the next time they play.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                } footer: {
                    Text("Apps appear when they start playing. Right-click one to pin it, ignore it, or choose where it plays.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Every known device: volume, restore and lock, and a way to make it the output.
struct DevicesPane: View {
    @State private var devices = OutputDevices.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section("Several Outputs") { OutputGroupControls() }
            ForEach(knownDeviceUIDs(), id: \.self) { uid in
                Section {
                    HStack {
                        DeviceSummary(uid: uid)
                        if devices.device(uid: uid) != nil, uid != devices.defaultUID {
                            Button("Use as Output") { devices.makeDefault(uid) }.controlSize(.small)
                        }
                        if devices.device(uid: uid) == nil {
                            if store.device(uid).airPlay { AirPlayConnectButton(name: store.device(uid).name) }
                            Button("Forget") { store.forgetDevice(uid) }.controlSize(.small)
                        }
                    }
                    DeviceVolumeSlider(uid: uid)
                    DeviceMemoryToggles(uid: uid)
                    if let device = devices.device(uid: uid) {
                        LabeledContent("Connection", value: device.transportName).font(.callout)
                    }
                    let s = store.device(uid)
                    LabeledContent("Equalizer", value: s.eqEnabled ? (EQPreset.matching(s.eqGains)?.name ?? "Custom") : "Off").font(.callout)
                }
            }
            let groups = AirPlayBrowser.shared.groupedForList
            ForEach(groups, id: \.kind) { group in
                Section {
                    ForEach(group.speakers) { AirPlaySpeakerRow(speaker: $0) }
                } header: {
                    Text("AirPlay · \(group.kind.title)")
                } footer: {
                    if group.kind == groups.last?.kind {
                        Text("Connect opens Sound settings, where one click makes the speaker your Mac's output; macOS doesn't let other apps connect AirPlay speakers themselves. Once connected, AudioLens remembers its volume and EQ.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
            } footer: {
                Text("AudioLens remembers each device's volume on this Mac and puts it back when the device becomes the output. Locking keeps it there even if something else changes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The EQ for one device, chosen from a menu (the system output to start with).
struct EqualizerPane: View {
    @State private var devices = OutputDevices.shared
    @State private var chosen: String?

    var body: some View {
        let uid = chosen ?? devices.defaultUID
        Form {
            Section {
                Picker("Device", selection: Binding(get: { uid ?? "" }, set: { chosen = $0 })) {
                    ForEach(knownDeviceUIDs(), id: \.self) { id in
                        Text(devices.device(uid: id)?.name ?? SettingsStore.shared.device(id).name ?? id).tag(id)
                    }
                }
            } footer: {
                Text("Each device keeps its own EQ and headphone correction, and it applies to every app playing to it, except ignored apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let uid {
                Section { DeviceEQPanel(uid: uid, graphHeight: 210) }
            }
            PermissionBanner()
        }
        .formStyle(.grouped)
    }
}

/// Pinned apps, running or not.
struct PinnedPane: View {
    @State private var store = SettingsStore.shared

    var body: some View {
        let pinned = store.apps.filter { $0.value.pinned }.map { id, s in
            AudioEngine.shared.running[id] ?? AudioApp(id: id, name: s.name ?? AudioEngine.name(forBundleID: id), bundleID: id)
        }.sorted { $0.name < $1.name }
        Form {
            if pinned.isEmpty {
                Text("No pinned apps. Right-click an app while it plays and choose Pin to keep it listed when it's silent.")
                    .foregroundStyle(.secondary)
            }
            ForEach(pinned) { app in
                HStack {
                    AppIcon(app: app, size: 22)
                    Text(app.name)
                    Spacer()
                    Text(percentText(store.app(app.id).volume)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Unpin") { AppBindings(app: app).togglePin() }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Ignored apps, which play exactly as they would without AudioLens.
struct IgnoredPane: View {
    @State private var engine = AudioEngine.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                if engine.ignoredApps.isEmpty {
                    Text("No ignored apps.").foregroundStyle(.secondary)
                }
                ForEach(engine.ignoredApps) { app in
                    HStack {
                        AppIcon(app: app, size: 22)
                        Text(app.name)
                        Spacer()
                        Button("Stop Ignoring") { store.updateApp(app.id) { $0.ignored = false } }.controlSize(.small)
                    }
                }
            } footer: {
                Text("AudioLens leaves ignored apps alone: no volume change, no EQ, and they aren't listed. Right-click a playing app to ignore it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Synced 2:41 PM" with an icon, for sidebars and footers.
struct SyncStatusLabel: View {
    @State private var sync = SettingsSync.shared

    var body: some View {
        if sync.isEnabled {
            Label(text, systemImage: sync.lastError == nil ? "icloud" : "exclamationmark.icloud")
                .font(.caption).foregroundStyle(sync.lastError == nil ? Color.secondary : Color.orange)
                .help(sync.lastError ?? "Settings sync with your other Macs through iCloud Drive")
        }
    }

    private var text: String {
        if sync.lastError != nil { return "Sync needs attention" }
        if sync.keyState != .ready { return "Sync needs your passphrase" }
        if let date = sync.lastSynced { return "Synced \(date.formatted(date: .omitted, time: .shortened))" }
        return "Syncing…"
    }
}

/// The current output and its volume, along the bottom of a window.
struct OutputBar: View {
    @State private var devices = OutputDevices.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        HStack(spacing: 12) {
            if let device = devices.defaultDevice {
                DeviceBadge(symbol: device.symbol, active: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).fontWeight(.semibold).lineLimit(1)
                    Text(subtitle(device.uid)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 240, alignment: .leading)
                OutputMenu().controlSize(.small)
                AirPlayIcon()
                Spacer()
                DeviceVolumeSlider(uid: device.uid).frame(maxWidth: 320)
            } else {
                Text("No output device").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func subtitle(_ uid: String) -> String {
        if let group = AudioEngine.shared.activeGroup { return "Also playing on " + group.filter { $0.uid != uid }.map(\.name).joined(separator: ", ") }
        let s = store.device(uid)
        var parts: [String] = []
        if s.lockVolume { parts.append("Volume locked") } else if s.restoreVolume { parts.append("Volume remembered") }
        if let c = s.correction, c.enabled { parts.append("Correction: \(c.name)") }
        if s.eqEnabled { parts.append("EQ: \(EQPreset.matching(s.eqGains)?.name ?? "Custom")") }
        return parts.isEmpty ? "System output" : parts.joined(separator: " · ")
    }
}
