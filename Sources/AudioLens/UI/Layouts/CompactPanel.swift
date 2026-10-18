import AudioLensKit
import SwiftUI

/// Option 5: one narrow panel. It's the menu bar drop-down, and what any layout shrinks to.
struct CompactPanel: View {
    enum Mode { case menuBar, window }
    enum Tab: String, CaseIterable { case apps = "Apps", devices = "Devices", eq = "EQ" }

    static let width: CGFloat = 340

    let mode: Mode
    @State private var tab = Tab.apps
    @State private var engine = AudioEngine.shared
    @State private var devices = OutputDevices.shared
    @State private var store = SettingsStore.shared
    @State private var expanded: String?
    @State private var showAllRecent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .apps: appsTab
                case .devices: devicesTab
                case .eq: eqTab
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            footer
        }
        .padding(12)
        .frame(width: Self.width)
        .frame(minHeight: mode == .menuBar ? 300 : 360, maxHeight: .infinity)
    }

    // MARK: - Parts

    private var header: some View {
        VStack(spacing: 8) {
            Menu {
                ForEach(devices.devices) { d in
                    Button { devices.makeDefault(d.uid) } label: {
                        Label(d.name, systemImage: d.uid == devices.defaultUID ? "checkmark" : d.symbol)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    DeviceBadge(symbol: devices.defaultDevice?.symbol ?? "speaker.slash", active: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(devices.defaultDevice?.name ?? "No output").fontWeight(.semibold).lineLimit(1)
                        Text(outputSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .help("Choose the output device")
            .overlay(alignment: .trailing) { AirPlayIcon().padding(.trailing, 30) }
            if let uid = devices.defaultUID { DeviceVolumeSlider(uid: uid, thick: true).padding(.horizontal, 2) }
        }
    }

    private var outputSubtitle: String {
        guard let uid = devices.defaultUID else { return "" }
        if let group = engine.activeGroup { return "+ " + group.filter { $0.uid != uid }.map(\.name).joined(separator: ", ") }
        let s = store.device(uid)
        var parts: [String] = []
        if s.restoreVolume || s.lockVolume, let v = store.savedVolume(for: uid) { parts.append("Restores at \(percentText(v))") }
        if s.correction?.enabled == true { parts.append("Correction on") } else if s.eqEnabled { parts.append("EQ on") }
        return parts.isEmpty ? "System output" : parts.joined(separator: " · ")
    }

    private var appsTab: some View {
        let apps = engine.visibleApps
        let recent = engine.recentApps
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                PermissionBanner(compact: true)
                if apps.isEmpty && recent.isEmpty {
                    EmptyAppsView().frame(height: 220)
                }
                ForEach(apps) { app in
                    PanelAppRow(app: app, expanded: expanded == app.id) {
                        withAnimation(.snappy(duration: 0.18)) { expanded = expanded == app.id ? nil : app.id }
                    }
                }
                if !recent.isEmpty {
                    HStack {
                        Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if recent.count > 3 {
                            Button(showAllRecent ? "Show Fewer" : "Show All (\(recent.count))") {
                                withAnimation(.snappy(duration: 0.18)) { showAllRecent.toggle() }
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                    ForEach(showAllRecent ? recent : Array(recent.prefix(3))) { app in
                        PanelAppRow(app: app, expanded: expanded == app.id, recent: true) {
                            withAnimation(.snappy(duration: 0.18)) { expanded = expanded == app.id ? nil : app.id }
                        }
                    }
                }
            }
        }
    }

    private var devicesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) { OutputGroupControls(compact: true) }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                AirPlayCompactSection()
                ForEach(knownDeviceUIDs(), id: \.self) { uid in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            DeviceSummary(uid: uid, compact: true)
                            if devices.device(uid: uid) != nil, uid != devices.defaultUID {
                                Button("Use") { devices.makeDefault(uid) }.controlSize(.small)
                            } else if devices.device(uid: uid) == nil, store.device(uid).airPlay {
                                AirPlayConnectButton(name: store.device(uid).name)
                            }
                        }
                        DeviceVolumeSlider(uid: uid)
                        Toggle("Restore when connected", isOn: DeviceBindings(uid: uid).restore).controlSize(.small)
                        Toggle("Lock volume", isOn: DeviceBindings(uid: uid).lock).controlSize(.small)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var eqTab: some View {
        ScrollView {
            if let uid = devices.defaultUID {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("EQ for \(devices.defaultDevice?.name ?? "output")").font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Toggle("", isOn: DeviceEQBindings(uid: uid).enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    HStack {
                        PresetMenu(uid: uid).controlSize(.small)
                        Spacer()
                        Button("Flat") { DeviceEQBindings(uid: uid).apply(.flat) }.controlSize(.small)
                    }
                    EQGraph(uid: uid, height: 90)
                    EQBandFaders(uid: uid).frame(height: 150)
                    Divider()
                    CorrectionControls(uid: uid)
                    PermissionBanner(compact: true)
                }
            } else {
                Text("No output device").foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            SyncStatusLabel()
            Spacer()
            switch mode {
            case .menuBar:
                Button("Open Window") { MainWindow.shared.show(compact: false) }.controlSize(.small)
            case .window:
                Button {
                    MainWindow.shared.setCompact(false)
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .controlSize(.small)
                .help("Back to the full window (⇧⌘C)")
            }
            Button {
                SettingsWindow.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }
}

/// An app in the compact panel; clicking its name shows its output, pin, ignore and mute.
struct PanelAppRow: View {
    let app: AudioApp
    let expanded: Bool
    var recent = false
    let toggle: () -> Void
    @State private var engine = AudioEngine.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        let s = store.app(app.id)
        let bind = AppBindings(app: app)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    AppIcon(app: app, size: 22)
                    Text(app.name).lineLimit(1)
                    if let uid = s.outputUID, let d = OutputDevices.shared.device(uid: uid) {
                        Text(d.name).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule()).foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if s.pinned && !engine.isAudible(app) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                    if recent {
                        Text(appStatusLine(app)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        PlayingIndicator(playing: engine.isAudible(app) && !s.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                AppVolumeSlider(app: app)
                VolumeText(app: app)
            }
            if expanded {
                HStack(spacing: 6) {
                    RoutePicker(app: app, compact: true)
                    Button(s.pinned ? "Unpin" : "Pin") { bind.togglePin() }
                    Button("Ignore") { bind.ignore() }
                    Button(s.muted ? "Unmute" : "Mute") { bind.muted.wrappedValue.toggle() }
                    if recent { Button("Remove") { SettingsStore.shared.forgetRecent(app.id) } }
                }
                .controlSize(.mini)
            }
            FailureNote(app: app)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(expanded ? Color(nsColor: .controlBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(expanded ? 0.1 : 0)))
        .opacity(engine.isAudible(app) ? 1 : 0.65)
        .contextMenu { AppContextMenu(app: app) }
    }
}

/// AirPlay speakers on the network, at the top of the compact Devices tab.
private struct AirPlayCompactSection: View {
    @State private var browser = AirPlayBrowser.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MultiRoomControls(compact: true)
            if !SettingsStore.shared.multiRoom.enabled {
                Divider()
                Text("One AirPlay speaker for the Mac's sound").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                AirPlaySpeakerRows(compact: true)
            }
            if !SettingsStore.shared.multiRoom.enabled, browser.unconnected.isEmpty {
                Text(browser.denied ? "Allow Local Network access for AudioLens to see AirPlay speakers." : "Looking for AirPlay speakers…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
