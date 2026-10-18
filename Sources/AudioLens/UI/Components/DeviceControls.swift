import AudioLensKit
import SwiftUI

/// A device's volume slider: the live level when connected, the remembered level otherwise.
struct DeviceVolumeSlider: View {
    let uid: String
    var thick = false
    @State private var devices = OutputDevices.shared

    var body: some View {
        let binding = Binding<Double>(
            get: { uid == devices.defaultUID ? (devices.volume ?? 0) : (devices.volume(forUID: uid) ?? 0.5) },
            set: { devices.setVolume($0, forUID: uid) })
        HStack(spacing: 8) {
            Button {
                if uid == devices.defaultUID { devices.setSystemMuted(!devices.muted) }
            } label: {
                Image(systemName: uid == devices.defaultUID && devices.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(uid == devices.defaultUID && devices.muted ? Color.red : Color.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(uid != devices.defaultUID)
            LevelSlider(value: binding, range: 0...1, thick: thick, label: "\(devices.device(uid: uid)?.name ?? "Device") volume")
                .disabled(devices.device(uid: uid) != nil && OutputDevices.volume(of: devices.device(uid: uid)!.objectID) == nil)
            Text(percentText(binding.wrappedValue)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// Bindings onto a device's restore and lock choices.
@MainActor
struct DeviceBindings {
    let uid: String
    private var store: SettingsStore { .shared }

    var restore: Binding<Bool> {
        Binding(get: { store.device(uid).restoreVolume }, set: { v in store.updateDevice(uid) { $0.restoreVolume = v } })
    }

    var lock: Binding<Bool> {
        Binding(get: { store.device(uid).lockVolume }, set: { v in
            store.updateDevice(uid) { $0.lockVolume = v }
            // Locks at the level it has now.
            if v, let current = OutputDevices.shared.volume(forUID: uid) { SettingsStore.shared.saveVolume(current, for: uid) }
        })
    }
}

/// Restore and lock switches.
struct DeviceMemoryToggles: View {
    let uid: String

    var body: some View {
        Toggle("Restore this volume when connected", isOn: DeviceBindings(uid: uid).restore)
        Toggle("Lock volume at this level", isOn: DeviceBindings(uid: uid).lock)
    }
}

/// A row for one device: symbol, name, state, remembered volume.
struct DeviceSummary: View {
    let uid: String
    var compact = false
    @State private var devices = OutputDevices.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        let device = devices.device(uid: uid)
        let isDefault = uid == devices.defaultUID
        HStack(spacing: 10) {
            DeviceBadge(symbol: device?.symbol ?? OutputDevice.symbol(name: store.device(uid).name ?? "", transport: 0),
                        active: isDefault, size: compact ? 24 : 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(device?.name ?? store.device(uid).name ?? "Device").lineLimit(1)
                Text(statusLine(device: device, isDefault: isDefault)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .opacity(device == nil ? 0.6 : 1)
    }

    private func statusLine(device: OutputDevice?, isDefault: Bool) -> String {
        let level = devices.volume(forUID: uid).map { percentText($0) }
        if device == nil { return "Not connected" + (level.map { " · last \($0)" } ?? "") }
        if isDefault { return "In use" + (level.map { " · \($0)" } ?? "") }
        return "Available" + (level.map { " · \($0)" } ?? "")
    }
}

/// Every device worth showing: the connected ones, then remembered ones that aren't connected.
@MainActor
func knownDeviceUIDs() -> [String] {
    let connected = OutputDevices.shared.devices.map(\.uid)
    let remembered = SettingsStore.shared.devices.keys.filter { !connected.contains($0) }
        .sorted { (SettingsStore.shared.device($0).name ?? $0) < (SettingsStore.shared.device($1).name ?? $1) }
    return connected + remembered
}

/// Picks the system output.
struct OutputMenu: View {
    @State private var devices = OutputDevices.shared

    var body: some View {
        Menu {
            ForEach(devices.devices) { device in
                Button {
                    devices.makeDefault(device.uid)
                } label: {
                    Label(device.name, systemImage: device.uid == devices.defaultUID ? "checkmark" : device.symbol)
                }
            }
        } label: {
            Text("Change Output")
        }
        .fixedSize()
        .help("Choose the system output device")
    }
}
