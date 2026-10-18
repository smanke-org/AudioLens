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
}
#endif
