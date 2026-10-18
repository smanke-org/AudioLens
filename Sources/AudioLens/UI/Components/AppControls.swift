import AppKit
import AudioLensKit
import SwiftUI

/// Bindings onto one app's stored settings.
@MainActor
struct AppBindings {
    let app: AudioApp
    private var store: SettingsStore { .shared }

    var settings: AppAudioSettings { store.app(app.id) }

    var volume: Binding<Double> {
        Binding(get: { store.app(app.id).volume }, set: { v in
            store.updateApp(app.id) { s in
                s.volume = v
                if v > 0 { s.muted = false }
                if s.name == nil { s.name = app.name }
            }
        })
    }

    var muted: Binding<Bool> {
        Binding(get: { store.app(app.id).muted }, set: { v in store.updateApp(app.id) { $0.muted = v; if $0.name == nil { $0.name = app.name } } })
    }

    func togglePin() { store.updateApp(app.id) { $0.pinned.toggle(); $0.name = app.name } }
    func ignore() { store.updateApp(app.id) { $0.ignored = true; $0.pinned = false; $0.name = app.name } }
    func route(to uid: String?) { store.updateApp(app.id) { $0.outputUID = uid; $0.name = app.name } }
    func reset() { store.updateApp(app.id) { $0.volume = 1; $0.muted = false; $0.outputUID = nil } }
}

/// Mute button: a speaker, crossed out (and red) while muted.
struct MuteButton: View {
    let app: AudioApp
    @State private var store = SettingsStore.shared

    var body: some View {
        let muted = store.app(app.id).muted
        Button {
            AppBindings(app: app).muted.wrappedValue = !muted
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 18)
                .foregroundStyle(muted ? Color.red : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
    }
}

/// The value beside a slider: "80%", orange past 100%, "Muted" while muted.
struct VolumeText: View {
    let app: AudioApp
    @State private var store = SettingsStore.shared

    var body: some View {
        let s = store.app(app.id)
        Text(s.muted ? "Muted" : percentText(s.volume))
            .font(.callout).monospacedDigit()
            .foregroundStyle(s.muted ? Color.red : LevelStyle.text(s.volume))
            .frame(width: 46, alignment: .trailing)
    }
}

/// An app's slider, bound to its settings.
struct AppVolumeSlider: View {
    let app: AudioApp
    var thick = false
    @State private var store = SettingsStore.shared

    var body: some View {
        LevelSlider(value: AppBindings(app: app).volume, range: 0...store.maxVolume, thick: thick, label: "\(app.name) volume")
            .opacity(store.app(app.id).muted ? 0.45 : 1)
    }
}

/// "System Output" or a device name, as a menu that changes where the app plays.
struct RoutePicker: View {
    let app: AudioApp
    var compact = false
    @State private var store = SettingsStore.shared
    @State private var devices = OutputDevices.shared

    var body: some View {
        let chosen = store.app(app.id).outputUID
        let connected = devices.device(uid: chosen)
        Menu {
            Button {
                AppBindings(app: app).route(to: nil)
            } label: {
                Label("System Output (\(devices.defaultDevice?.name ?? "none"))", systemImage: chosen == nil ? "checkmark" : "speaker.wave.2")
            }
            Divider()
            ForEach(devices.devices) { device in
                Button {
                    AppBindings(app: app).route(to: device.uid)
                } label: {
                    Label(device.name, systemImage: chosen == device.uid ? "checkmark" : device.symbol)
                }
            }
            if let chosen, connected == nil {
                Divider()
                Text("\(store.device(chosen).name ?? "The chosen device") isn't connected, so \(app.name) plays to the system output.")
            }
        } label: {
            HStack(spacing: 4) {
                if chosen != nil { Image(systemName: connected?.symbol ?? "exclamationmark.triangle") }
                Text(chosen == nil ? "System Output" : (connected?.name ?? store.device(chosen!).name ?? "Not connected"))
                    .lineLimit(1)
            }
            .font(compact ? .caption : .callout)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(compact ? .mini : .small)
        .fixedSize()
        .help("Where \(app.name) plays")
    }
}

/// Pin, ignore, output and reset, for an app's right-click menu.
struct AppContextMenu: View {
    let app: AudioApp
    @State private var store = SettingsStore.shared
    @State private var devices = OutputDevices.shared

    var body: some View {
        let s = store.app(app.id)
        let bind = AppBindings(app: app)
        Button(s.muted ? "Unmute" : "Mute") { bind.muted.wrappedValue = !s.muted }
        Button(s.pinned ? "Unpin" : "Pin (Keep Listed When Silent)") { bind.togglePin() }
        Menu("Play To") {
            Button("System Output") { bind.route(to: nil) }
            Divider()
            ForEach(devices.devices) { d in Button(d.name) { bind.route(to: d.uid) } }
        }
        Divider()
        Button("Back to 100%, System Output") { bind.reset() }
        Button("Ignore \(app.name)") { bind.ignore() }
    }
}

/// Shown when an app needs a tap but macOS hasn't allowed audio capture yet, or refused it.
struct PermissionBanner: View {
    @State private var permission = CapturePermission.shared
    @State private var engine = AudioEngine.shared
    var compact = false

    var body: some View {
        if !permission.isAuthorized && (engine.waitingForPermission || permission.status == .denied) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("AudioLens needs permission to change app volumes").font(.callout.weight(.semibold))
                    if !compact {
                        Text("macOS asks once. Turn on AudioLens under System Audio Recording Only in Privacy & Security › Screen & System Audio Recording. Until then, every app plays normally.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if permission.status != .denied { Button("Allow…") { permission.request() } }
                        Button("Open Privacy & Security") { permission.openSettings() }
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Why an app couldn't be tapped, under its row.
struct FailureNote: View {
    let app: AudioApp
    @State private var engine = AudioEngine.shared

    var body: some View {
        if let failure = engine.failures[app.id] {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }
}

/// What an app is doing, for the line under its name.
@MainActor
func appStatusLine(_ app: AudioApp) -> String {
    let engine = AudioEngine.shared
    let s = SettingsStore.shared.app(app.id)
    if !app.isRunning { return "Not running" }
    if s.muted { return "Muted" }
    if engine.isAudible(app) {
        if let uid = s.outputUID, let d = OutputDevices.shared.device(uid: uid) { return "Playing · \(d.name)" }
        return "Playing"
    }
    return s.pinned ? "Pinned · silent" : "Silent"
}

/// An empty list, explained.
struct EmptyAppsView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("Nothing is playing").font(.headline)
            Text("Apps appear here when they start playing audio. Right-click one to pin it so it stays listed while silent.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
