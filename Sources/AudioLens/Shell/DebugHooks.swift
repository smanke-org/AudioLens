#if DEBUG
import AppKit
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
}
#endif
