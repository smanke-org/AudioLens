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

    /// Builds one from a key code and Carbon modifiers (ShortcutsLens's Change Shortcut), named
    /// the way a key press would be in the current keyboard layout. Nil without ⌘ ⌥ or ⌃, as
    /// the Settings recorder would refuse it.
    init?(keyCode: Int, carbonModifiers: Int) {
        guard (0...127).contains(keyCode) else { return nil }
        var m: KeyModifiers = []
        if carbonModifiers & controlKey != 0 { m.insert(.control) }
        if carbonModifiers & optionKey != 0 { m.insert(.option) }
        if carbonModifiers & shiftKey != 0 { m.insert(.shift) }
        if carbonModifiers & cmdKey != 0 { m.insert(.command) }
        guard !m.intersection([.control, .option, .command]).isEmpty else { return nil }
        let code = UInt16(keyCode)
        self.init(keyCode: code, modifiers: m, key: KeyNames.name(keyCode: code, characters: Self.layoutCharacter(code)))
    }

    /// What the key types with no modifiers in the current layout ("u" for kVK_ANSI_U on QWERTY).
    private static func layoutCharacter(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
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
        ShortcutsLensReport.publish()
    }

    /// For ShortcutsLens: the shortcuts that registered, named as Settings names them.
    var reportedShortcuts: [ShortcutsLensReport.Shortcut] {
        guard !paused else { return [] }
        let store = SettingsStore.shared
        let all: [(Action, String, String, Shortcut?)] = [
            (.up, "volumeUp", "Turn the playing app up", store.hotKeyUp),
            (.down, "volumeDown", "Turn the playing app down", store.hotKeyDown),
            (.mute, "mute", "Mute or unmute the playing app", store.hotKeyMute),
        ]
        return all.compactMap { action, id, title, key in
            guard let key, !isFailed(action) else { return nil }
            return .init(id: id, title: title, keyCode: Int(key.keyCode), carbonModifiers: Int(key.carbonModifiers))
        }
    }

    func isFailed(_ action: Action) -> Bool { failed.contains(action.rawValue) }

    /// ShortcutsLens's Change Shortcut: saves the keys as the Settings recorder does (so Settings
    /// shows them and sync carries them) and registers again. Nil when done, or why not.
    func change(id: String, keyCode: Int, carbonModifiers: Int) -> String? {
        let ids: [(String, Action, String)] = [
            ("volumeUp", .up, "Turn the playing app up"),
            ("volumeDown", .down, "Turn the playing app down"),
            ("mute", .mute, "Mute or unmute the playing app"),
        ]
        guard let action = ids.first(where: { $0.0 == id })?.1 else { return "AudioLens has no shortcut called \(id)." }
        guard let key = Shortcut(keyCode: keyCode, carbonModifiers: carbonModifiers) else {
            return "AudioLens shortcuts need ⌘, ⌥ or ⌃."
        }
        if let other = ids.first(where: { $0.1 != action && shortcut(for: $0.1).map { $0.sameKeys(as: key) } == true }) {
            return "AudioLens already uses \(key.display) to \(other.2.prefix(1).lowercased() + other.2.dropFirst())."
        }
        let previous = shortcut(for: action)
        save(key, for: action)
        apply()
        guard isFailed(action) else { return nil }
        // Taken by another app: keep the old keys rather than leave the shortcut dead.
        save(previous, for: action)
        apply()
        return "\(key.display) is taken by another app, so AudioLens kept \(previous?.display ?? "no shortcut")."
    }

    private func shortcut(for action: Action) -> Shortcut? {
        let store = SettingsStore.shared
        switch action {
        case .up: return store.hotKeyUp
        case .down: return store.hotKeyDown
        case .mute: return store.hotKeyMute
        }
    }

    private func save(_ key: Shortcut?, for action: Action) {
        let store = SettingsStore.shared
        switch action {
        case .up: store.hotKeyUp = key
        case .down: store.hotKeyDown = key
        case .mute: store.hotKeyMute = key
        }
    }

    /// Starts answering ShortcutsLens, Change Shortcut included.
    func startShortcutsLensReport() {
        ShortcutsLensReport.start({ HotKeys.shared.reportedShortcuts }, change: { id, keyCode, modifiers in
            HotKeys.shared.change(id: id, keyCode: keyCode, carbonModifiers: modifiers)
        })
    }

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
        perform(action, on: AudioEngine.shared.hotKeyTarget)
    }

    /// What a hotkey does, also for `audiolens://volume-up`, `volume-down` and `mute`:
    /// turns `app` up or down a step or toggles its mute, and shows the volume indicator.
    func perform(_ action: Action, on target: AudioApp?) {
        guard let app = target else {
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
