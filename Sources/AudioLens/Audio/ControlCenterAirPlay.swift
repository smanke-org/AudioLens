import AppKit
import CoreAudio
import ApplicationServices
import Observation

/// An accessibility attribute's value, or nil.
nonisolated func axAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return v
}

/// Which AirPlay speaker macOS plays to, read and changed through Control Center.
///
/// macOS gives other apps a single "AirPlay" output and keeps the choice of speaker behind it
/// to itself. Control Center's Sound module lists every output as a toggle (identifier
/// "sound-device-<name>"), so AudioLens opens it, reads or presses one through Accessibility,
/// and closes it again. On macOS 27 the Mac's sound goes to one AirPlay speaker at a time:
/// pressing another switches to it (confirmed by hand in Control Center too).
/// Control Center appears for about a second while it does. This is automation of Apple's
/// own interface: if a macOS update moves things, AudioLens says so and offers Sound settings.
@Observable
@MainActor
final class AirPlaySpeakers {
    static let shared = AirPlaySpeakers()

    /// Every output Control Center lists, and whether it's checked, from the last look.
    private(set) var checked: [String: Bool] = [:]
    /// The order Control Center lists them in.
    private(set) var order: [String] = []
    private(set) var working = false
    private(set) var lastError: String?
    private(set) var lastRead: Date?

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's prompt to allow Accessibility for AudioLens.
    func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The AirPlay speakers currently checked, in Control Center's order.
    var checkedAirPlay: [String] {
        let wired = Set(OutputDevices.shared.devices.filter { $0.transport != kAudioDeviceTransportTypeAirPlay }.map(\.name))
        return order.filter { checked[$0] == true && !wired.contains($0) }
    }

    /// Looks at Control Center's list again.
    func refresh() {
        run(select: nil, read: true)
    }

    /// Plays to one AirPlay speaker (macOS plays to one at a time), or, with nil, turns AirPlay
    /// off by going back to the Mac's first wired or built-in output.
    func select(_ name: String?) {
        run(select: .some(name), read: false)
    }

    /// The AirPlay speaker playing now, if any.
    var current: String? { checkedAirPlay.first }

    // MARK: - Working Control Center

    private func run(select target: String??, read: Bool) {
        guard !working else { return }
        guard isTrusted else {
            lastError = "AudioLens needs Accessibility permission to choose AirPlay speakers."
            return
        }
        working = true
        lastError = nil
        // Name the AirPlay output after the speaker it will play to, for its saved volume and EQ.
        if case .some(.some(let name)) = target { OutputDevices.shared.pendingAirPlay = (name, Date()) }
        Task {
            defer { working = false }
            do {
                let result = try await session(select: target)
                checked = result.states
                order = result.order
                lastRead = Date()
                nameCurrentAirPlay()
            } catch {
                lastError = (error as? CCError)?.message ?? error.localizedDescription
                NSLog("AudioLens: Control Center: \(lastError ?? "")")
            }
        }
    }

    /// Gives the connected AirPlay output the name of the speakers it's playing to.
    private func nameCurrentAirPlay() {
        let names = checkedAirPlay
        guard !names.isEmpty else { return }
        OutputDevices.shared.pendingAirPlay = (names.joined(separator: " + "), Date())
        for device in OutputDevices.shared.devices where device.transport == kAudioDeviceTransportTypeAirPlay {
            SettingsStore.shared.nameAirPlayDevice(device.uid, as: names.joined(separator: " + "))
        }
        OutputDevices.shared.refresh()
    }

    struct CCError: Error { let message: String }

