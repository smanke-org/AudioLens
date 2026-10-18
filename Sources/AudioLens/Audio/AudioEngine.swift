import AppKit
import Darwin
import AudioLensKit
import CoreAudio
import Observation

/// An app that's playing, or one the user pinned.
struct AudioApp: Identifiable, Hashable {
    /// The bundle identifier, or "pid:123" for a process without one.
    let id: String
    var name: String
    var bundleID: String?
    var pid: pid_t?
    /// Every Core Audio process object that belongs to it (helpers included).
    var processObjects: [AudioObjectID] = []
    /// Those currently sending audio to an output.
    var playingObjects: [AudioObjectID] = []
    var isRunning: Bool { pid != nil }
    var isPlaying: Bool { !playingObjects.isEmpty }
}

/// Finds the apps that are playing, and gives each one that needs it a `TapPipeline`.
///
/// An app is only tapped while something about it differs from plain macOS output: its
/// volume isn't 100%, it's muted, it's sent to another device, or its device has an EQ or a
/// headphone correction. Everything else is left exactly as macOS plays it. A tapped app stays
/// tapped while it runs, even when silent, so its next sound starts at the right level.
@Observable
@MainActor
final class AudioEngine {
    static let shared = AudioEngine()

    /// Running apps that have Core Audio process objects, by id.
    private(set) var running: [String: AudioApp] = [:]
    /// When each app last played, to keep it listed for a moment after it stops.
    private(set) var lastPlayed: [String: Date] = [:]
    /// Why an app couldn't be tapped, if it couldn't.
    private(set) var failures: [String: String] = [:]
    /// An app needs a tap but macOS hasn't allowed audio capture yet.
    private(set) var waitingForPermission = false
    /// The ids that have a running pipeline.
    private(set) var tapped: Set<String> = []

