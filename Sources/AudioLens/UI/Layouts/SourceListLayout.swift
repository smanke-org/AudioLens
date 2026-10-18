import AudioLensKit
import SwiftUI

/// Option 1, the default: a sidebar like System Settings, rows on the right, and the output
/// with its volume along the bottom.
struct SourceListLayout: View {
    enum Section: String, CaseIterable, Identifiable {
        case apps, devices, equalizer, pinned, ignored
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apps: "Apps"
            case .devices: "Output Devices"
            case .equalizer: "Equalizer"
            case .pinned: "Pinned Apps"
            case .ignored: "Ignored Apps"
            }
        }
        var symbol: String {
            switch self {
            case .apps: "square.grid.2x2"
            case .devices: "hifispeaker.2"
            case .equalizer: "slider.vertical.3"
            case .pinned: "pin"
            case .ignored: "eye.slash"
            }
        }
    }

    @State private var selection: Section = .apps
    @State private var engine = AudioEngine.shared
    @State private var devices = OutputDevices.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Section?>(get: { selection }, set: { if let s = $0 { selection = s } })) {
                ForEach([Section.apps, .devices, .equalizer]) { row($0) }
                SwiftUI.Section("Library") {
                    ForEach([Section.pinned, .ignored]) { row($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                SyncStatusLabel().frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } detail: {
            VStack(spacing: 0) {
                switch selection {
                case .apps: AppsList()
                case .devices: DevicesPane()
                case .equalizer: EqualizerPane()
                case .pinned: PinnedPane()
                case .ignored: IgnoredPane()
                }
                Divider()
                OutputBar()
            }
            .navigationTitle(selection.title)
        }
    }

    private func row(_ section: Section) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                if let count = count(section) { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        } icon: {
            Image(systemName: section.symbol)
        }
        .tag(section)
    }

    private func count(_ section: Section) -> Int? {
        switch section {
        case .apps: engine.visibleApps.count
        case .devices: devices.devices.count
        case .pinned: store.apps.values.filter(\.pinned).count
        case .ignored: store.apps.values.filter(\.ignored).count
        case .equalizer: nil
        }
    }
}
