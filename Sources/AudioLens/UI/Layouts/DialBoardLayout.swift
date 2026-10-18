import AudioLensKit
import SwiftUI

/// Option 3: devices across the top with their remembered volumes, apps below as dials.
struct DialBoardLayout: View {
    @State private var engine = AudioEngine.shared
    @State private var devices = OutputDevices.shared
    @State private var store = SettingsStore.shared
    @State private var editingEQ = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(knownDeviceUIDs(), id: \.self) { uid in DeviceChip(uid: uid) }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .background(.bar)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    PermissionBanner()
                    let apps = engine.visibleApps
                    if apps.isEmpty {
                        EmptyAppsView().frame(height: 300)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)], spacing: 14) {
                            ForEach(apps) { DialTile(app: $0) }
                            PinHintTile()
                        }
                    }
                }
                .padding(18)
            }
            Divider()
            eqBar
        }
    }

    private var eqBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.vertical.3").foregroundStyle(.secondary)
            if let device = devices.defaultDevice {
                let s = store.device(device.uid)
                Text("Equalizer for \(device.name)").fontWeight(.semibold).lineLimit(1)
                Text(s.correction?.enabled == true ? "Correction: \(s.correction!.name)" : (s.eqEnabled ? (EQPreset.matching(s.eqGains)?.name ?? "Custom") : "Off"))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                EQThumbnail(gains: s.eqGains, enabled: s.eqEnabled)
                Button("Edit EQ") { editingEQ = true }
                    .popover(isPresented: $editingEQ, arrowEdge: .top) {
                        DeviceEQPanel(uid: device.uid).padding(16).frame(width: 420)
                    }
            } else {
                Text("No output device").foregroundStyle(.secondary)
                Spacer()
            }
            SyncStatusLabel()
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.bar)
    }
}

/// A device card: its remembered volume, whether it's connected; click to make it the output.
struct DeviceChip: View {
    let uid: String
    @State private var devices = OutputDevices.shared

    var body: some View {
        let isDefault = uid == devices.defaultUID
        Button {
            if devices.device(uid: uid) != nil { devices.makeDefault(uid) }
        } label: {
            DeviceSummary(uid: uid, compact: true)
                .frame(minWidth: 170, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isDefault ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isDefault ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .help(devices.device(uid: uid) == nil ? "Not connected" : (isDefault ? "The system output" : "Make this the system output"))
    }
}

/// One app as a tile with a dial.
struct DialTile: View {
    let app: AudioApp
    @State private var engine = AudioEngine.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        let s = store.app(app.id)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                AppIcon(app: app, size: 22)
                Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if engine.isAudible(app) {
                    PlayingIndicator(playing: !s.muted)
                } else if s.pinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
                MuteButton(app: app)
            }
            VolumeKnob(value: AppBindings(app: app).volume, range: 0...store.maxVolume, label: "\(app.name) volume", size: 104)
                .opacity(s.muted ? 0.45 : 1)
            RoutePicker(app: app, compact: true)
            FailureNote(app: app)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
        .opacity(engine.isAudible(app) ? 1 : 0.75)
        .contextMenu { AppContextMenu(app: app) }
    }
}

struct PinHintTile: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus").font(.title2).foregroundStyle(.tertiary)
            Text("Right-click an app and pin it to keep it here when it's silent")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
