import AudioLensKit
import CoreAudio
import SwiftUI

/// "Play on several outputs": a switch, a checkbox per connected output, and sync fine-tuning.
struct OutputGroupControls: View {
    var compact = false
    @State private var store = SettingsStore.shared
    @State private var devices = OutputDevices.shared
    @State private var engine = AudioEngine.shared

    var body: some View {
        let enabled = Binding(get: { store.output.enabled }, set: { store.output.enabled = $0 })
        Toggle("Play on several outputs at once", isOn: enabled)
            .controlSize(compact ? .small : .regular)
        if store.output.enabled {
            ForEach(devices.devices) { device in
                Toggle(isOn: Binding(get: { store.isInGroup(device.uid) }, set: { store.setInGroup(device.uid, $0) })) {
                    HStack(spacing: 8) {
                        Image(systemName: device.symbol).frame(width: 18)
                        Text(device.name).lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
            }
            if let group = engine.activeGroup {
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { store.output.syncOffsetMs }, set: { store.output.syncOffsetMs = ($0 / 10).rounded() * 10 }),
                               in: OutputGroup.offsetRange)
                            .frame(minWidth: 100)
                        Text(String(format: "%+.0f ms", store.output.syncOffsetMs))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        Button("Reset") { store.output.syncOffsetMs = 0 }
                            .controlSize(.small).disabled(store.output.syncOffsetMs == 0)
                    }
                } label: {
                    Text("Sync")
                    Text("If \(fastName(group)) sounds ahead, move right; if it lags, move left.")
                }
                Text("Playing on \(group.map(\.name).joined(separator: " + ")). Every app goes through AudioLens while this is on.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Check at least two connected outputs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("For several HomePods, check them together in Control Center › Sound; they join as one AirPlay output.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The output that plays sooner, which the slider holds back.
    private func fastName(_ group: [OutputDevice]) -> String {
        group.first { $0.transport != kAudioDeviceTransportTypeAirPlay }?.name ?? group[0].name
    }
}
