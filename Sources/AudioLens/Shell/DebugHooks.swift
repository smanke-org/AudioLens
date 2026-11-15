#if DEBUG
import AppKit
import Carbon.HIToolbox
import SwiftUI
import AudioLensKit

/// Debug-build switches for testing and screenshots, set in the environment:
///
///     AUDIOLENS_DEBUG_SHOW=sourceList|mixingDesk|dialBoard|deviceInspector|compact|settings:<pane>
///
/// The window opens in that state as soon as launch finishes. Returns true to stop normal launch.
enum DebugHooks {
    @MainActor
    static func run() -> Bool {
        guard let show = ProcessInfo.processInfo.environment["AUDIOLENS_DEBUG_SHOW"] else { return false }
        if show == "compact" {
            MainWindow.shared.show(compact: true)
        } else if show.hasPrefix("settings") {
            let pane = SettingsPane(rawValue: String(show.split(separator: ":").last ?? "general")) ?? .general
            SettingsWindow.shared.show(pane)
        } else if let layout = WindowLayout(rawValue: show) {
            MainWindow.shared.setLayout(layout)
        }
        return true
    }

    /// `AUDIOLENS_DEBUG_QUIT_TEST=<return|cancel|quit|suppress|off>` quits as ⌘Q does, then
    /// answers the question a second later: presses Return (then Cancel), clicks Cancel or
    /// Quit (ticking "Don't ask again" first for `suppress`), or with `off` turns the setting
    /// off first. What the question looked like goes to `debug.quitTest` in the defaults, and
    /// the activation policy after a Cancel to `debug.quitTestAfter`. Run it under a test
    /// bundle id with AUDIOLENS_SYNC_FOLDER set: the defaults are the app's own, and the
    /// sync key is a test one then.
    @MainActor
    static func runQuitTest() -> Bool {
        guard let how = ProcessInfo.processInfo.environment["AUDIOLENS_DEBUG_QUIT_TEST"] else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if how == "off" { SettingsStore.shared.confirmQuit = false }
            note("debug.quitTest", "no question; policy \(NSApp.activationPolicy().rawValue); active before \(NSApp.isActive)")
            UserDefaults.standard.removeObject(forKey: "debug.quitTestAfter")
            answer(how, after: 1)
            NSApp.terminate(nil)
            // Still running: the question was cancelled. The old policy comes back a turn later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                note("debug.quitTestAfter", "still running; confirmQuit \(SettingsStore.shared.confirmQuit); policy \(NSApp.activationPolicy().rawValue)")
            }
        }
        return true
    }

    private static func note(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
        UserDefaults.standard.synchronize()
    }

    /// A timer in `.common` mode, since a plain scheduled one doesn't fire inside runModal.
    @MainActor
    private static func answer(_ how: String, after seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { answerQuit(how) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private static func answerQuit(_ how: String) {
        guard let window = NSApp.modalWindow else {
            if how == "cancel-after-return" { note("debug.quitTestReturn", "after Return: question gone") }
            return
        }
        var texts: [String] = []
        var buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        func click(_ title: String) { buttons.first { $0.title == title }?.performClick(nil) }
        if how == "cancel-after-return" {
            note("debug.quitTestReturn", "after Return: question still up")
            return click("Cancel")
        }
        let titles = buttons.map { "\($0.title)[\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent == "\u{1b}" ? "Esc" : $0.keyEquivalent)]" }
        note("debug.quitTest", "asked \(texts) buttons \(titles) key \(window.isKeyWindow) active \(NSApp.isActive) visible \(window.isVisible) level \(window.level.rawValue) frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") policy \(NSApp.activationPolicy().rawValue)")
        switch how {
        case "return":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
            // Return should leave the question up; note that, then cancel it.
            answer("cancel-after-return", after: 1)
        case "cancel": click("Cancel")
        case "quit", "suppress":
            if how == "suppress" { click("Don't ask again") }
            click("Quit")
        default: break
        }
    }

    /// `AUDIOLENS_DEBUG_SHORTCUT_TEST=<folder>` (only in an APP_STORE test copy, whose settings
    /// are the test suite's): puts Settings › Hotkeys in a window off screen, opens the shortcut
    /// editor on "Turn the playing app up" and checks it: "+" becomes ⇧=, a bare letter is
    /// refused, an F-key may stand alone, modifiers pressed and let go with no key show the
    /// hint, pressing the mute shortcut's keys moves them, and Clear clears. Writes result.txt
    /// and editor.png (the popover drawn with cacheDisplay) to the folder.
    @MainActor
    static func runShortcutEditorTest() -> Bool {
        guard AgentSocket.isTestRun,
              let folder = ProcessInfo.processInfo.environment["AUDIOLENS_DEBUG_SHORTCUT_TEST"] else { return false }
        let dir = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SettingsStore.shared
        store.hotKeyUp = SettingsStore.defaultUp
        store.hotKeyDown = SettingsStore.defaultDown
        store.hotKeyMute = SettingsStore.defaultMute
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 640, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HotkeySettings())
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        Task { @MainActor in
            var out: [String] = []
            func line(_ s: String) { out.append(s) }
            func recorders(in view: NSView) -> [ShortcutRecorder.RecorderButton] {
                ((view as? ShortcutRecorder.RecorderButton).map { [$0] } ?? []) + view.subviews.flatMap(recorders)
            }
            func key(_ flags: NSEvent.ModifierFlags, _ code: UInt16, _ type: NSEvent.EventType = .keyDown) -> NSEvent? {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: "",
                                 charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
            }
            try? await Task.sleep(for: .milliseconds(500))
            let buttons = recorders(in: window.contentView!)
            line("recorders: \(buttons.map(\.debugTitle))")
            guard let up = buttons.first else { return finish(dir, out + ["no recorder"]) }
            up.performClick(nil)
            try? await Task.sleep(for: .milliseconds(300))
            guard let model = up.debugModel else { return finish(dir, out + ["editor did not open"]) }
            line("opened: shown \(up.debugShown) title \(up.debugTitle); starts as \(model.combo?.display ?? "-")")
            model.control = false; model.option = false; model.shift = false; model.command = false
            model.typed("+")
            line("plus: key \(model.keyText) shift \(model.shift) combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.control = true
            line("plus with ⌃: combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.control = false; model.shift = false
            model.typed("k")
            line("bare k: combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.typed("kj")
            line("typed kj: key \(model.keyText)")
            model.choose(UInt16(kVK_F6))
            line("F6 alone: combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.typed("éé")
            line("not on keyboard: problem \(model.problem ?? "-")")
            if let down = key([.control, .option], 58, .flagsChanged), let upEvent = key([], 58, .flagsChanged) {
                _ = model.handle(down); _ = model.handle(upEvent)
            }
            line("modifiers with no key: hint \(model.showHint)")
            if let event = key([.control, .option], 46) { line("press ⌃⌥M used: \(model.handle(event))") }
            line("pressed: combo \(model.combo?.display ?? "-") moves from \(model.movesFrom) hint \(model.showHint)")
            model.command = true; model.control = false; model.option = false
            model.choose(UInt16(kVK_Space))
            line("⌘Space: system \(model.systemUse ?? "-")")
            model.command = false; model.control = true; model.option = true
            model.choose(46)
            try? await Task.sleep(for: .milliseconds(300))
            if let view = up.debugPopoverView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("editor.png"))
                line("shot \(Int(view.bounds.width))x\(Int(view.bounds.height))")
            }
            model.finish?(.set(model.combo))
            try? await Task.sleep(for: .milliseconds(1500))
            line("after Set: up \(store.hotKeyUp?.display ?? "none") down \(store.hotKeyDown?.display ?? "none") mute \(store.hotKeyMute?.display ?? "none"); titles \(buttons.map(\.debugTitle)); editor open \(up.debugModel != nil) shown \(up.debugShown)")
            up.performClick(nil)
            try? await Task.sleep(for: .milliseconds(300))
            if let model = up.debugModel {
                if let esc = key([], UInt16(kVK_Escape)) { _ = model.handle(esc) }
                try? await Task.sleep(for: .milliseconds(1500))
                line("Esc: up \(store.hotKeyUp?.display ?? "none"); editor open \(up.debugModel != nil)")
            }
            up.performClick(nil)
            try? await Task.sleep(for: .milliseconds(300))
            if let model = up.debugModel {
                line("Clear enabled: \(model.original != nil)")
                model.finish?(.set(nil))
                try? await Task.sleep(for: .milliseconds(1500))
                line("after Clear: up \(store.hotKeyUp?.display ?? "none"); title \(up.debugTitle)")
            }
            finish(dir, out)
        }
        return true
    }

    @MainActor
    private static func finish(_ dir: URL, _ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
