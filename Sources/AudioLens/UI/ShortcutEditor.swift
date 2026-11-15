import AppKit
import AudioLensKit
import Carbon.HIToolbox
import SwiftUI

/// A shortcut box. Clicking it opens an editor with modifier buttons and a key field; pressing
/// the keys while it's open fills them in too. `action` is which shortcut this is, so the same
/// keys can be moved off another AudioLens shortcut.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    var action: HotKeys.Action? = nil

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        // Keep its own width rather than stretching across a row.
        view.setContentHuggingPriority(.required, for: .horizontal)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onChange = { shortcut = $0 }
        view.action_ = action
        view.shortcut = shortcut
    }

    final class RecorderButton: NSButton {
        var onChange: ((Shortcut?) -> Void)?
        var action_: HotKeys.Action?
        var shortcut: Shortcut? { didSet { refresh() } }
        private var popover: NSPopover?
        private var model: ShortcutEditorModel?
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            target = self
            action = #selector(open)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: super.intrinsicContentSize.height) }

        private func refresh() {
            title = popover != nil ? "Set a shortcut…" : (shortcut?.display ?? "Click to set")
        }

        @objc private func open() {
            guard popover == nil, window != nil else { popover?.close(); return }
            // Settings may not have redrawn yet after keys moved off this shortcut.
            if let action_ { shortcut = HotKeys.shared.shortcut(for: action_) }
            // The current shortcuts must not fire while new keys are pressed.
            HotKeys.shared.pause()
            let model = ShortcutEditorModel(shortcut: shortcut, action: action_)
            model.finish = { [weak self] result in self?.finish(result) }
            self.model = model
            let host = NSHostingController(rootView: ShortcutEditor(model: model))
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = host
            popover.contentSize = host.view.fittingSize
            popover.delegate = PopoverCloser.shared
            PopoverCloser.shared.onClose[ObjectIdentifier(popover)] = { [weak self] in self?.closed() }
            self.popover = popover
            refresh()
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
            // A popover that couldn't be shown never reports closing: don't leave the hotkeys off.
            guard popover.isShown else { closed(); return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak model] event in
                guard let model else { return event }
                return model.handle(event) ? nil : event
            }
        }

        /// Set (a shortcut, or nil for Clear) or Cancel.
        private func finish(_ result: ShortcutEditorModel.Result) {
            if case .set(let key) = result {
                if let key {
                    // Move: the keys leave any other shortcut that had them.
                    for other in HotKeys.shared.others(using: key, except: action_) {
                        HotKeys.shared.save(nil, for: other)
                    }
                }
                shortcut = key
                onChange?(key)
            }
            // Clean up now: the close message can come late, or never while AudioLens isn't
            // frontmost, which would leave the hotkeys off.
            let shown = popover
            closed()
            shown?.close()
        }

        /// Runs once per editor: from finish, or when the popover closes on its own.
        private func closed() {
            guard let popover else { return }
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            PopoverCloser.shared.onClose[ObjectIdentifier(popover)] = nil
            self.popover = nil
            model = nil
            refresh()
            // The binding writes the settings synchronously, so this registers the new keys.
            HotKeys.shared.resume()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { popover?.close() }
            super.viewWillMove(toWindow: newWindow)
        }

        #if DEBUG
        var debugTitle: String { title }
        var debugModel: ShortcutEditorModel? { model }
        var debugShown: Bool { popover?.isShown ?? false }
        var debugPopoverView: NSView? { popover?.contentViewController?.view }
        #endif
    }
}

/// NSPopover's delegate is weak; one shared object tells each button its popover closed.
@MainActor private final class PopoverCloser: NSObject, NSPopoverDelegate {
    static let shared = PopoverCloser()
    var onClose: [ObjectIdentifier: () -> Void] = [:]
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        onClose[ObjectIdentifier(popover)]?()
    }
}

@MainActor final class ShortcutEditorModel: ObservableObject {
    enum Result { case set(Shortcut?), cancel }

    @Published var control = false
    @Published var option = false
    @Published var shift = false
    @Published var command = false
    /// What's in the key box: one typed character, or a named key from the menu.
    @Published var keyText = ""
    /// Set when the key came from the menu or a key press, so its name needn't be looked up.
    @Published var keyCode: UInt16?
    @Published var showHint = false

