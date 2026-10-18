import AudioLensKit
import SwiftUI

/// Option 2: each app is a channel strip with a fader and a meter; the output device is the
/// master strip on the right.
struct MixingDeskLayout: View {
    enum Tab: String, CaseIterable { case mixer = "Mixer", devices = "Devices", equalizer = "Equalizer" }
    @State private var tab = Tab.mixer
    @State private var engine = AudioEngine.shared
    @State private var devices = OutputDevices.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                SyncStatusLabel()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            switch tab {
            case .mixer: mixer
            case .devices: DevicesPane()
            case .equalizer: EqualizerPane()
            }
        }
    }

    private var mixer: some View {
        let apps = engine.visibleApps
        return VStack(spacing: 0) {
            PermissionBanner().padding(.horizontal, 16).padding(.top, 8)
            HStack(alignment: .top, spacing: 0) {
                if apps.isEmpty {
                    EmptyAppsView()
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(apps) { app in
                                ChannelStrip(app: app)
                                Divider()
                            }
                        }
                        .padding(.vertical, 14).padding(.leading, 8)
                    }
                }
                Divider()
                MasterStrip(onEQ: { tab = .equalizer })
            }
            .frame(maxHeight: .infinity)
        }
        .background(LinearGradient(colors: [Color.primary.opacity(0.02), Color.primary.opacity(0.05)], startPoint: .top, endPoint: .bottom))
    }
}

/// One app's strip: icon, name, output, fader with meter, value, mute and pin.
struct ChannelStrip: View {
    let app: AudioApp
    @State private var store = SettingsStore.shared
    @State private var engine = AudioEngine.shared

    var body: some View {
        let s = store.app(app.id)
        let bind = AppBindings(app: app)
        VStack(spacing: 8) {
            AppIcon(app: app, size: 40)
            Text(app.name).font(.callout.weight(.medium)).lineLimit(1).frame(width: 92)
            RoutePicker(app: app, compact: true).frame(maxWidth: 96)
            HStack(spacing: 8) {
                FaderScale(values: store.allowBoost ? [1.5, 1, 0.5, 0] : [1, 0.5, 0], top: store.maxVolume)
                VerticalFader(value: bind.volume, range: 0...store.maxVolume, reference: store.allowBoost ? 1 : nil,
                              label: "\(app.name) volume")
                    .frame(width: 30)
                    .opacity(s.muted ? 0.45 : 1)
                LevelMeter(appID: app.id, playing: engine.isAudible(app) && !s.muted)
            }
            .frame(height: 220)
            VolumeText(app: app).frame(width: 60, alignment: .center)
            HStack(spacing: 4) {
                StripButton(title: "M", on: s.muted, tint: .red, help: s.muted ? "Unmute" : "Mute") { bind.muted.wrappedValue.toggle() }
                StripButton(title: "P", on: s.pinned, tint: .accentColor, help: s.pinned ? "Unpin" : "Pin (keep listed when silent)") { bind.togglePin() }
            }
            FailureNote(app: app).frame(width: 96)
        }
        .frame(width: 108)
        .padding(.horizontal, 4)
        .opacity(engine.isAudible(app) ? 1 : 0.62)
        .contextMenu { AppContextMenu(app: app) }
    }
}

/// Percent marks beside a fader, each at its value's height.
struct FaderScale: View {
    let values: [Double]
    let top: Double

    var body: some View {
        GeometryReader { geo in
            ForEach(values, id: \.self) { v in
                Text("\(Int((v * 100).rounded()))")
                    .position(x: geo.size.width / 2, y: geo.size.height * (1 - v / top))
            }
        }
        .frame(width: 22)
        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
    }
}

struct StripButton: View {
    let title: String
    let on: Bool
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 20)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .background(on ? tint : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(on ? 0 : 0.15)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The output device's strip: its volume (remembered per device) and its EQ.
struct MasterStrip: View {
    let onEQ: () -> Void
    @State private var devices = OutputDevices.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        VStack(spacing: 8) {
            if let device = devices.defaultDevice {
                let volume = Binding<Double>(get: { devices.volume ?? 0 }, set: { devices.setSystemVolume($0) })
                DeviceBadge(symbol: device.symbol, active: true, size: 40)
                Text(device.name).font(.callout.weight(.medium)).lineLimit(1).frame(width: 130)
                OutputMenu().controlSize(.mini)
                HStack(spacing: 8) {
                    FaderScale(values: [1, 0.5, 0], top: 1)
                    VerticalFader(value: volume, range: 0...1, reference: nil, label: "\(device.name) volume").frame(width: 30)
                }
                .frame(height: 220)
                Text(percentText(devices.volume ?? 0)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                let s = store.device(device.uid)
                Button(action: onEQ) {
                    VStack(spacing: 3) {
                        EQThumbnail(gains: s.eqGains, enabled: s.eqEnabled)
                        Text(s.correction?.enabled == true ? "Headphone correction" : (s.eqEnabled ? (EQPreset.matching(s.eqGains)?.name ?? "Custom EQ") : "EQ off"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Edit the EQ for \(device.name)")
            } else {
                Text("No output").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
        .frame(width: 160)
        .background(Color.accentColor.opacity(0.05))
    }
}

/// A tiny drawing of the EQ curve.
struct EQThumbnail: View {
    let gains: [Double]
    let enabled: Bool

    var body: some View {
        Canvas { ctx, size in
            var zero = Path(); zero.move(to: CGPoint(x: 2, y: size.height / 2)); zero.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            ctx.stroke(zero, with: .color(.primary.opacity(0.12)), lineWidth: 1)
            var p = Path()
            for (i, g) in gains.enumerated() {
                let pt = CGPoint(x: 4 + CGFloat(i) * (size.width - 8) / CGFloat(max(gains.count - 1, 1)),
                                 y: size.height / 2 - CGFloat(g / 12) * (size.height / 2 - 3))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(enabled ? .accentColor : .secondary), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(width: 76, height: 26)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}
