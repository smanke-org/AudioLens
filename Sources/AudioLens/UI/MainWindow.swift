import AppKit
import AudioLensKit
import SwiftUI

/// The AudioLens window. It shows the chosen layout, or shrinks in place to the compact panel;
/// each layout and the compact panel remember their own size and position on this Mac.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()

    private var window: NSWindow?
    private var store: SettingsStore { .shared }
    /// While the window moves to another mode's frame, its move and resize events are that
    /// animation, not the user: saving them stored the old layout's size under the new name.
    private var applyingFrame = false
    private static let floatKey = "compactFloats"

    var isVisible: Bool { window?.isVisible == true }

    /// Keeps the compact window above other windows.
    var compactFloats: Bool {
        get { UserDefaults.standard.bool(forKey: Self.floatKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.floatKey)
            applyLevel()
        }
    }

    func show(compact: Bool? = nil) {
        if let compact, compact != store.compact {
            saveFrame()
            store.compact = compact
        }
        if window == nil { makeWindow() }
        AirPlayBrowser.shared.start()
        applyMode()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func toggleVisible() {
        if let window, window.isVisible, window.isKeyWindow { window.orderOut(nil) } else { show() }
    }

    func setCompact(_ compact: Bool) {
        guard compact != store.compact || window?.isVisible != true else { return }
        show(compact: compact)
    }

    func setLayout(_ layout: WindowLayout) {
        saveFrame()
        store.layout = layout
        store.compact = false
        show()
    }

    private func makeWindow() {
        let hosting = NSHostingController(rootView: MainRoot())
        // The window's size is AppKit's to manage; letting SwiftUI drive it fights the
        // per-layout frames below.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "AudioLens"
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        // AudioLens keeps a frame per layout itself. macOS's own window restoration put back
        // whatever size the window last had, a moment after launch, over the layout's frame.
        window.isRestorable = false
        self.window = window
    }

    private func applyMode() {
        guard let window else { return }
        let compact = store.compact
        if compact {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentMinSize = NSSize(width: 340, height: 380)
            window.contentMaxSize = NSSize(width: 340, height: 1600)
        } else {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.contentMinSize = NSSize(width: store.layout.minimumWidth, height: 420)
            window.contentMaxSize = NSSize(width: 10000, height: 10000)
        }
        applyingFrame = true
        let animate = window.isVisible
        let target = frame(for: compact)
        window.setFrame(target, display: true, animate: animate)
        DispatchQueue.main.asyncAfter(deadline: .now() + (animate ? 0.6 : 0.05)) { [weak self] in self?.applyingFrame = false }
        applyLevel()
    }

    private func applyLevel() {
        window?.level = store.compact && compactFloats ? .floating : .normal
    }

    // MARK: - Frames

    private var frameKey: String { store.compact ? "frame.compact" : "frame.\(store.layout.rawValue)" }

    private func saveFrame() {
        guard let window, window.isVisible, !applyingFrame else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey)
    }

    /// The saved frame for a mode if it's still on a screen; otherwise its natural size,
    /// placed where the window is now (compact keeps the top-right corner, like a panel).
    private func frame(for compact: Bool) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            var rect = NSRectFromString(saved)
            // Never narrower than the layout needs (an older build saved too-small frames).
            if !compact { rect.size.width = max(rect.width, store.layout.minimumWidth) }
            if rect.width > 100, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return rect }
        }
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size: NSSize = compact
            ? NSSize(width: 340, height: min(600, visible.height - 40))
            : NSSize(width: store.layout.defaultSize.width, height: store.layout.defaultSize.height)
        let content = window.map { $0.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size } ?? size
        let current = window?.isVisible == true ? window!.frame : nil
        var origin: NSPoint
        if let current {
            origin = compact
                ? NSPoint(x: current.maxX - content.width, y: current.maxY - content.height)
                : NSPoint(x: current.midX - content.width / 2, y: current.maxY - content.height)
        } else {
            origin = NSPoint(x: visible.midX - content.width / 2, y: visible.midY - content.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - content.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - content.height)
        return NSRect(origin: origin, size: content)
    }

    /// Another app (a window manager, say) can resize the window through Accessibility, past
    /// the minimum AppKit enforces for the user. A layout squeezed below its width clips, so
    /// it's widened back.
    func windowDidResize(_ notification: Notification) {
        guard let window, !applyingFrame, !store.compact else { return }
        let minimum = store.layout.minimumWidth
        let content = window.contentRect(forFrameRect: window.frame)
        guard content.width < minimum - 1 else { return }
        DispatchQueue.main.async {
            var frame = window.frame
            frame.size.width += minimum - content.width
            if let visible = window.screen?.visibleFrame, frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
            window.setFrame(frame, display: true)
        }
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowWillClose(_ notification: Notification) { saveFrame() }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

/// The window's content: the chosen layout, or the compact panel.
struct MainRoot: View {
    @State private var store = SettingsStore.shared

    var body: some View {
        Group {
            if store.compact {
                CompactPanel(mode: .window)
                    .padding(.top, 18)
                    .ignoresSafeArea(edges: .top)
            } else {
                Group {
                    switch store.layout {
                    case .sourceList: SourceListLayout()
                    case .mixingDesk: MixingDeskLayout()
                    case .dialBoard: DialBoardLayout()
                    case .deviceInspector: DeviceInspectorLayout()
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            MainWindow.shared.setCompact(true)
                        } label: {
                            Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                        .help("Shrink to the compact panel (⇧⌘C)")
                        Button {
                            SettingsWindow.shared.show()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("Settings")
                    }
                }
            }
        }
        .frame(minWidth: store.compact ? 340 : 640, minHeight: 360)
    }
}