    let action: HotKeys.Action?
    let original: Shortcut?
    var finish: ((Result) -> Void)?
    private var modifiersDown = false
    private var sawKey = false

    init(shortcut: Shortcut?, action: HotKeys.Action?) {
        self.action = action
        original = shortcut
        if let shortcut {
            control = shortcut.modifiers.contains(.control)
            option = shortcut.modifiers.contains(.option)
            shift = shortcut.modifiers.contains(.shift)
            command = shortcut.modifiers.contains(.command)
            keyCode = shortcut.keyCode
            keyText = EditorKeys.name(shortcut.keyCode)
        }
    }

    var carbonModifiers: Int {
        (control ? controlKey : 0) | (option ? optionKey : 0) | (shift ? shiftKey : 0) | (command ? cmdKey : 0)
    }

    /// The shortcut as it stands, or nil while it isn't one AudioLens can use.
    var combo: Shortcut? {
        guard let code = keyCode else { return nil }
        return Shortcut(keyCode: Int(code), carbonModifiers: carbonModifiers)
    }

    /// Why Set is off, when a key is chosen.
    var problem: String? {
        guard !keyText.isEmpty else { return nil }
        guard let code = keyCode else { return "\(AppInfo.name) can't find “\(keyText)” on this keyboard." }
        if combo == nil && !KeyNames.isFunctionKey(code) && !(control || option || command) {
            return "Add ⌃, ⌥ or ⌘. Only F-keys can be used on their own."
        }
        return nil
    }

    /// Other AudioLens shortcuts these keys will be taken from.
    var movesFrom: [String] {
        guard let combo else { return [] }
        return HotKeys.shared.others(using: combo, except: action).map { HotKeys.shared.title(of: $0) }
    }

    var systemUse: String? {
        guard let combo else { return nil }
        return SystemShortcuts.purpose(of: combo)
    }

    /// The key box changed: keep the last character typed and find its key.
    func typed(_ text: String) {
        // A named key from the menu ("F6", "Space") stays whole.
        if let code = keyCode, EditorKeys.name(code) == text { keyText = text; return }
        if text.count > 1, let last = text.last { typed(String(last)); return }
        keyText = text
        guard !text.isEmpty else { keyCode = nil; return }
        if let found = EditorKeys.keyCode(for: text) {
            keyCode = found.code
            if found.needsShift { shift = true }
            // Show the base key: ⇧ + = stays “=”, not “+”.
            let base = EditorKeys.name(found.code)
            if base != text { keyText = base }
        } else {
            keyCode = nil
        }
    }

    func choose(_ code: UInt16) {
        keyCode = code
        keyText = EditorKeys.name(code)
    }

    /// A key press while the editor is open. True when it was used.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .flagsChanged {
            // A shortcut another app has taken never arrives: the modifiers go down and up
            // with no key between them.
            let held = !flags.intersection([.command, .option, .control]).isEmpty
            if held && !modifiersDown { modifiersDown = true; sawKey = false }
            else if !held && modifiersDown { modifiersDown = false; if !sawKey { showHint = true } }
            return false
        }
        sawKey = true
        let code = event.keyCode
        if Int(code) == kVK_Escape { finish?(.cancel); return true }
        if Int(code) == kVK_Return || Int(code) == kVK_ANSI_KeypadEnter, flags.isEmpty {
            if combo != nil && problem == nil { finish?(.set(combo)) }
            return true
        }
        // With ⌃ ⌥ or ⌘ held, or an F-key, it's the whole shortcut; plain typing goes to the key box.
        guard !flags.intersection([.command, .option, .control]).isEmpty || KeyNames.isFunctionKey(code) else { return false }
        control = flags.contains(.control)
        option = flags.contains(.option)
        shift = flags.contains(.shift)
        command = flags.contains(.command)
        choose(code)
        showHint = false
        return true
    }
}

