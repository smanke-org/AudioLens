import AudioLensKit
import SwiftUI

/// Bindings onto one device's EQ settings.
@MainActor
struct DeviceEQBindings {
    let uid: String
    private var store: SettingsStore { .shared }

    var enabled: Binding<Bool> {
        Binding(get: { store.device(uid).eqEnabled }, set: { v in
            store.updateDevice(uid) { $0.eqEnabled = v; if $0.name == nil { $0.name = OutputDevices.shared.device(uid: uid)?.name } }
        })
    }

    func gain(_ band: Int) -> Binding<Double> {
        Binding(get: { store.device(uid).eqGains[band] }, set: { v in
            store.updateDevice(uid) { s in
                s.eqGains[band] = min(max(v, EQBands.range.lowerBound), EQBands.range.upperBound)
                s.eqEnabled = true
            }
        })
    }

    func apply(_ preset: EQPreset) {
        store.updateDevice(uid) { $0.eqGains = preset.gains; $0.eqEnabled = true }
    }

    var correctionEnabled: Binding<Bool> {
        Binding(get: { store.device(uid).correction?.enabled ?? false }, set: { v in
            store.updateDevice(uid) { $0.correction?.enabled = v }
        })
    }
}

/// Preset menu: the built-in curves, with a check beside the one in use.
struct PresetMenu: View {
    let uid: String
    @State private var store = SettingsStore.shared

    var body: some View {
        let current = EQPreset.matching(store.device(uid).eqGains)
        Menu(current?.name ?? "Custom") {
            ForEach(EQPreset.all) { preset in
                Button {
                    DeviceEQBindings(uid: uid).apply(preset)
                } label: {
                    if preset == current { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                }
            }
        }
        .fixedSize()
        .help("EQ presets")
    }
}

/// The EQ as a curve with ten draggable points, plus the headphone correction as a dashed line.
struct EQGraph: View {
    let uid: String
    var height: CGFloat = 170
    @State private var store = SettingsStore.shared
    @State private var dragging: Int?

    private let sampleRate = 48000.0
    private let minF = 20.0, maxF = 20000.0

    var body: some View {
        let settings = store.device(uid)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let left: CGFloat = 26, right: CGFloat = 8, top: CGFloat = 8, bottom: CGFloat = 18
            let plotW = w - left - right, plotH = h - top - bottom
            let x = { (f: Double) -> CGFloat in left + CGFloat(log10(f / minF) / log10(maxF / minF)) * plotW }
            let y = { (g: Double) -> CGFloat in top + CGFloat((12 - min(max(g, -12), 12)) / 24) * plotH }

            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    // Grid and labels.
                    for g in stride(from: -12.0, through: 12, by: 6) {
                        var p = Path(); p.move(to: CGPoint(x: left, y: y(g))); p.addLine(to: CGPoint(x: w - right, y: y(g)))
                        ctx.stroke(p, with: .color(.primary.opacity(g == 0 ? 0.22 : 0.08)), lineWidth: 1)
                        ctx.draw(Text(g > 0 ? "+\(Int(g))" : "\(Int(g))").font(.system(size: 9)).foregroundStyle(.tertiary),
                                 at: CGPoint(x: left - 4, y: y(g)), anchor: .trailing)
                    }
                    for (i, f) in EQBands.frequencies.enumerated() {
                        ctx.draw(Text(EQBands.labels[i]).font(.system(size: 9)).foregroundStyle(.tertiary),
                                 at: CGPoint(x: x(f), y: h - 7), anchor: .center)
                    }
                    let freqs = EQChain.logFrequencies(count: 140)
                    // Headphone correction, dashed.
                    if let correction = settings.correction, correction.enabled {
                        var only = DeviceSettings(); only.correction = correction
                        let sections = correction.filters.map { Biquad.filter($0, sampleRate: sampleRate) }
                        let response = EQChain(sections: sections, preamp: 1).response(at: freqs, sampleRate: sampleRate)
                        var p = Path()
                        for (i, f) in freqs.enumerated() {
                            let pt = CGPoint(x: x(f), y: y(response[i]))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        ctx.stroke(p, with: .color(.purple.opacity(0.85)), style: StrokeStyle(lineWidth: 1.3, dash: [3, 3]))
                    }
                    // The EQ bands' own curve (no preamp), so the points sit on it.
                    let sections = zip(EQBands.frequencies, settings.eqGains).map {
                        Biquad.peaking(frequency: $0, gain: $1, q: EQBands.q, sampleRate: sampleRate)
                    }
                    let response = EQChain(sections: sections, preamp: 1).response(at: freqs, sampleRate: sampleRate)
                    var curve = Path()
                    for (i, f) in freqs.enumerated() {
                        let pt = CGPoint(x: x(f), y: y(response[i]))
                        if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                    }
                    var area = curve
                    area.addLine(to: CGPoint(x: x(freqs.last!), y: y(0)))
                    area.addLine(to: CGPoint(x: x(freqs.first!), y: y(0)))
                    area.closeSubpath()
                    let tint: Color = settings.eqEnabled ? .accentColor : .secondary
                    ctx.fill(area, with: .color(tint.opacity(0.12)))
                    ctx.stroke(curve, with: .color(tint), lineWidth: 2)
                }
                ForEach(0..<EQBands.count, id: \.self) { band in
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(settings.eqEnabled ? Color.accentColor : Color.secondary, lineWidth: 2))
                        .frame(width: dragging == band ? 13 : 11, height: dragging == band ? 13 : 11)
                        .position(x: x(EQBands.frequencies[band]), y: y(settings.eqGains[band]))
                        .help("\(EQBands.labels[band]) Hz: \(String(format: "%+.1f", settings.eqGains[band])) dB")
                        .accessibilityElement()
                        .accessibilityLabel("\(EQBands.labels[band]) hertz")
                        .accessibilityValue(String(format: "%+.1f decibels", settings.eqGains[band]))
                        .accessibilityAdjustableAction { direction in
                            let b = DeviceEQBindings(uid: uid).gain(band)
                            b.wrappedValue += direction == .increment ? 0.5 : -0.5
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let band = dragging ?? nearestBand(to: g.startLocation.x, x: x)
                dragging = band
                let gain = 12 - Double((g.location.y - top) / plotH) * 24
                DeviceEQBindings(uid: uid).gain(band).wrappedValue = (gain * 2).rounded() / 2
            }.onEnded { _ in dragging = nil })
        }
        .frame(height: height)
    }

    private func nearestBand(to px: CGFloat, x: (Double) -> CGFloat) -> Int {
        EQBands.frequencies.indices.min { abs(x(EQBands.frequencies[$0]) - px) < abs(x(EQBands.frequencies[$1]) - px) } ?? 0
    }
}

