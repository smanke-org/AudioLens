import AppKit
import AudioLensKit
import SwiftUI

/// A brief on-screen level, shown when a hotkey changes an app's volume.
@MainActor
final class VolumeHUD {
    static let shared = VolumeHUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = HUDModel()

    @Observable
    @MainActor
    final class HUDModel {
        var app: AudioApp?
    }

    func show(app: AudioApp) {
        model.app = app
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 74),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: HUDView(model: model))
            self.panel = panel
        }
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - 150, y: frame.minY + 90))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private struct HUDView: View {
        let model: HUDModel
        @State private var store = SettingsStore.shared

        var body: some View {
            if let app = model.app {
                let s = store.app(app.id)
                HStack(spacing: 12) {
                    AppIcon(app: app, size: 34)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(app.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(s.muted ? "Muted" : percentText(s.volume)).font(.callout).monospacedDigit()
                                .foregroundStyle(s.muted ? .red : LevelStyle.text(s.volume))
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.15))
                                Capsule().fill(LevelStyle.fill(for: s.volume))
                                    .frame(width: geo.size.width * (s.muted ? 0 : s.volume / store.maxVolume))
                            }
                        }
                        .frame(height: 6)
                    }
                }
                .padding(.horizontal, 16)
                .frame(width: 300, height: 74)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}