struct ShortcutEditor: View {
    @ObservedObject var model: ShortcutEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                toggle("⌃", "Control", $model.control)
                toggle("⌥", "Option", $model.option)
                toggle("⇧", "Shift", $model.shift)
                toggle("⌘", "Command", $model.command)
                Text("+").foregroundStyle(.secondary)
                TextField("Key", text: Binding(get: { model.keyText }, set: { model.typed($0) }))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
                    .help("Type a letter, number or symbol")
                Menu {
                    ForEach(EditorKeys.specialKeys, id: \.self) { code in
                        Button(EditorKeys.spoken(code)) { model.choose(code) }
                    }
                    Divider()
                    ForEach(Array(EditorKeys.functionKeys.prefix(12)), id: \.self) { code in
                        Button(EditorKeys.name(code)) { model.choose(code) }
                    }
                    Menu("More F-keys") {
                        ForEach(Array(EditorKeys.functionKeys.dropFirst(12)), id: \.self) { code in
                            Button(EditorKeys.name(code)) { model.choose(code) }
                        }
                    }
                } label: { Image(systemName: "keyboard") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Keys you can't type: arrows, Space, Return, F-keys…")
            }

            Text(model.combo?.display ?? "No shortcut")
                .font(.title2.monospaced())
                .frame(maxWidth: .infinity)
                .foregroundStyle(model.combo == nil ? .secondary : .primary)

            if let problem = model.problem {
                note(problem, "exclamationmark.triangle")
            } else if !model.movesFrom.isEmpty {
                note("Moves from \(model.movesFrom.joined(separator: ", ")), which will have no shortcut.", "arrow.right.circle")
            } else if let system = model.systemUse {
                note("macOS uses this for \(system). It may not reach \(AppInfo.name).", "exclamationmark.triangle")
            }
            if model.showHint {
                note("Nothing came through. If you pressed a shortcut, another app is using those keys. Press different keys, or set them with the buttons above.", "info.circle")
            }
            Text("Or press the shortcut now.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Clear") { model.finish?(.set(nil)) }
                    .disabled(model.original == nil)
                Spacer()
                Button("Cancel") { model.finish?(.cancel) }
                Button("Set") { model.finish?(.set(model.combo)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.combo == nil || model.problem != nil)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func toggle(_ symbol: String, _ name: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            Text(symbol).font(.title3).frame(minWidth: 22)
        }
        .toggleStyle(.button)
        .controlSize(.large)
        .help(name)
        .accessibilityLabel(name)
    }

    private func note(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Key names and lookups for the editor.
enum EditorKeys {
    static let specialKeys: [UInt16] = [kVK_Space, kVK_Return, kVK_Tab, kVK_Escape, kVK_Delete, kVK_ForwardDelete,
                                        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown].map { UInt16($0) }
    static let functionKeys: [UInt16] = KeyNames.functionKeyCodes

    /// How a key reads in the box and in shortcuts: "A", "=", "Space", "F5", "↩".
    static func name(_ code: UInt16) -> String {
        KeyNames.name(keyCode: code, characters: Shortcut.layoutCharacter(code))
    }

    /// How a key reads in the keyboard menu.
    static func spoken(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Space: "Space"
        case kVK_Return: "Return ↩"
        case kVK_Tab: "Tab ⇥"
        case kVK_Escape: "Escape ⎋"
        case kVK_Delete: "Delete ⌫"
        case kVK_ForwardDelete: "Forward Delete ⌦"
        case kVK_LeftArrow: "Left Arrow ←"
        case kVK_RightArrow: "Right Arrow →"
        case kVK_UpArrow: "Up Arrow ↑"
        case kVK_DownArrow: "Down Arrow ↓"
        case kVK_Home: "Home ↖"
        case kVK_End: "End ↘"
        case kVK_PageUp: "Page Up ⇞"
        case kVK_PageDown: "Page Down ⇟"
        default: name(code)
        }
    }

    /// The key that types this character in the current layout, and whether it needs ⇧.
    static func keyCode(for text: String) -> (code: UInt16, needsShift: Bool)? {
        let wanted = text.lowercased()
        if wanted == " " { return (UInt16(kVK_Space), false) }
        let typing = (UInt16(0)...127).filter { !KeyNames.isFunctionKey($0) && !specialKeys.contains($0) && !keypad.contains($0) }
        if let code = typing.first(where: { Shortcut.layoutCharacter($0)?.lowercased() == wanted }) { return (code, false) }
        if let code = typing.first(where: { Shortcut.layoutCharacter($0, shift: true) == text }) { return (code, true) }
        return nil
    }

    /// Prefer the main keys over the keypad's copies of the digits.
    private static let keypad: Set<UInt16> = Set([kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
        kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals].map { UInt16($0) })
}
