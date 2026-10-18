import AppKit
import AudioLensKit
import Carbon.HIToolbox
import SwiftUI

extension Shortcut {
    /// Builds one from a key press. With `requireModifier`, only if it has at least one of
    /// ⌘ ⌥ ⌃: a bare key as a global shortcut would steal ordinary typing from every app.
    init?(event: NSEvent, requireModifier: Bool) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if requireModifier, flags.intersection([.command, .option, .control]).isEmpty { return nil }
        self.init(keyCode: event.keyCode, modifiers: Self.modifiers(flags),
                  key: KeyNames.name(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }
}

/// The global volume keys: up, down and mute for whichever app is playing, through Carbon's
/// RegisterEventHotKey, which works without any permission.
@Observable
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    enum Action: UInt32, CaseIterable { case up = 1, down, mute }

    /// Shortcuts that couldn't be registered, almost always because another app holds them.
    private(set) var failed: Set<UInt32> = []

    @ObservationIgnored private var refs: [EventHotKeyRef] = []
    @ObservationIgnored private var installed = false
    @ObservationIgnored private var paused = false

    func apply() {
        installHandlerOnce()
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        var failures: Set<UInt32> = []
        guard !paused else { failed = []; return }
        let store = SettingsStore.shared
        for (action, key) in [(Action.up, store.hotKeyUp), (.down, store.hotKeyDown), (.mute, store.hotKeyMute)] {
            guard let key else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x414C_4E53), id: action.rawValue) // "ALNS"
            if RegisterEventHotKey(UInt32(key.keyCode), key.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else {
                failures.insert(action.rawValue)
                NSLog("AudioLens: shortcut \(key.display) not registered, probably taken by another app")
            }
        }
        failed = failures
    }

    func isFailed(_ action: Action) -> Bool { failed.contains(action.rawValue) }

    /// While a shortcut is being recorded, the current ones must not fire.
    func pause() { paused = true; apply() }
    func resume() { paused = false; apply() }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        guard let app = AudioEngine.shared.hotKeyTarget else {
            NSSound.beep()
            return
        }
        let store = SettingsStore.shared
        let step = store.volumeStep
        store.updateApp(app.id) { s in
            if s.name == nil { s.name = app.name }
            switch action {
            case .up:
                s.muted = false
                s.volume = min(s.volume + step, store.maxVolume)
            case .down: s.volume = max(s.volume - step, 0)
            case .mute: s.muted.toggle()
            }
        }
        VolumeHUD.shared.show(app: app)
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    let which = id.id
    MainActor.assumeIsolated { HotKeys.shared.fire(which) }
    return noErr
}

/// Click, then press a shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    var placeholder = "Click to set"

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        update(view)
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) { update(view) }

    private func update(_ view: RecorderButton) {
        view.onChange = { shortcut = $0 }
        view.placeholder = placeholder
        view.shortcut = shortcut
    }

    final class RecorderButton: NSButton {
        var onChange: ((Shortcut?) -> Void)?
        var placeholder = "Click to set" { didSet { refresh() } }
        var shortcut: Shortcut? { didSet { refresh() } }
        private var recording = false { didSet { refresh() } }
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            target = self
            action = #selector(toggle)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 130, height: super.intrinsicContentSize.height) }

        private func refresh() {
            title = recording ? "Press keys…" : (shortcut?.display ?? placeholder)
        }

        @objc private func toggle() { recording ? stop() : start() }

        private func start() {
            recording = true
            HotKeys.shared.pause()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let bare = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                switch Int(event.keyCode) {
                case kVK_Escape where bare:
                    self.stop()
                case kVK_Delete where bare, kVK_ForwardDelete where bare:
                    self.shortcut = nil
                    self.onChange?(nil)
                    self.stop()
                default:
                    guard let key = Shortcut(event: event, requireModifier: true) else {
                        NSSound.beep()
                        return nil
                    }
                    self.shortcut = key
                    self.onChange?(key)
                    self.stop()
                }
                return nil
            }
        }

        private func stop() {
            recording = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            HotKeys.shared.resume()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, recording { stop() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
