import AppKit
import AudioLensKit
import SwiftUI

// MARK: - Icons

/// An app's icon, from the running app or its bundle, cached.
struct AppIcon: View {
    let app: AudioApp
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: IconCache.icon(for: app))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: AudioApp) -> NSImage {
        if let hit = cache[app.id] { return hit }
        var image: NSImage?
        if let pid = app.pid { image = NSRunningApplication(processIdentifier: pid)?.icon }
        if image == nil, let id = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let result = image ?? NSWorkspace.shared.icon(for: .application)
        cache[app.id] = result
        return result
    }
}

/// A device's symbol in a rounded tile, filled in when it's the one in use.
struct DeviceBadge: View {
    let symbol: String
    var active = false
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? Color.accentColor : Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Volume colors

enum LevelStyle {
    static let boost = Color.orange
    static func fill(for value: Double) -> Color { value > 1.0001 ? boost : .accentColor }
    static func text(_ value: Double) -> Color { value > 1.0001 ? .orange : .secondary }
}

// MARK: - Sliders

/// A horizontal level slider. Past 100% the fill turns orange, and a tick marks 100% when the
/// range allows boost.
struct LevelSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...AppAudioSettings.maxBoost
    var thick = false
    var label: String

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = width * fraction
            let trackHeight: CGFloat = thick ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: trackHeight)
                Capsule().fill(LevelStyle.fill(for: value)).frame(width: max(x, trackHeight), height: trackHeight)
                if range.upperBound > 1, range.contains(1) {
                    let unity = width * (1 - range.lowerBound) / (range.upperBound - range.lowerBound)
                    Rectangle().fill(Color.secondary.opacity(0.7)).frame(width: 1, height: 9).offset(x: unity - 0.5)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 16, height: 16)
                    .offset(x: min(max(x - 8, 0), width - 16))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                dragging = true
                let f = min(max(g.location.x / max(width, 1), 0), 1)
                value = snap(range.lowerBound + f * (range.upperBound - range.lowerBound))
            }.onEnded { _ in dragging = false })
        }
        .frame(height: 18)
        .frame(minWidth: 60)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(percentText(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, range.upperBound)
            case .decrement: value = max(value - 0.05, range.lowerBound)
            @unknown default: break
            }
        }
        .onScrollWheel { delta in value = min(max(value + delta * 0.01, range.lowerBound), range.upperBound) }
    }

    /// Sticks to 100% when dragged close to it, so getting back to normal is easy.
    private func snap(_ v: Double) -> Double {
        let rounded = (v * 100).rounded() / 100
        return range.upperBound > 1 && abs(rounded - 1) < 0.025 ? 1 : rounded
    }
}

/// A vertical fader for the mixing desk and the EQ bands.
struct VerticalFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...AppAudioSettings.maxBoost
    /// The value drawn as a line across the track: 100% for volume, 0 dB for EQ.
    var reference: Double? = 1
    var small = false
    var label: String
    var onScroll: Double = 0.01

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = range.upperBound - range.lowerBound
            let fraction = (value - range.lowerBound) / span
            let y = height * (1 - fraction)
            let trackWidth: CGFloat = small ? 4 : 6
            let fillFrom = reference.map { height * (1 - ($0 - range.lowerBound) / span) } ?? height
            let isBoost = range.lowerBound >= 0 && value > 1.0001
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(width: trackWidth)
                // The fill runs from the reference line for EQ, from the bottom for volume.
                let top = range.lowerBound < 0 ? min(y, fillFrom) : y
                let bottom = range.lowerBound < 0 ? max(y, fillFrom) : height
                Capsule().fill(isBoost ? LevelStyle.boost : Color.accentColor)
                    .frame(width: trackWidth, height: max(bottom - top, 2))
                    .offset(y: top)
                if let reference, range.contains(reference) {
                    Rectangle().fill(Color.secondary.opacity(0.7))
                        .frame(width: trackWidth + (small ? 8 : 10), height: 1)
                        .offset(y: height * (1 - (reference - range.lowerBound) / span))
                }
                RoundedRectangle(cornerRadius: small ? 3 : 4, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.black.opacity(0.25)).frame(height: 1).padding(.horizontal, small ? 3 : 5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: small ? 16 : 26, height: small ? 10 : 12)
                    .offset(y: min(max(y - (small ? 5 : 6), 0), height - (small ? 10 : 12)))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = 1 - min(max(g.location.y / max(height, 1), 0), 1)
                var v = range.lowerBound + f * span
                v = range.lowerBound < 0 ? (v * 2).rounded() / 2 : (v * 100).rounded() / 100
                if let reference, abs(v - reference) < span * 0.015 { v = reference }
                value = v
            })
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(range.lowerBound < 0 ? String(format: "%+.1f dB", value) : percentText(value))
        .accessibilityAdjustableAction { direction in
            let step = range.lowerBound < 0 ? 0.5 : 0.05
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
        .onScrollWheel { delta in value = min(max(value + delta * onScroll, range.lowerBound), range.upperBound) }
    }
}