    /// Opens Control Center, opens Sound's list, makes the changes, reads the result, closes.
    private func session(select target: String??) async throws -> (states: [String: Bool], order: [String]) {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            throw CCError(message: "Control Center isn't running.")
        }
        let agentApp = AXUIElementCreateApplication(agent.processIdentifier)
        guard let menuItem = Self.find(in: agentApp, depth: 5, where: { axAttr($0, "AXIdentifier") as? String == "com.apple.menuextra.controlcenter" }) else {
            throw CCError(message: "Control Center isn't in the menu bar.")
        }
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            throw CCError(message: "Control Center isn't running.")
        }
        let ccApp = AXUIElementCreateApplication(cc.processIdentifier)

        AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        defer { AXUIElementPerformAction(menuItem, kAXPressAction as CFString) }

        // The Sound module, then its list of outputs.
        guard let sound = try await poll({ Self.findInWindows(ccApp) { axAttr($0, "AXIdentifier") as? String == "controlcenter-volume" } }) else {
            throw CCError(message: "Control Center has no Sound module. Add Sound back in System Settings › Control Center.")
        }
        var actions: CFArray?
        AXUIElementCopyActionNames(sound, &actions)
        let details = (actions as? [String])?.first { $0.contains("show details") } ?? kAXPressAction
        AXUIElementPerformAction(sound, details as CFString)
        guard try await poll({ Self.outputs(ccApp).isEmpty ? nil : true }) != nil else {
            throw CCError(message: "Control Center's list of outputs didn't open.")
        }

        if case .some(let name) = target {
            var rows = Self.outputs(ccApp)
            let wanted = name ?? rows.first { !Self.isAirPlayName($0.name) }?.name
            // Apple TVs, Macs and TVs sit under "Show More".
            if let wanted, !rows.contains(where: { $0.name == wanted }),
               let more = Self.findInWindows(ccApp, where: { (axAttr($0, kAXDescriptionAttribute) as? String)?.localizedCaseInsensitiveContains("show more") == true
                    || (axAttr($0, kAXTitleAttribute) as? String)?.localizedCaseInsensitiveContains("show more") == true }) {
                AXUIElementPerformAction(more, kAXPressAction as CFString)
                _ = try await poll({ Self.outputs(ccApp).contains { $0.name == wanted } ? true : nil })
                rows = Self.outputs(ccApp)
            }
            guard let wanted, let row = rows.first(where: { $0.name == wanted }) else {
                throw CCError(message: "Control Center doesn't list \(name ?? "a non-AirPlay output") right now.")
            }
            if !row.checked { AXUIElementPerformAction(row.element, kAXPressAction as CFString) }
            // AirPlay takes a moment to connect.
            try await Task.sleep(for: .milliseconds(1200))
        }
        let list = Self.outputs(ccApp)
        return (Dictionary(list.map { ($0.name, $0.checked) }, uniquingKeysWith: { a, _ in a }), list.map(\.name))
    }

    /// Whether a Control Center output is an AirPlay speaker rather than a wired or Bluetooth one.
    private static func isAirPlayName(_ name: String) -> Bool {
        !OutputDevices.shared.devices.contains { $0.name == name && $0.transport != kAudioDeviceTransportTypeAirPlay }
    }

    /// Calls `body` every 100 ms for up to 2 seconds until it returns something.
    private func poll<T>(_ body: () -> T?) async throws -> T? {
        for _ in 0..<20 {
            if let value = body() { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func outputs(_ ccApp: AXUIElement) -> [(name: String, checked: Bool, element: AXUIElement)] {
        var result: [(String, Bool, AXUIElement)] = []
        for window in (axAttr(ccApp, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            collect(window, depth: 0) { e in
                guard let id = axAttr(e, "AXIdentifier") as? String, id.hasPrefix("sound-device-") else { return false }
                let name = axAttr(e, kAXDescriptionAttribute) as? String ?? String(id.dropFirst("sound-device-".count))
                let on = (axAttr(e, kAXValueAttribute) as? NSNumber)?.boolValue ?? false
                result.append((name, on, e))
                return true
            }
        }
        return result.map { (name: $0.0, checked: $0.1, element: $0.2) }
    }

    private static func findInWindows(_ app: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        for window in (axAttr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if let hit = find(in: window, depth: 18, where: match) { return hit }
        }
        return nil
    }

    private static func find(in e: AXUIElement, depth: Int, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(e) { return e }
        guard depth > 0 else { return nil }
        for key in [kAXChildrenAttribute, "AXExtrasMenuBar"] {
            if key == "AXExtrasMenuBar" {
                if let bar = axAttr(e, key), CFGetTypeID(bar) == AXUIElementGetTypeID(),
                   let hit = find(in: bar as! AXUIElement, depth: depth - 1, where: match) { return hit }
                continue
            }
            for k in (axAttr(e, key) as? [AXUIElement]) ?? [] {
                if let hit = find(in: k, depth: depth - 1, where: match) { return hit }
            }
        }
        return nil
    }

    /// Visits elements; `body` returns true to stop descending into one.
    private static func collect(_ e: AXUIElement, depth: Int, _ body: (AXUIElement) -> Bool) {
        if body(e) || depth > 18 { return }
        for k in (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { collect(k, depth: depth + 1, body) }
    }
}
