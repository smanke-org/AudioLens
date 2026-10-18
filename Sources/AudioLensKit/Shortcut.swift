import Foundation

/// Modifier keys, independent of AppKit and Carbon so they can be stored and tested.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// ⌃⌥⇧⌘, in the order macOS menus use.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A key plus modifiers: a global shortcut.
public struct Shortcut: Codable, Hashable, Sendable {
    /// A macOS virtual key code (kVK_…).
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// How the key itself reads: "T", "Space", "F5", "↩".
    public var key: String

    public init(keyCode: UInt16, modifiers: KeyModifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// "⌃⌥⌘T".
    public var display: String { modifiers.symbols + key }

    /// Same key and modifiers, whatever the stored label says.
    public func sameKeys(as other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    /// ⌃⌥⌘ plus a key: the house style for shortcuts nothing else claims by default.
    public static func controlOptionCommand(_ keyCode: UInt16, _ key: String) -> Shortcut {
        Shortcut(keyCode: keyCode, modifiers: [.control, .option, .command], key: key)
    }



}

/// The virtual key codes this package refers to by name.
public enum KeyCode {
    public static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, h: UInt16 = 4, c: UInt16 = 8, v: UInt16 = 9
    public static let b: UInt16 = 11, w: UInt16 = 13, r: UInt16 = 15, y: UInt16 = 16, t: UInt16 = 17
    public static let u: UInt16 = 32, l: UInt16 = 37, k: UInt16 = 40, n: UInt16 = 45
    public static let returnKey: UInt16 = 36, tab: UInt16 = 48, space: UInt16 = 49, grave: UInt16 = 50
    public static let comma: UInt16 = 43
    public static let delete: UInt16 = 51, escape: UInt16 = 53, forwardDelete: UInt16 = 117
    public static let keypadEnter: UInt16 = 76
    public static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    /// The digit keys 1–9 and 0 along the top row, in that order.
    public static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
}

/// Names for keys whose character doesn't describe them.
public enum KeyNames {
    /// Key code → F-key number. A table, not a range: the codes are scattered (F1 is 122,
    /// F20 is 90).
    private static let fKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    private static let special: [UInt16: String] = [
        KeyCode.returnKey: "↩", KeyCode.keypadEnter: "⌤", KeyCode.tab: "⇥", KeyCode.space: "Space",
        KeyCode.delete: "⌫", KeyCode.forwardDelete: "⌦", KeyCode.escape: "⎋",
        KeyCode.left: "←", KeyCode.right: "→", KeyCode.down: "↓", KeyCode.up: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// Keys a keystroke button can press that can't be typed into a text field, as the
    /// Special Keys menu offers them.
    public static let insertable: [(title: String, token: String)] = [
        ("Return", "↩"), ("Tab", "⇥"), ("Space", "[Space]"), ("Escape", "⎋"), ("Delete", "⌫"),
        ("Forward Delete", "⌦"), ("Left Arrow", "←"), ("Right Arrow", "→"), ("Up Arrow", "↑"),
        ("Down Arrow", "↓"), ("Home", "↖"), ("End", "↘"), ("Page Up", "⇞"), ("Page Down", "⇟"),
    ] + (1...12).map { ("F\($0)", "[F\($0)]") }

    /// The key code for a special key's symbol or name: "↩", "F5", "Space", "Return".
    public static func code(named name: String) -> UInt16? {
        if let hit = special.first(where: { $0.value == name }) { return hit.key }
        if let hit = fKeys.first(where: { "F\($0.value)" == name.uppercased() }) { return hit.key }
        if let token = insertable.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame })?.token,
           token.count == 1 {
            return code(named: token)
        }
        return nil
    }

    /// The label a special key reads as, or nil for an ordinary character key.
    public static func label(of keyCode: UInt16) -> String? {
        if let f = fKeys[keyCode] { return "F\(f)" }
        return special[keyCode]
    }

    /// The label for a key, given the characters it typed without modifiers.
    public static func name(keyCode: UInt16, characters: String?) -> String {
        if let f = fKeys[keyCode] { return "F\(f)" }
        if let s = special[keyCode] { return s }
        let typed = (characters ?? "").trimmingCharacters(in: .controlCharacters)
        return typed.isEmpty ? "Key \(keyCode)" : typed.uppercased()
    }
}

/// Shortcuts macOS itself uses, so choosing one can be warned about.
public enum SystemShortcuts {
    private static let known: [(UInt16, KeyModifiers, String)] = [
        (KeyCode.space, [.command], "Spotlight"),
        (KeyCode.space, [.command, .option], "Finder search"),
        (KeyCode.space, [.control], "switching input sources"),
        (KeyCode.space, [.control, .option], "switching input sources"),
        (KeyCode.space, [.control, .command], "the Character Viewer"),
        (KeyCode.tab, [.command], "switching apps"),
        (12, [.command], "Quit"),
        (KeyCode.w, [.command], "closing windows"),
        (KeyCode.h, [.command], "Hide"),
        (KeyCode.grave, [.command], "switching windows"),
        (20, [.command, .shift], "screenshots"),
        (21, [.command, .shift], "screenshots"),
        (23, [.command, .shift], "screenshots"),
    ]

    /// What macOS uses this shortcut for, if anything.
    public static func purpose(of shortcut: Shortcut) -> String? {
        known.first { $0.0 == shortcut.keyCode && $0.1 == shortcut.modifiers }?.2
    }
}