/// A rotary dial: drag up or down to turn it.
struct VolumeKnob: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...AppAudioSettings.maxBoost
    var label: String
    var size: CGFloat = 100

    @State private var dragStart: Double?

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let fraction = (value - range.lowerBound) / span
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * fraction)
                .stroke(LevelStyle.fill(for: value), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .fill(RadialGradient(colors: [Color(nsColor: .controlBackgroundColor), Color.primary.opacity(0.10)],
                                     center: .init(x: 0.4, y: 0.3), startRadius: 2, endRadius: size * 0.4))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                .padding(size * 0.22)
            Capsule().fill(Color.primary.opacity(0.65))
                .frame(width: 2.5, height: size * 0.11)
                .offset(y: -size * 0.17)
                .rotationEffect(.degrees(-135 + 270 * fraction))
            Text(percentText(value))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(value > 1.0001 ? Color.orange : Color.primary)
                .offset(y: size * 0.48)
        }
        .frame(width: size, height: size)
        .padding(.bottom, 10)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let start = dragStart ?? value
            if dragStart == nil { dragStart = start }
            var v = start - g.translation.height * span / 200
            v = (min(max(v, range.lowerBound), range.upperBound) * 100).rounded() / 100
            if range.upperBound > 1, abs(v - 1) < 0.025 { v = 1 }
            value = v
        }.onEnded { _ in dragStart = nil })
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(percentText(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, range.upperBound)
            case .decrement: value = max(value - 0.05, range.lowerBound)
            @unknown default: break
            }
        }
        .onScrollWheel { delta in value = min(max(value + delta * 0.01, range.lowerBound), range.upperBound) }
    }
}

// MARK: - Meters

/// Live levels for tapped apps, read about 20 times a second while a meter is on screen.
@Observable
@MainActor
final class Meters {
    static let shared = Meters()
    private(set) var levels: [String: Float] = [:]
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var timer: Timer?

    func watch() {
        watchers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { Meters.shared.tick() }
        }
    }

    func unwatch() {
        watchers = max(watchers - 1, 0)
        if watchers == 0 { timer?.invalidate(); timer = nil; levels = [:] }
    }

    private func tick() {
        var next: [String: Float] = [:]
        for id in AudioEngine.shared.tapped {
            let peak = AudioEngine.shared.takePeak(id) ?? 0
            // Falls back slowly, as meters do.
            next[id] = max(peak, (levels[id] ?? 0) * 0.82)
        }
        if next != levels { levels = next }
    }
}

/// Three bouncing bars while an app plays, flat while it's silent.
struct PlayingIndicator: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let h = playing ? 4 + 9 * abs(sin(t * 4.2 + Double(i) * 1.3)) : 3
                    RoundedRectangle(cornerRadius: 1).fill(playing ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 3, height: h)
                }
            }
            .frame(width: 15, height: 14, alignment: .bottom)
        }
        .accessibilityLabel(playing ? "Playing" : "Silent")
    }
}

/// A vertical level meter for one app (mixing desk).
struct LevelMeter: View {
    let appID: String
    let playing: Bool
    @State private var meters = Meters.shared

    var body: some View {
        GeometryReader { geo in
            let level = Double(meters.levels[appID] ?? (playing && !AudioEngine.shared.isTapped(appID) ? 0.45 : 0))
            let h = geo.size.height * min(level, 1)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.10))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.7),
                                                 .init(color: .yellow, location: 0.88), .init(color: .orange, location: 1)],
                                         startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) { Rectangle().frame(height: h) }
            }
        }
        .frame(width: 6)
        .onAppear { meters.watch() }
        .onDisappear { meters.unwatch() }
        .accessibilityHidden(true)
    }
}

// MARK: - Scroll wheel

extension View {
    /// Calls `action` with the vertical scroll amount (positive = up) while the pointer is over
    /// the view and Option is held. Plain scrolling always scrolls the list: a slider that
    /// grabbed the wheel as the pointer passed over it stopped the scroll and changed a volume.
    func onScrollWheel(_ action: @escaping (Double) -> Void) -> some View {
        overlay(ScrollWheelCatcher(action: action).allowsHitTesting(true))
    }
}

private struct ScrollWheelCatcher: NSViewRepresentable {
    let action: (Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: ((Double) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            // A local monitor rather than scrollWheel(_:), so clicks and drags still reach the
            // SwiftUI control underneath.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.contains(.option) else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
                if abs(dy) > 0.01 { self.action?(Double(dy)) }
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
