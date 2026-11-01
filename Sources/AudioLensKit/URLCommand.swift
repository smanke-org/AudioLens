import Foundation

/// What an `audiolens://` link asks for, from ToolHUD, Shortcuts, a script or another app:
///
///     audiolens://show (or open)              the window
///     audiolens://compact                     the compact panel
///     audiolens://menubar                     the menu bar drop-down
///     audiolens://settings                    Settings
///     audiolens://volume-up                   the playing app up a step, as the hotkey does
///     audiolens://volume-down                 the playing app down a step
///     audiolens://mute                        mute or unmute the playing app
///     audiolens://next-output                 the system output to the next device
///     audiolens://volume?app=<bundle id>&value=<0–150>
///     audiolens://mute?app=<bundle id>&on=<1|0>   (no "on" toggles)
///     audiolens://eq?device=<UID|default>&preset=<name>&on=<1|0>
///
/// `app` may also be `playing`, the app the hotkeys act on, which is also what an omitted
/// `app` means. Other query items (ToolHUD adds `source=toolhud`) are ignored, and an unknown
/// host opens the window.
public enum URLCommand: Equatable, Sendable {
    /// The app a volume or mute link acts on.
    public enum Target: Equatable, Sendable {
        /// The app the hotkeys act on: the frontmost app if it's playing, otherwise the one
        /// that started playing most recently.
        case playing
        /// A bundle identifier, an AudioLens app id or an app's name.
        case app(String)
    }

    /// The three hotkey actions.
    public enum Nudge: Equatable, Sendable { case up, down, mute }

    case showWindow
    case compactPanel
    case menuBarPanel
    case settings
    /// What a hotkey does to the playing app, with the volume indicator.
    case nudge(Nudge)
    case nextOutput
    /// A volume in percent (0 to 150); nil leaves the volume alone.
    case setVolume(Target, percent: Double?)
    /// nil toggles.
    case setMuted(Target, muted: Bool?)
    /// `device` nil or "default" is the system output.
    case eq(device: String?, preset: String?, enabled: Bool?)

    public static let scheme = "audiolens"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .compactMap { item in item.value.map { (item.name, $0) } } ?? [], uniquingKeysWith: { _, b in b })
        let target: Target = query["app"].map { $0 == "playing" ? .playing : .app($0) } ?? .playing
        let on = query["on"].map { $0 == "1" || $0.lowercased() == "true" }

        switch url.host?.lowercased() {
        case "compact": self = .compactPanel
        case "menubar": self = .menuBarPanel
        case "settings": self = .settings
        case "volume-up": self = .nudge(.up)
        case "volume-down": self = .nudge(.down)
        case "next-output": self = .nextOutput
        case "volume": self = .setVolume(target, percent: query["value"].flatMap(Double.init))
        case "mute":
            // Bare, it's the mute hotkey; with an app or on=, it sets that app.
            if query["app"] == nil, on == nil { self = .nudge(.mute) } else { self = .setMuted(target, muted: on) }
        case "eq": self = .eq(device: query["device"], preset: query["preset"], enabled: on)
        default: self = .showWindow
        }
    }
}

/// The next output for `audiolens://next-output`: devices in name order, wrapping around,
/// after the current system output. Virtual and aggregate devices (meeting apps' and
/// recorders' drivers) are skipped unless there's nothing else.
public enum OutputCycle {
    public struct Candidate: Equatable, Sendable {
        public let uid: String
        public let name: String
        /// A virtual or aggregate device.
        public let isVirtual: Bool

        public init(uid: String, name: String, isVirtual: Bool = false) {
            self.uid = uid
            self.name = name
            self.isVirtual = isVirtual
        }
    }

    /// The UID to switch to, or nil if there's no other device.
    public static func next(after current: String?, in devices: [Candidate]) -> String? {
        let real = devices.filter { !$0.isVirtual }
        let pool = (real.isEmpty ? devices : real).sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
        }
        guard !pool.isEmpty else { return nil }
        guard let current, let index = pool.firstIndex(where: { $0.uid == current }) else {
            // The output is a skipped device (or unknown): the first one in order.
            return pool.first { $0.uid != current }?.uid
        }
        let next = pool[(index + 1) % pool.count]
        return next.uid == current ? nil : next.uid
    }
}
