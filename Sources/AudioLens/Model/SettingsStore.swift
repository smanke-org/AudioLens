import AudioLensKit
import CoreAudio
import Foundation
import Observation

/// Everything AudioLens remembers, in UserDefaults.
///
/// Synced between Macs (see `SettingsSync.syncedKeys`): app volumes, mutes, pins, ignores and
/// outputs; each device's EQ, headphone correction, and restore/lock choices; the options and
/// hotkeys. Kept on each Mac: the last volume of each device (a HomePod in one room shouldn't
/// move another Mac's level) and the window layout, since screens differ.
@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    enum Key {
        static let apps = "apps"
        static let devices = "devices"
        static let allowBoost = "allowBoost"
        static let showPinned = "showPinnedWhenSilent"
        static let showMeters = "showMeters"
        static let volumeStep = "volumeStep"
        static let hotKeyUp = "hotKey.volumeUp"
        static let hotKeyDown = "hotKey.volumeDown"
        static let hotKeyMute = "hotKey.mute"
        // Per Mac.
        static let deviceVolumes = "deviceVolumes"
        static let deviceTrims = "deviceTrims"
        static let recentApps = "recentApps"
        static let airPlayNames = "airPlayNames"
        static let outputGroup = "outputGroup"
        static let carryLevel = "carryLevelInDeviceVolume"
        static let layout = "windowLayout"
        static let compact = "windowCompact"
    }

    /// Settings that follow the user between Macs.
    static let syncedKeys = [Key.apps, Key.devices, Key.allowBoost, Key.showPinned, Key.showMeters, Key.carryLevel,
                             Key.volumeStep, Key.hotKeyUp, Key.hotKeyDown, Key.hotKeyMute]

    private(set) var apps: [String: AppAudioSettings] = [:]
    private(set) var devices: [String: DeviceSettings] = [:]
    private(set) var deviceVolumes: [String: Double] = [:]
    /// Apps that have played on this Mac, by bundle id, until the user removes them.
    private(set) var recentApps: [String: RecentApp] = [:]

    struct RecentApp: Codable, Equatable {
        var name: String
        var lastPlayed: Date
    }

    var allowBoost = true { didSet { save(allowBoost, Key.allowBoost, oldValue != allowBoost); if !allowBoost { capBoosts() } } }
    var showPinnedWhenSilent = true { didSet { save(showPinnedWhenSilent, Key.showPinned, oldValue != showPinnedWhenSilent) } }
    var showMeters = true { didSet { save(showMeters, Key.showMeters, oldValue != showMeters) } }
    /// Keep the device's own volume at the loudest adjusted app's level, so quitting AudioLens
    /// doesn't make apps jump louder.
    var carryLevelInDeviceVolume = true {
        didSet {
            save(carryLevelInDeviceVolume, Key.carryLevel, oldValue != carryLevelInDeviceVolume)
            if oldValue != carryLevelInDeviceVolume, !loading { AudioEngine.shared.settingsChanged(appID: nil) }
        }
    }
    /// How far one hotkey press moves a volume, 0.01…0.25.
    var volumeStep = 0.05 { didSet { save(volumeStep, Key.volumeStep, oldValue != volumeStep) } }
    var hotKeyUp: Shortcut? = SettingsStore.defaultUp { didSet { saveShortcut(hotKeyUp, Key.hotKeyUp, oldValue != hotKeyUp) } }
    var hotKeyDown: Shortcut? = SettingsStore.defaultDown { didSet { saveShortcut(hotKeyDown, Key.hotKeyDown, oldValue != hotKeyDown) } }
    var hotKeyMute: Shortcut? = SettingsStore.defaultMute { didSet { saveShortcut(hotKeyMute, Key.hotKeyMute, oldValue != hotKeyMute) } }

    var layout = WindowLayout.standard { didSet { if oldValue != layout { defaults.set(layout.rawValue, forKey: Key.layout) } } }
    var compact = false { didSet { if oldValue != compact { defaults.set(compact, forKey: Key.compact) } } }

    static let defaultUp = Shortcut(keyCode: KeyCode.up, modifiers: [.control, .option], key: "↑")
    static let defaultDown = Shortcut(keyCode: KeyCode.down, modifiers: [.control, .option], key: "↓")
    static let defaultMute = Shortcut(keyCode: 46, modifiers: [.control, .option], key: "M")

    var maxVolume: Double { allowBoost ? AppAudioSettings.maxBoost : 1 }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var loading = false

    private init() { load() }

    func reload() { load() }

    private func load() {
        loading = true
        defer { loading = false }
        let decoder = JSONDecoder()
        apps = (defaults.data(forKey: Key.apps)).flatMap { try? decoder.decode([String: AppAudioSettings].self, from: $0) } ?? [:]
        devices = (defaults.data(forKey: Key.devices)).flatMap { try? decoder.decode([String: DeviceSettings].self, from: $0) } ?? [:]
        deviceVolumes = defaults.dictionary(forKey: Key.deviceVolumes) as? [String: Double] ?? [:]
        airPlayNames = defaults.dictionary(forKey: Key.airPlayNames) as? [String: String] ?? [:]
        output = defaults.data(forKey: Key.outputGroup).flatMap { try? decoder.decode(OutputGroup.self, from: $0) } ?? OutputGroup()
        recentApps = defaults.data(forKey: Key.recentApps).flatMap { try? decoder.decode([String: RecentApp].self, from: $0) } ?? [:]
        allowBoost = defaults.object(forKey: Key.allowBoost) as? Bool ?? true
        showPinnedWhenSilent = defaults.object(forKey: Key.showPinned) as? Bool ?? true
        showMeters = defaults.object(forKey: Key.showMeters) as? Bool ?? true
        carryLevelInDeviceVolume = defaults.object(forKey: Key.carryLevel) as? Bool ?? true
        volumeStep = min(max(defaults.object(forKey: Key.volumeStep) as? Double ?? 0.05, 0.01), 0.25)
        hotKeyUp = shortcut(Key.hotKeyUp, default: Self.defaultUp)
        hotKeyDown = shortcut(Key.hotKeyDown, default: Self.defaultDown)
        hotKeyMute = shortcut(Key.hotKeyMute, default: Self.defaultMute)
        layout = defaults.string(forKey: Key.layout).flatMap(WindowLayout.init) ?? .standard
        compact = defaults.bool(forKey: Key.compact)
    }

    /// A stored shortcut; an empty Data means the user cleared it.
    private func shortcut(_ key: String, default value: Shortcut) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return value }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? value
    }

    /// The whole synced set, defaults included, for SettingsSync.
    var snapshot: [String: Any] {
        let encoder = JSONEncoder()
        func data<T: Encodable>(_ v: T) -> Data { (try? encoder.encode(v)) ?? Data() }
        return [
            Key.apps: data(apps.filter { !$0.key.hasPrefix("pid:") }), Key.devices: data(devices), Key.allowBoost: allowBoost,
            Key.showPinned: showPinnedWhenSilent, Key.showMeters: showMeters, Key.volumeStep: volumeStep,
            Key.carryLevel: carryLevelInDeviceVolume,
            Key.hotKeyUp: hotKeyUp.map(data) ?? Data(), Key.hotKeyDown: hotKeyDown.map(data) ?? Data(),
            Key.hotKeyMute: hotKeyMute.map(data) ?? Data(),
        ]
    }

    // MARK: - Apps

    func app(_ id: String) -> AppAudioSettings { apps[id] ?? AppAudioSettings() }

    func updateApp(_ id: String, _ change: (inout AppAudioSettings) -> Void) {
        var s = app(id)
        change(&s)
        s.volume = min(max(s.volume, 0), maxVolume)
        guard s != apps[id] else { return }
        // Nothing worth keeping: drop the entry rather than store defaults for every app ever heard.
        if s == AppAudioSettings(name: s.name) { apps[id] = nil } else { apps[id] = s }
        saveApps()
        AudioEngine.shared.settingsChanged(appID: id)
    }

    private func saveApps() {
        // Tools without a bundle identifier are known only by a process number that changes
        // every run, so their settings last only as long as the process.
        let lasting = apps.filter { !$0.key.hasPrefix("pid:") }
        defaults.set((try? JSONEncoder().encode(lasting)) ?? Data(), forKey: Key.apps)
        if !loading { SettingsSync.shared.localDidChange() }
    }

    private func capBoosts() {
        guard !loading else { return }
        var changed = false
        for (id, s) in apps where s.volume > 1 {
            apps[id]?.volume = 1
            changed = true
        }
        if changed {
            saveApps()
            AudioEngine.shared.settingsChanged(appID: nil)
        }
    }

    // MARK: - Recent apps

    /// Notes that an app is playing. Written at most once a minute per app, since it's called
    /// every second while something plays.
    func notePlayed(_ id: String, name: String) {
        guard !id.hasPrefix("pid:") else { return }
        if let known = recentApps[id], known.name == name, Date().timeIntervalSince(known.lastPlayed) < 60 { return }
        recentApps[id] = RecentApp(name: name, lastPlayed: Date())
        saveRecent()
    }

    func forgetRecent(_ id: String) {
        guard recentApps.removeValue(forKey: id) != nil else { return }
        saveRecent()
    }

    private func saveRecent() {
        defaults.set((try? JSONEncoder().encode(recentApps)) ?? Data(), forKey: Key.recentApps)
    }

    // MARK: - Devices

    /// Where a device's settings are kept. For most devices that's its UID. An AirPlay
    /// speaker shows up as a generic "AirPlay" device whose UID changes with every connection,
    /// so it's kept by the speaker's name ("airplay:Bedroom") when AudioLens connected it,
    /// and under one shared "airplay:AirPlay" otherwise. Keys that aren't UIDs pass through.
    func memoryKey(_ uid: String) -> String {
        if uid.hasPrefix(Self.airPlayKeyPrefix) { return uid }
        if let name = airPlayNames[uid] { return Self.airPlayKeyPrefix + name }
        if OutputDevices.shared.device(uid: uid)?.transport == kAudioDeviceTransportTypeAirPlay {
            return Self.airPlayKeyPrefix + "AirPlay"
        }
        return uid
    }

    static let airPlayKeyPrefix = "airplay:"

    /// The speaker each AirPlay connection was made for, by its current UID (per Mac).
    private(set) var airPlayNames: [String: String] = [:]

    func nameAirPlayDevice(_ uid: String, as name: String) {
        guard airPlayNames[uid] != name else { return }
        // Only the current connection matters; older UIDs never come back.
        airPlayNames = [uid: name]
        defaults.set(airPlayNames, forKey: Key.airPlayNames)
    }

    func device(_ uid: String) -> DeviceSettings { devices[memoryKey(uid)] ?? DeviceSettings() }

    func updateDevice(_ uid: String, _ change: (inout DeviceSettings) -> Void) {
        let key = memoryKey(uid)
        var s = device(uid)
        change(&s)
        if key.hasPrefix(Self.airPlayKeyPrefix) { s.airPlay = true }
        guard s != devices[key] else { return }
        let soundChanged = s.eqEnabled != devices[key]?.eqEnabled || s.eqGains != devices[key]?.eqGains
            || s.correction != devices[key]?.correction
        devices[key] = s
        defaults.set((try? JSONEncoder().encode(devices)) ?? Data(), forKey: Key.devices)
        if !loading { SettingsSync.shared.localDidChange() }
        if soundChanged { AudioEngine.shared.eqChanged(deviceUID: key) }
    }

    /// Drops everything remembered about a device that isn't connected.
    func forgetDevice(_ uid: String) {
        let key = memoryKey(uid)
        devices[key] = nil
        deviceVolumes[key] = nil
        defaults.set((try? JSONEncoder().encode(devices)) ?? Data(), forKey: Key.devices)
        defaults.set(deviceVolumes, forKey: Key.deviceVolumes)
        output.members.removeAll { $0 == key }
        SettingsSync.shared.localDidChange()
    }

    func savedVolume(for uid: String) -> Double? { deviceVolumes[memoryKey(uid)] }

    /// How far AudioLens last moved a device's own volume from the user's level, in dB (per Mac).
    func trim(for uid: String) -> Double {
        (defaults.dictionary(forKey: Key.deviceTrims) as? [String: Double])?[memoryKey(uid)] ?? 0
    }

    func saveTrim(_ value: Double, for uid: String) {
        var all = defaults.dictionary(forKey: Key.deviceTrims) as? [String: Double] ?? [:]
        all[memoryKey(uid)] = abs(value) < 0.01 ? nil : value
        defaults.set(all, forKey: Key.deviceTrims)
    }

    func saveVolume(_ value: Double, for uid: String) {
        let key = memoryKey(uid)
        guard abs((deviceVolumes[key] ?? -1) - value) > 0.001 else { return }
        deviceVolumes[key] = value
        defaults.set(deviceVolumes, forKey: Key.deviceVolumes)
    }

    // MARK: - Output group

    /// Several outputs at once (per Mac: the devices differ from Mac to Mac).
    var output = OutputGroup() {
        didSet {
            guard output != oldValue, !loading else { return }
            defaults.set((try? JSONEncoder().encode(output)) ?? Data(), forKey: Key.outputGroup)
            AudioEngine.shared.groupChanged()
        }
    }

    func setInGroup(_ uid: String, _ member: Bool) {
        let key = memoryKey(uid)
        if member, !output.members.contains(key) { output.members.append(key) }
        if !member { output.members.removeAll { $0 == key } }
    }

    func isInGroup(_ uid: String) -> Bool { output.members.contains(memoryKey(uid)) }

    // MARK: - Saving

    private func save(_ value: Any, _ key: String, _ changed: Bool) {
        guard changed, !loading else { return }
        defaults.set(value, forKey: key)
        SettingsSync.shared.localDidChange()
    }

    private func saveShortcut(_ value: Shortcut?, _ key: String, _ changed: Bool) {
        guard changed, !loading else { return }
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
        SettingsSync.shared.localDidChange()
        HotKeys.shared.apply()
    }

    /// Back to how AudioLens started, except where it appears, login, sync and updates.
    func resetToDefaults() {
        for key in Self.syncedKeys { defaults.removeObject(forKey: key) }
        load()
        SettingsSync.shared.localDidChange()
        AudioEngine.shared.settingsChanged(appID: nil)
        AudioEngine.shared.eqChanged(deviceUID: nil)
        HotKeys.shared.apply()
    }
}