    @ObservationIgnored private var pipelines: [String: TapPipeline] = [:]
    @ObservationIgnored private var listeners: [CA.Listener] = []
    @ObservationIgnored private var processListeners: [AudioObjectID: CA.Listener] = [:]
    @ObservationIgnored private var teardownAfter: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var asked = false
    @ObservationIgnored private var hasScanned = false
    private let myPID = ProcessInfo.processInfo.processIdentifier
    /// How long an app stays listed after it goes quiet.
    static let lingerSeconds: TimeInterval = 8

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        listeners = [CA.Listener(CA.system, kAudioHardwarePropertyProcessObjectList) { AudioEngine.shared.refresh() }].compactMap { $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AudioEngine.shared.refresh() }
        }
        // A safety net for changes Core Audio doesn't announce, and the linger timeout.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AudioEngine.shared.refresh() }
        }
        refresh()
        startStatusFile()
    }

    /// For testing: with AUDIOLENS_STATUS_FILE set, writes what the engine is doing there twice
    /// a second (permission, tapped apps and their peak levels, failures).
    private func startStatusFile() {
        guard let path = ProcessInfo.processInfo.environment["AUDIOLENS_STATUS_FILE"] else { return }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let engine = AudioEngine.shared
                var taps: [String: Any] = [:]
                for (id, pipeline) in engine.pipelines {
                    taps[id] = ["device": pipeline.deviceUID, "peak": Double(pipeline.processor.takePeak()),
                                "sampleRate": pipeline.sampleRate, "processes": pipeline.processObjects.count]
                }
                let status: [String: Any] = [
                    "permission": "\(CapturePermission.shared.status)",
                    "waitingForPermission": engine.waitingForPermission,
                    "playing": engine.running.values.filter(\.isPlaying).map(\.id),
                    "taps": taps, "failures": engine.failures,
                    "output": OutputDevices.shared.defaultUID ?? "", "outputVolume": OutputDevices.shared.volume ?? -1,
                    "trimDB": OutputDevices.shared.trimDB,
                    "airplayChecked": AirPlaySpeakers.shared.checked, "airplayError": AirPlaySpeakers.shared.lastError ?? "",
                    "devices": OutputDevices.shared.devices.map(\.name),
                    "multiRoom": ["running": MultiRoomStream.shared.running, "delay": MultiRoomStream.shared.delay ?? -1,
                                  "onAirPlay": MultiRoomStream.shared.onAirPlay,
                                  "streamingApps": engine.pipelines.values.filter { $0.feed != nil }.map(\.appID)] as [String: Any],
                    "hardwareVolume": OutputDevices.volume(of: CA.defaultOutputDevice()) ?? -1,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        }
    }

    /// Stops every tap, so each app plays straight to its device again.
    func stopAll() {
        for pipeline in pipelines.values { pipeline.stop() }
        pipelines = [:]
        tapped = []
    }

    // MARK: - What's listed

    /// The apps to show: playing ones (and ones that just stopped), then pinned ones if the
    /// setting allows. Ignored apps are left out.
    var visibleApps: [AudioApp] {
        let store = SettingsStore.shared
        let now = Date()
        var result: [AudioApp] = []
        var seen = Set<String>()
        for app in running.values {
            let s = store.app(app.id)
            guard !s.ignored else { continue }
            let recent = app.isPlaying || now.timeIntervalSince(lastPlayed[app.id] ?? .distantPast) < Self.lingerSeconds
            if recent || (s.pinned && store.showPinnedWhenSilent) {
                result.append(app)
                seen.insert(app.id)
            }
        }
        if store.showPinnedWhenSilent {
            for (id, s) in store.apps where s.pinned && !s.ignored && !seen.contains(id) {
                result.append(AudioApp(id: id, name: s.name ?? Self.name(forBundleID: id), bundleID: id))
            }
        }
        return result.sorted { a, b in
            if isAudible(a) != isAudible(b) { return isAudible(a) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Apps that have played before and aren't playing or listed as pinned now, most recent
    /// first, so their saved volume can be changed ahead of the next time they play.
    var recentApps: [AudioApp] {
        let store = SettingsStore.shared
        let shown = Set(visibleApps.map(\.id))
        return store.recentApps
            .filter { id, _ in !shown.contains(id) && !store.app(id).ignored }
            .sorted { $0.value.lastPlayed > $1.value.lastPlayed }
            .map { id, recent in running[id] ?? AudioApp(id: id, name: recent.name, bundleID: id) }
    }

    /// When an app in the recent list last played.
    func lastPlayedDate(_ id: String) -> Date? { SettingsStore.shared.recentApps[id]?.lastPlayed }

    /// Playing now or within the linger time.
    func isAudible(_ app: AudioApp) -> Bool {
        app.isPlaying || Date().timeIntervalSince(lastPlayed[app.id] ?? .distantPast) < Self.lingerSeconds
    }

    /// Ignored apps, running or not, for Settings.
    var ignoredApps: [AudioApp] {
        SettingsStore.shared.apps.filter { $0.value.ignored }.map { id, s in
            running[id] ?? AudioApp(id: id, name: s.name ?? Self.name(forBundleID: id), bundleID: id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app hotkeys act on: the frontmost app if it's playing, otherwise the one that
    /// started playing most recently.
    var hotKeyTarget: AudioApp? {
        let audible = visibleApps.filter(isAudible)
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let app = audible.first(where: { $0.bundleID == front }) { return app }
        return audible.max { (lastPlayed[$0.id] ?? .distantPast) < (lastPlayed[$1.id] ?? .distantPast) }
    }

    /// The device an app plays to: its chosen one if connected, otherwise the group's first
    /// output while a group is on, otherwise the system output.
    func outputDevice(for appID: String) -> OutputDevice? {
        outputDevices(for: appID).first
    }

    /// Every device an app plays to: its chosen one, the group, or the system output.
    func outputDevices(for appID: String) -> [OutputDevice] {
        let devices = OutputDevices.shared
        if let chosen = devices.device(uid: SettingsStore.shared.app(appID).outputUID) { return [chosen] }
        if SettingsStore.shared.multiRoom.enabled, let mac = macOutput { return [mac] }
        if let group = activeGroup { return group }
        return devices.defaultDevice.map { [$0] } ?? []
    }

    /// While multi-room is on, the Mac's own output the taps run on (and play to, delayed, if
    /// the Mac plays along): the system output unless that's AirPlay, then the built-in one.
    var macOutput: OutputDevice? {
        let devices = OutputDevices.shared
        if let d = devices.defaultDevice, d.transport != kAudioDeviceTransportTypeAirPlay { return d }
        return devices.devices.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? devices.devices.first { $0.transport != kAudioDeviceTransportTypeAirPlay }
    }

    /// Whether an app's sound goes into the multi-room stream (it isn't sent to a device of its own).
    func streams(_ appID: String) -> Bool {
        let store = SettingsStore.shared
        return store.multiRoom.enabled && !store.app(appID).ignored
            && OutputDevices.shared.device(uid: store.app(appID).outputUID) == nil
    }

    /// The multi-room stream's delay changed: the Mac's own output follows it.
    func streamDelayChanged() {
        let delay = MultiRoomStream.shared.macDelay
        for pipeline in pipelines.values { pipeline.setStreamDelay(seconds: delay) }
    }

    /// The outputs of the group, when it's on and at least two of them are connected: the
    /// system output first if it's a member, AirPlay last (it can't be the aggregate's clock
    /// without making the others drift).
    var activeGroup: [OutputDevice]? {
        let store = SettingsStore.shared
        guard store.output.enabled, !store.multiRoom.enabled else { return nil }
        let devices = OutputDevices.shared
        let members = devices.devices.filter { store.output.members.contains(store.memoryKey($0.uid)) }
        guard members.count >= 2 else { return nil }
        return members.sorted { a, b in
            let aAir = a.transport == kAudioDeviceTransportTypeAirPlay, bAir = b.transport == kAudioDeviceTransportTypeAirPlay
            if aAir != bAir { return !aAir }
            if (a.uid == devices.defaultUID) != (b.uid == devices.defaultUID) { return a.uid == devices.defaultUID }
            return store.output.members.firstIndex(of: store.memoryKey(a.uid)) ?? 0 < store.output.members.firstIndex(of: store.memoryKey(b.uid)) ?? 0
        }
    }

    /// The group changed: fine-tuning applies live; anything else rebuilds the taps.
    func groupChanged() {
        let offset = SettingsStore.shared.output.syncOffsetMs
        for pipeline in pipelines.values where pipeline.deviceUIDs.count > 1 { pipeline.setSyncOffset(offset) }
        reconcile()
    }

    func isTapped(_ appID: String) -> Bool { tapped.contains(appID) }

    /// The loudest sample since the last call, for meters; nil when the app isn't tapped.
    func takePeak(_ appID: String) -> Float? { pipelines[appID]?.processor.takePeak() }

    // MARK: - Discovery

    func refresh() {
        let runningApps = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(runningApps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [String: AudioApp] = [:]
        let objects = CA.processObjects()

        for object in objects {
            let pid: pid_t = CA.get(object, kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, pid != myPID else { continue }
            let owner = Self.owningApp(of: pid, in: byPID)
            // Processes without a bundle report an empty string rather than none.
            let processBundle = CA.string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            let bundleID = owner?.bundleIdentifier ?? processBundle
            let path = Self.executablePath(pid)
            // A daemon of macOS's own (historicalaudiod and friends) with no app behind it.
            if owner == nil, let path, ["/usr/libexec/", "/usr/sbin/", "/System/", "/Library/Apple/"].contains(where: path.hasPrefix) { continue }
            let name = owner?.localizedName ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? processBundle?.split(separator: ".").last.map(String.init) ?? "Process \(pid)"
            if Self.isSystemProcess(bundleID: bundleID, name: name) { continue }
            let id = bundleID ?? "pid:\(owner?.processIdentifier ?? pid)"
            var app = found[id] ?? AudioApp(id: id, name: name, bundleID: bundleID, pid: owner?.processIdentifier ?? pid)
            app.processObjects.append(object)
            if CA.get(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 {
                app.playingObjects.append(object)
            }
            found[id] = app
        }

        let now = Date()
        for app in found.values where app.isPlaying {
            lastPlayed[app.id] = now
            SettingsStore.shared.notePlayed(app.id, name: app.name)
        }
        for id in lastPlayed.keys where found[id] == nil { lastPlayed[id] = nil }
        if found != running {
            if ProcessInfo.processInfo.environment["AUDIOLENS_LOG_PROCESSES"] != nil {
                for app in found.values {
                    NSLog("AudioLens: process \(app.id) name=\(app.name) pid=\(app.pid ?? -1) objects=\(app.processObjects) playing=\(app.playingObjects)")
                }
            }
            running = found
            for app in found.values where SettingsStore.shared.apps[app.id] != nil && SettingsStore.shared.app(app.id).name != app.name {
                SettingsStore.shared.updateApp(app.id) { $0.name = app.name }
            }
        }
        watchProcesses(objects)
        hasScanned = started
        reconcile()
    }

    /// Process objects announce when they start or stop playing; listen to each.
    private func watchProcesses(_ objects: [AudioObjectID]) {
        let current = Set(objects)
        for id in processListeners.keys where !current.contains(id) { processListeners[id] = nil }
        for object in objects where processListeners[object] == nil {
            processListeners[object] = CA.Listener(object, kAudioProcessPropertyIsRunningOutput) { AudioEngine.shared.refresh() }
        }
    }

    /// The app a process belongs to: itself if it's an app, otherwise the app responsible for
    /// it (Safari for its WebKit processes, Chrome for its helpers), found the way Activity
    /// Monitor does, falling back to walking up the parent processes.
    static func owningApp(of pid: pid_t, in byPID: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        func isApp(_ app: NSRunningApplication?) -> Bool { app?.bundleURL?.pathExtension == "app" }
        if let direct = byPID[pid], isApp(direct) { return outermost(direct, in: byPID) }
        if let responsible = responsiblePID(pid), let app = byPID[responsible], isApp(app) { return outermost(app, in: byPID) }
        var current = pid
        var visited = Set<pid_t>()
        while current > 1, visited.insert(current).inserted {
            if let app = byPID[current], isApp(app) { return outermost(app, in: byPID) }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
            let parent = info.kp_eproc.e_ppid
            if parent == current { break }
            current = parent
        }
        return byPID[pid]
    }

    /// A helper app inside another app's bundle (Chrome's "Google Chrome Helper.app") belongs
    /// to the outer app, when that's running.
    private static func outermost(_ app: NSRunningApplication, in byPID: [pid_t: NSRunningApplication]) -> NSRunningApplication {
        guard let path = app.bundleURL?.path, let range = path.range(of: ".app/") else { return app }
        let outer = String(path[..<range.lowerBound]) + ".app"
        return byPID.values.first { $0.bundleURL?.path == outer } ?? app
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private typealias ResponsibleFunc = @convention(c) (pid_t) -> pid_t
    nonisolated(unsafe) private static let responsibleFunc: ResponsibleFunc? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunc.self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let f = responsibleFunc else { return nil }
        let r = f(pid)
        return r > 0 && r != pid ? r : nil
    }

    /// Sounds macOS makes itself (Siri, alerts, dictation…), which aren't apps to list or tap.
    static func isSystemProcess(bundleID: String?, name: String) -> Bool {
        let prefixes = ["com.apple.siri", "com.apple.Siri", "com.apple.assistant", "com.apple.audio", "com.apple.coreaudio",
                        "com.apple.mediaremote", "com.apple.systemsound", "com.apple.notificationcenter", "com.apple.NotificationCenter",
                        "com.apple.UserNotifications", "com.apple.usernotifications", "com.apple.speech", "com.apple.dictation",
                        "com.apple.corespeech", "com.apple.CoreSpeech", "com.apple.SpeechRecognitionCore", "com.apple.VoiceControl",
                        "com.apple.accessibility", "com.apple.hearingd", "com.apple.springboard", "com.apple.controlcenter"]
        if let bundleID, prefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        let lower = name.lowercased()
        return ["systemsoundserver", "coreaudiod", "audiomxd", "speechrecognition", "dictationd", "corespeechd", "heard"]
            .contains { lower.hasPrefix($0) }
    }

    static func name(forBundleID id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id.split(separator: ".").last.map(String.init) ?? id
    }

    // MARK: - Taps

    func settingsChanged(appID: String?) {
        // Asked for by the user: if this is the first tap, now is the time to ask for permission.
        if let appID, needsTap(appID), !CapturePermission.shared.isAuthorized, !asked {
            asked = true
            CapturePermission.shared.request()
        }
        reconcile()
    }

    func eqChanged(deviceUID: String?) {
        let store = SettingsStore.shared
        for pipeline in pipelines.values
        where deviceUID == nil || pipeline.deviceUIDs.contains(where: { store.memoryKey($0) == deviceUID }) {
            pipeline.setChain { uid, rate in EQChain(settings: store.device(uid), sampleRate: rate) }
        }
        if let deviceUID, SettingsStore.shared.device(deviceUID).processesSound, !CapturePermission.shared.isAuthorized, !asked {
            asked = true
            CapturePermission.shared.request()
        }
        reconcile()
    }

    func devicesChanged() { reconcile() }
    func defaultOutputChanged() { reconcile() }
    func permissionChanged() { reconcile() }

    private func needsTap(_ appID: String) -> Bool {
        let s = SettingsStore.shared.app(appID)
        guard !s.ignored else { return false }
        if s.changesSound { return true }
        // A group or multi-room plays everything through AudioLens: only a tap can reach
        // several outputs.
        if activeGroup != nil || SettingsStore.shared.multiRoom.enabled { return true }
        guard let device = outputDevice(for: appID) else { return false }
        return SettingsStore.shared.device(device.uid).processesSound
    }

    /// Brings the pipelines in line with what each app needs.
    private func reconcile() {
        let allowed = CapturePermission.shared.isAuthorized
        var waiting = false
        let now = Date()

        // Apps that quit, or no longer need a tap (after a moment, so dragging a slider
        // through 100% doesn't tear down and rebuild).
        for id in pipelines.keys {
            guard let app = running[id], !app.processObjects.isEmpty else {
                remove(id, reason: "quit")
                continue
            }
            if SettingsStore.shared.app(id).ignored {
                remove(id, reason: "ignored")
            } else if needsTap(id) && allowed {
                teardownAfter[id] = nil
            } else if let after = teardownAfter[id] {
                if now >= after { remove(id, reason: "back to normal") }
            } else {
                teardownAfter[id] = now.addingTimeInterval(3)
            }
        }

        for app in running.values where needsTap(app.id) {
            guard allowed else { waiting = true; continue }
            let targets = outputDevices(for: app.id)
            guard !targets.isEmpty else { continue }
            if let pipeline = pipelines[app.id] {
                // Rebuild when the outputs changed, or a process that isn't in the tap started playing.
                let missing = app.playingObjects.contains { !pipeline.processObjects.contains($0) }
                let moved = pipeline.deviceUIDs != targets.map(\.uid) || (pipeline.feed != nil) != streams(app.id)
                guard moved || missing else { continue }
                remove(app.id, reason: moved ? "output changed" : "new process")
            } else if !app.isPlaying && !SettingsStore.shared.app(app.id).changesSound {
                // Only the device's EQ applies, so a silent app can wait until it plays. One with
                // its own volume, mute or output is tapped already, or its first sound would
                // come out at full volume before the tap started.
                continue
            }
            build(app, devices: targets)
        }
        waitingForPermission = waiting
        let ids = Set(pipelines.keys)
        if ids != tapped { tapped = ids }
        updateLevels()
    }

    // MARK: - Levels

    /// Decides how far the system output's own volume should move to carry the app levels
    /// (see `OutputDevices.trimDB`), moves it, and gives every tap its level relative to that.
    ///
    /// The trim follows the loudest app AudioLens adjusts on the system output, so that app
    /// needs no gain of its own. While an app AudioLens isn't adjusting plays there (or one it
    /// ignores), the trim is 0: that app plays at the device volume and must stay at the
    /// user's level. With nothing playing, the trim stays where it is, so silence never moves
    /// the volume.
    private func updateLevels() {
        // Until the first look at what's playing, leave the trim where the last run left it:
        // it already carries the right level, and dropping it would make apps jump louder.
        guard hasScanned else { return }
        let devices = OutputDevices.shared
        let store = SettingsStore.shared
        let defaultUID = devices.defaultUID
        var desired: Double?
        if !store.carryLevelInDeviceVolume || defaultUID == nil || activeGroup != nil || store.multiRoom.enabled {
            // A group's outputs each keep their own volume; carrying a level in one of them
            // would make that one louder or quieter than the rest.
            desired = 0
        } else if !pipelines.values.contains(where: { $0.deviceUID == defaultUID }) {
            desired = 0
        } else {
            let audible = running.values.filter { isAudible($0) && outputDevice(for: $0.id)?.uid == defaultUID }
            if audible.contains(where: { pipelines[$0.id] == nil }) {
                desired = 0
            } else if !audible.isEmpty {
                desired = audible.map { app -> Double in
                    let s = store.app(app.id)
                    return s.muted ? -120 : StereoProcessor.decibels(forVolume: s.volume)
                }.max()
            }
        }
        let trim = desired.map { devices.setTrim($0) } ?? devices.trimDB
        for (id, pipeline) in pipelines {
            let s = store.app(id)
            let carried = pipeline.deviceUIDs.count == 1 && pipeline.deviceUID == defaultUID
            pipeline.setVolume(s.volume, muted: s.muted, trimDB: carried ? trim : 0)
        }
    }

    /// The trim a new tap on a device starts with.
    private func currentTrim(for deviceUID: String) -> Double {
        deviceUID == OutputDevices.shared.defaultUID ? OutputDevices.shared.trimDB : 0
    }

    private func build(_ app: AudioApp, devices: [OutputDevice]) {
        let store = SettingsStore.shared
        let s = store.app(app.id)
        let objects = Array(Set(app.processObjects)).sorted()
        do {
            let pipeline = try TapPipeline(
                appID: app.id, name: app.name, processObjects: objects, devices: devices,
                volume: s.volume, muted: s.muted,
                trimDB: devices.count == 1 ? currentTrim(for: devices[0].uid) : 0,
                syncOffsetMs: store.output.syncOffsetMs,
                feed: streams(app.id) ? MultiRoomStream.shared.feed(for: app.id) : nil,
                chain: { device, rate in EQChain(settings: store.device(device.uid), sampleRate: rate) },
                onRateChange: { AudioEngine.shared.rebuild(app.id) })
            pipelines[app.id] = pipeline
            pipeline.setStreamDelay(seconds: MultiRoomStream.shared.macDelay)
            failures[app.id] = nil
        } catch {
            failures[app.id] = error.localizedDescription
            NSLog("AudioLens: couldn't tap \(app.name): \(error.localizedDescription)")
        }
    }

    private func rebuild(_ id: String) {
        remove(id, reason: "sample rate changed")
        reconcile()
    }

    private func remove(_ id: String, reason: String) {
        guard let pipeline = pipelines.removeValue(forKey: id) else { return }
        pipeline.stop()
        if pipeline.feed != nil { MultiRoomStream.shared.removeFeed(id) }
        teardownAfter[id] = nil
        NSLog("AudioLens: stopped tapping \(id) (\(reason))")
    }
}