/// Ten small faders, one per band, for the compact panel.
struct EQBandFaders: View {
    let uid: String
    @State private var store = SettingsStore.shared

    var body: some View {
        let gains = store.device(uid).eqGains
        HStack(spacing: 2) {
            ForEach(0..<EQBands.count, id: \.self) { band in
                VStack(spacing: 4) {
                    Text(String(format: "%+.0f", gains[band])).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                    VerticalFader(value: DeviceEQBindings(uid: uid).gain(band), range: EQBands.range, reference: 0, small: true,
                                  label: "\(EQBands.labels[band]) hertz", onScroll: 0.25)
                    Text(EQBands.labels[band]).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The headphone correction controls for a device: what's applied, and how to change it.
struct CorrectionControls: View {
    let uid: String
    @State private var store = SettingsStore.shared
    @State private var choosing = false

    var body: some View {
        let correction = store.device(uid).correction
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headphone correction")
                    Text(correction.map { "\($0.name)\($0.source.map { " · \($0)" } ?? "")" } ?? "Off. Choose your headphone model to even out its sound.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if correction != nil { Toggle("", isOn: DeviceEQBindings(uid: uid).correctionEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small) }
            }
            ViewThatFits(in: .horizontal) {
                HStack { correctionButtons(correction) }
                VStack(alignment: .leading, spacing: 6) { correctionButtons(correction) }
            }
            .controlSize(.small)
        }
        .sheet(isPresented: $choosing) { HeadphonePicker(uid: uid, isPresented: $choosing) }
    }

    @ViewBuilder private func correctionButtons(_ correction: HeadphoneCorrection?) -> some View {
        Button(correction == nil ? "Choose Headphones…" : "Change…") { choosing = true }
        Button("Import File…") { CorrectionCatalog.shared.importFile(for: uid) }
        if correction != nil { Button("Remove") { store.updateDevice(uid) { $0.correction = nil } } }
    }
}

/// Searches the AutoEQ list of measured headphones.
struct HeadphonePicker: View {
    let uid: String
    @Binding var isPresented: Bool
    @State private var catalog = CorrectionCatalog.shared
    @State private var query = ""
    @State private var applying: AutoEQ.Entry?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Your Headphones").font(.headline)
            Text("Correction curves come from the AutoEQ project, measured by independent reviewers. Pick the model you're wearing on \(OutputDevices.shared.device(uid: uid)?.name ?? "this device").")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search, for example “AirPods Pro”", text: $query)
                .textFieldStyle(.roundedBorder)
            Group {
                if catalog.loading {
                    ProgressView("Downloading the headphone list…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = catalog.lastError {
                    VStack(spacing: 8) {
                        Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { catalog.retry() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let hits = AutoEQ.search(catalog.entries, for: query)
                    List(hits) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.name)
                                Text("Measured by \(entry.source)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if applying == entry { ProgressView().controlSize(.small) }
                            Button("Use") { choose(entry) }.disabled(applying != nil)
                        }
                    }
                    .overlay {
                        if hits.isEmpty {
                            Text(query.isEmpty ? "Type a headphone model to search \(catalog.entries.count.formatted()) measurements." : "No matches.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 260)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460, height: 460)
        .onAppear { catalog.load() }
    }

    private func choose(_ entry: AutoEQ.Entry) {
        applying = entry
        error = nil
        Task {
            defer { applying = nil }
            do {
                try await CorrectionCatalog.shared.apply(entry, to: uid)
                isPresented = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The full EQ panel for a device: switch, presets, curve and correction.
struct DeviceEQPanel: View {
    let uid: String
    var graphHeight: CGFloat = 170
    @State private var store = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Equalizer").font(.headline)
                Spacer()
                PresetMenu(uid: uid)
                Toggle("", isOn: DeviceEQBindings(uid: uid).enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Turn the EQ on or off for this device")
            }
            EQGraph(uid: uid, height: graphHeight)
                .opacity(store.device(uid).eqEnabled ? 1 : 0.6)
            HStack(spacing: 14) {
                Label("Your EQ", systemImage: "line.diagonal").foregroundStyle(Color.accentColor)
                if store.device(uid).correction?.enabled == true {
                    Label("Headphone correction", systemImage: "line.diagonal").foregroundStyle(.purple)
                }
                Spacer()
                Button("Flat") { DeviceEQBindings(uid: uid).apply(.flat) }.controlSize(.small)
            }
            .font(.caption)
            Divider()
            CorrectionControls(uid: uid)
        }
    }
}
