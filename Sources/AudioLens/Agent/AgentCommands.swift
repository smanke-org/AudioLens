import AppKit
import AudioLensKit
import CoreAudio

/// Everything an agent can do in AudioLens. Add a command here and the CLI, `help`, and the
/// MCP tools all get it. Each `run` is on the main actor and calls the same code as the
/// window's sliders, switches and buttons (AppBindings, DeviceBindings, DeviceEQBindings,
/// OutputDevices, SettingsStore), so the window updates live.
///
/// Apps are named by bundle ID, by name, or as `playing` (the app the hotkeys act on), as the
/// audiolens:// links do. Devices are named by UID, by name, or as `system` (the system output).
/// Writes change what the person hears at once, so the ones that touch sound take --dry-run.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, the system output and its volume, the app the hotkeys act on (`playing`), how many apps are listed, playing and adjusted, whether audio capture is allowed, and whether the group and multi-room AirPlay are on.",
                     example: "audiolens status --json", readOnly: true) { _ in
            let engine = AudioEngine.shared
            let devices = OutputDevices.shared
            let store = SettingsStore.shared
            let listed = engine.visibleApps
            var result: JSONObject = [
                "app": AppInfo.name, "version": AppInfo.version, "testCopy": AgentSocket.isTestRun,
                "permission": AgentSocket.isTestRun ? "not checked (test copy)" : permissionText,
                "waitingForPermission": engine.waitingForPermission,
                "listedApps": listed.count, "playingApps": listed.filter(engine.isAudible).count,
                "adjustedApps": engine.tapped.count, "allowBoost": store.allowBoost,
                "group": store.output.enabled, "groupActive": engine.activeGroup != nil,
                "multiRoom": store.multiRoom.enabled, "windowOpen": MainWindow.shared.isVisible,
            ]
            if let device = devices.defaultDevice {
                result["output"] = device.name
                result["outputUID"] = device.uid
                if let volume = devices.volume { result["outputVolume"] = percent(volume) }
                result["outputMuted"] = devices.muted
            } else {
                result["output"] = AgentSocket.isTestRun ? "none (a test copy reads no devices)" : "none"
            }
            if let target = engine.hotKeyTarget { result["playing"] = target.id }
            return result
        },

        // MARK: Apps

        AgentCommand(name: "apps list", summary: "List the apps AudioLens shows: playing ones and pinned ones, loudest first. --all adds the Recent list and ignored apps. Returns `apps` (id, name, playing, volume in percent, muted, pinned, ignored, output, adjusted, list), `total` and `nextOffset` when there are more.",
                     params: [.init(name: "all", kind: .boolean, help: "also apps in the Recent list and ignored apps"),
                              .init(name: "playing", kind: .boolean, help: "only apps playing now (or a moment ago)"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "audiolens apps list --all --json", readOnly: true) { args in
            let engine = AudioEngine.shared
            var rows = engine.visibleApps.map { appSummary($0, list: "listed") }
            if try args.bool("all") == true {
                rows += engine.recentApps.map { appSummary($0, list: "recent") }
                rows += engine.ignoredApps.map { appSummary($0, list: "ignored") }
            }
            if try args.bool("playing") == true { rows = rows.filter { $0["playing"] as? Bool == true } }
            return try page(rows, args, key: "apps")
        },
        AgentCommand(name: "apps show", summary: "Show one app: its volume, mute, pin, ignore, output, whether AudioLens is adjusting it, and why it couldn't be, if it couldn't.",
                     params: [appParam],
                     example: "audiolens apps show com.apple.Music --json", readOnly: true) { args in
            let app = try findApp(args.required("app"))
            var result = appSummary(app, list: listName(app))
            result["bundleID"] = app.bundleID ?? ""
            result["playsOn"] = AudioEngine.shared.outputDevices(for: app.id).map(\.name)
            return result
        },
        AgentCommand(name: "apps set", summary: "Change an app's volume, mute, output, pin or ignore, as its slider and right-click menu do. Only the options you give change. It changes what the person hears at once: add --dry-run to see the change first.",
                     params: [appParam,
                              .init(name: "volume", kind: .integer, help: "0 to 100, or up to 150 while boost is on (Settings › General). Above 0 also unmutes"),
                              .init(name: "muted", kind: .boolean, help: "true or false"),
                              .init(name: "output", help: "a device's UID or name (see `audiolens outputs list`), or system to follow the system output"),
                              .init(name: "pinned", kind: .boolean, help: "true keeps it listed while it's silent"),
                              .init(name: "ignored", kind: .boolean, help: "true leaves it completely alone; false stops ignoring it"),
                              dryRunParam],
                     example: "audiolens apps set com.apple.Music --volume 40 --json") { args in
            let app = try findApp(args.required("app"))
            let store = SettingsStore.shared
            let before = store.app(app.id)
            var after = before
            if args.string("volume") != nil {
                let volume = try args.int("volume", default: 0)
                let max = Int((store.maxVolume * 100).rounded())
                guard (0...max).contains(volume) else {
                    throw AgentError.invalid("--volume must be 0 to \(max)" + (store.allowBoost ? "" : " while boost is off (Settings › General)"))
                }
                after.volume = Double(volume) / 100
                if volume > 0 { after.muted = false }
            }
            if let muted = try args.bool("muted") { after.muted = muted }
            if let output = args.string("output") {
                after.outputUID = output.lowercased() == "system" ? nil : try findDevice(output, connectedOnly: true).uid
            }
            if let pinned = try args.bool("pinned") { after.pinned = pinned }
            if let ignored = try args.bool("ignored") {
                after.ignored = ignored
                if ignored { after.pinned = false }
            }
            guard ["volume", "muted", "output", "pinned", "ignored"].contains(where: { args.string($0) != nil }) else {
                throw AgentError.usage("nothing to change. Give --volume, --muted, --output, --pinned or --ignored. Example: audiolens apps set com.apple.Music --volume 40")
            }
            let changes = appChanges(before, after)
            if try args.bool("dry-run") == true {
                return ["dryRun": true, "app": app.id, "name": app.name, "wouldChange": changes]
            }
            // The window's own controls, in the order a person would use them.
            let controls = AppBindings(app: app)
            if after.volume != before.volume { controls.volume.wrappedValue = after.volume }
            if after.muted != store.app(app.id).muted { controls.muted.wrappedValue = after.muted }
            if after.outputUID != before.outputUID { controls.route(to: after.outputUID) }
            if after.ignored != before.ignored {
                if after.ignored { controls.ignore() } else { store.updateApp(app.id) { $0.ignored = false } }
            }
            if after.pinned != store.app(app.id).pinned { controls.togglePin() }
            var result = appSummary(app, list: listName(app))
            result["changed"] = !changes.isEmpty
            return result
        },

        // MARK: Outputs

        AgentCommand(name: "outputs list", summary: "List the output devices, system output first: name, UID, kind, volume in percent, EQ preset, headphone correction, restore and lock, and whether each is in the several-outputs group. --all adds devices AudioLens remembers that aren't connected.",
                     params: [.init(name: "all", kind: .boolean, help: "also remembered devices that aren't connected")],
                     example: "audiolens outputs list --json", readOnly: true) { args in
            let devices = OutputDevices.shared
            let store = SettingsStore.shared
            var rows = devices.devices.map { deviceSummary(uid: $0.uid, name: $0.name, kind: $0.transportName, connected: true) }
            if try args.bool("all") == true {
                let connected = Set(devices.devices.map { store.memoryKey($0.uid) })
                for (key, s) in store.devices.sorted(by: { $0.key < $1.key }) where !connected.contains(key) {
                    rows.append(deviceSummary(uid: key, name: s.name ?? key, kind: s.airPlay ? "AirPlay" : "Audio device", connected: false))
                }
            }
            return ["outputs": rows, "total": rows.count]
        },
        AgentCommand(name: "outputs set", summary: "Change a device's volume, mute (system output only), EQ, restore or lock, as Device Inspector does. A device that isn't connected gets the volume when it next connects. It changes what the person hears at once: add --dry-run to see the change first.",
                     params: [deviceParam,
                              .init(name: "volume", kind: .integer, help: "0 to 100"),
                              .init(name: "muted", kind: .boolean, help: "true or false (the system output only)"),
                              .init(name: "eq", kind: .boolean, help: "true or false: the 10-band EQ on or off"),
                              .init(name: "eq-preset", help: "an EQ preset, which also turns the EQ on: " + EQPreset.all.map(\.name).joined(separator: ", ")),
                              .init(name: "restore", kind: .boolean, help: "true puts its volume back when it becomes the output"),
                              .init(name: "lock", kind: .boolean, help: "true keeps it at its current level"),
                              dryRunParam],
                     example: "audiolens outputs set system --volume 30 --eq-preset \"Late Night\" --json") { args in
            let device = try findDevice(args.required("device"), connectedOnly: false)
            let devices = OutputDevices.shared
            let store = SettingsStore.shared
            let isSystem = device.uid == devices.defaultUID
            guard ["volume", "muted", "eq", "eq-preset", "restore", "lock"].contains(where: { args.string($0) != nil }) else {
                throw AgentError.usage("nothing to change. Give --volume, --muted, --eq, --eq-preset, --restore or --lock. Example: audiolens outputs set system --volume 30")
            }
            var volume: Int?
            if args.string("volume") != nil {
                volume = try args.int("volume", default: 0)
                guard (0...100).contains(volume!) else { throw AgentError.invalid("--volume must be 0 to 100") }
            }
            let muted = try args.bool("muted")
            if muted != nil, !isSystem { throw AgentError.invalid("only the system output can be muted here. Run `audiolens outputs list` to see which device it is") }
            var preset: EQPreset?
            if let name = args.string("eq-preset") {
                guard let match = EQPreset.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw AgentError.invalid("no EQ preset \"\(name)\". Use one of: " + EQPreset.all.map(\.name).joined(separator: ", "))
                }
                preset = match
            }
            let eq = try args.bool("eq"), restore = try args.bool("restore"), lock = try args.bool("lock")
            let s = store.device(device.uid)
            var changes: JSONObject = [:]
            if let volume, volume != devices.volume(forUID: device.uid).map(percent) { changes["volume"] = volume }
            if let muted, muted != devices.muted { changes["muted"] = muted }
            if let preset, preset.gains != s.eqGains || !s.eqEnabled { changes["eqPreset"] = preset.name }
            if let eq, eq != (preset != nil || s.eqEnabled) { changes["eq"] = eq }
            if let restore, restore != s.restoreVolume { changes["restore"] = restore }
            if let lock, lock != s.lockVolume { changes["lock"] = lock }
            if try args.bool("dry-run") == true {
                return ["dryRun": true, "device": device.name, "uid": device.uid, "wouldChange": changes]
            }
            if let volume { devices.setVolume(Double(volume) / 100, forUID: device.uid) }
            if let muted { devices.setSystemMuted(muted) }
            if let preset { DeviceEQBindings(uid: device.uid).apply(preset) }
            if let eq { DeviceEQBindings(uid: device.uid).enabled.wrappedValue = eq }
            if let restore { DeviceBindings(uid: device.uid).restore.wrappedValue = restore }
            if let lock { DeviceBindings(uid: device.uid).lock.wrappedValue = lock }
            var result = deviceSummary(uid: device.uid, name: device.name, kind: device.kind, connected: device.connected)
            result["changed"] = !changes.isEmpty
            return result
        },
        AgentCommand(name: "outputs use", summary: "Make a connected device the system output, as Use as Output does. It moves every app that follows the system output: add --dry-run to see the change first.",
                     params: [deviceParam, dryRunParam],
                     example: "audiolens outputs use \"MacBook Pro Speakers\" --json") { args in
            let device = try findDevice(args.required("device"), connectedOnly: true)
            let devices = OutputDevices.shared
            let changed = device.uid != devices.defaultUID
            if try args.bool("dry-run") == true {
                return ["dryRun": true, "output": device.name, "uid": device.uid, "wouldChange": changed]
            }
            if changed { devices.makeDefault(device.uid) }
            return ["output": device.name, "uid": device.uid, "changed": changed]
        },

        // MARK: Group and multi-room

        AgentCommand(name: "group show", summary: "Show the several-outputs group: whether it's on, whether it's playing (at least two members connected, multi-room AirPlay off), its members, and the sync fine-tuning in milliseconds.",
                     example: "audiolens group show --json", readOnly: true) { _ in groupSummary() },
        AgentCommand(name: "group set", summary: "Turn the several-outputs group on or off, add or remove a member, or fine-tune its sync, as Play on several outputs at once does. While it plays, every app goes through AudioLens: add --dry-run to see the change first.",
                     params: [.init(name: "on", kind: .boolean, help: "true or false"),
                              .init(name: "add", help: "a device to add (UID or name)"),
                              .init(name: "remove", help: "a device to remove (UID or name)"),
                              .init(name: "sync-offset", kind: .integer, help: "-500 to 500 ms, in steps of 10: positive holds the faster outputs back more"),
                              dryRunParam],
                     example: "audiolens group set --on --add \"Bedroom\" --json") { args in
            let store = SettingsStore.shared
            guard ["on", "add", "remove", "sync-offset"].contains(where: { args.string($0) != nil }) else {
                throw AgentError.usage("nothing to change. Give --on, --add, --remove or --sync-offset. Example: audiolens group set --on --add \"Bedroom\"")
            }
            let on = try args.bool("on")
            let add = try args.string("add").map { try findDevice($0, connectedOnly: false) }
            let remove = try args.string("remove").map { try findDevice($0, connectedOnly: false) }
            var offset: Double?
            if args.string("sync-offset") != nil {
                let value = try args.int("sync-offset", default: 0)
                guard OutputGroup.offsetRange.contains(Double(value)) else { throw AgentError.invalid("--sync-offset must be -500 to 500") }
                offset = (Double(value) / 10).rounded() * 10
            }
            var changes: JSONObject = [:]
            if let on, on != store.output.enabled { changes["on"] = on }
            if let add, !store.isInGroup(add.uid) { changes["add"] = add.name }
            if let remove, store.isInGroup(remove.uid) { changes["remove"] = remove.name }
            if let offset, offset != store.output.syncOffsetMs { changes["syncOffsetMs"] = offset }
            if try args.bool("dry-run") == true {
                var result: JSONObject = ["dryRun": true, "wouldChange": changes]
                if store.multiRoom.enabled { result["note"] = "multi-room AirPlay is on; the group waits until it's off" }
                return result
            }
            if let add { store.setInGroup(add.uid, true) }
            if let remove { store.setInGroup(remove.uid, false) }
            if let offset { store.output.syncOffsetMs = offset }
            if let on { store.output.enabled = on }
            var result = groupSummary()
            result["changed"] = !changes.isEmpty
            return result
        },
        AgentCommand(name: "multiroom show", summary: "Show multi-room AirPlay: whether it's on, whether the Mac plays along, the sync fine-tuning, and whether the stream is running and on AirPlay speakers.",
                     example: "audiolens multiroom show --json", readOnly: true) { _ in multiRoomSummary() },
        AgentCommand(name: "multiroom set", summary: "Turn multi-room AirPlay on or off, have the Mac play along, or fine-tune its sync. The speakers themselves are picked by the person in the window (Speakers button): macOS lets only its own picker choose them. It changes what the person hears at once: add --dry-run to see the change first.",
                     params: [.init(name: "on", kind: .boolean, help: "true or false"),
                              .init(name: "include-mac", kind: .boolean, help: "true also plays on this Mac, kept in step"),
                              .init(name: "sync-offset", kind: .integer, help: "-3000 to 3000 ms, in steps of 10: if the Mac sounds ahead of the speakers, a higher number"),
                              dryRunParam],
                     example: "audiolens multiroom set --on --include-mac --json") { args in
            let store = SettingsStore.shared
            guard ["on", "include-mac", "sync-offset"].contains(where: { args.string($0) != nil }) else {
                throw AgentError.usage("nothing to change. Give --on, --include-mac or --sync-offset. Example: audiolens multiroom set --on")
            }
            let on = try args.bool("on"), includeMac = try args.bool("include-mac")
            var offset: Double?
            if args.string("sync-offset") != nil {
                let value = try args.int("sync-offset", default: 0)
                guard (-3000...3000).contains(value) else { throw AgentError.invalid("--sync-offset must be -3000 to 3000") }
                offset = (Double(value) / 10).rounded() * 10
            }
            var changes: JSONObject = [:]
            if let on, on != store.multiRoom.enabled { changes["on"] = on }
            if let includeMac, includeMac != store.multiRoom.includeMac { changes["includeMac"] = includeMac }
            if let offset, offset != store.multiRoom.syncOffsetMs { changes["syncOffsetMs"] = offset }
            if try args.bool("dry-run") == true { return ["dryRun": true, "wouldChange": changes] }
            if let includeMac { store.multiRoom.includeMac = includeMac }
            if let offset {
                store.multiRoom.syncOffsetMs = offset
                AudioEngine.shared.streamDelayChanged()
            }
            if let on { store.multiRoom.enabled = on }
            var result = multiRoomSummary()
            result["changed"] = !changes.isEmpty
            return result
        },

        // MARK: Window

        AgentCommand(name: "window open", summary: "Show AudioLens: the main window (optionally in a layout), the compact panel, Settings (optionally on a pane) or Help. It brings AudioLens to the front.",
                     params: [.init(name: "page", positional: true, help: "main (default), compact, settings or help"),
                              .init(name: "layout", help: "for main: source-list, mixing-desk, dial-board or device-inspector"),
                              .init(name: "pane", help: "for settings: " + SettingsPane.allCases.map(\.rawValue).joined(separator: ", "))],
                     example: "audiolens window open main --layout mixing-desk") { args in
            let page = (args.string("page") ?? "main").lowercased()
            guard ["main", "compact", "settings", "help"].contains(page) else {
                throw AgentError.usage("no page \"\(page)\". Use main, compact, settings or help")
            }
            var layout: WindowLayout?
            if let name = args.string("layout") {
                let wanted = name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
                guard let match = WindowLayout.allCases.first(where: { $0.rawValue.lowercased() == wanted }) else {
                    throw AgentError.usage("no layout \"\(name)\". Use source-list, mixing-desk, dial-board or device-inspector")
                }
                layout = match
            }
            var pane: SettingsPane?
            if let name = args.string("pane") {
                guard let match = SettingsPane(rawValue: name.lowercased()) else {
                    throw AgentError.usage("no Settings pane \"\(name)\". Use " + SettingsPane.allCases.map(\.rawValue).joined(separator: ", "))
                }
                pane = match
            }
            // A test copy shares the installed app's window frames and would browse for AirPlay speakers.
            if AgentSocket.isTestRun { throw AgentError.invalid("a test copy doesn't open windows") }
            switch page {
            case "compact": MainWindow.shared.show(compact: true)
            case "settings": SettingsWindow.shared.show(pane ?? .general)
            case "help": HelpWindow.shared.show()
            default:
                if let layout { MainWindow.shared.setLayout(layout) } else { MainWindow.shared.show(compact: false) }
            }
            return ["opened": page]
        },
    ]

    // MARK: - Params

    static let appParam = AgentCommand.Param(name: "app", required: true, positional: true,
                                             help: "a bundle ID (com.apple.Music), an app's name, or playing for the app the hotkeys act on")
    static let deviceParam = AgentCommand.Param(name: "device", required: true, positional: true,
                                                help: "a device's UID or name (see `audiolens outputs list`), or system for the system output")
    static let dryRunParam = AgentCommand.Param(name: "dry-run", kind: .boolean, help: "only show what would change")

    // MARK: - Finding things

    /// An app by bundle ID, AudioLens id or name, or the playing one, among the apps AudioLens
    /// knows (running, listed, recent, ignored, with settings) and the apps installed.
    @MainActor
    static func findApp(_ key: String) throws -> AudioApp {
        let engine = AudioEngine.shared
        let store = SettingsStore.shared
        if key.lowercased() == "playing" {
            guard let app = engine.hotKeyTarget else { throw AgentError.notFound("nothing is playing. Run `audiolens apps list --all` and name an app") }
            return app
        }
        let known = Array(engine.running.values) + engine.visibleApps + engine.recentApps + engine.ignoredApps
        if let app = known.first(where: { $0.id == key || $0.bundleID == key }) { return app }
        let named = known.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if let app = named.first(where: \.isRunning) ?? named.first { return app }
        if let s = store.apps[key] { return AudioApp(id: key, name: s.name ?? AudioEngine.name(forBundleID: key), bundleID: key) }
        // An installed app that hasn't played yet: its volume is ready for its first sound.
        if key.contains("."), NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) != nil {
            return AudioApp(id: key, name: AudioEngine.name(forBundleID: key), bundleID: key)
        }
        throw AgentError.notFound("no app \"\(key)\". Run `audiolens apps list --all`, or give an installed app's bundle ID")
    }

    struct FoundDevice {
        var uid: String
        var name: String
        var kind: String
        var connected: Bool
    }

    /// A connected device by UID or name, or `system`; with `connectedOnly` false, also a
    /// device AudioLens remembers (by its settings key or name).
    @MainActor
    static func findDevice(_ key: String, connectedOnly: Bool) throws -> FoundDevice {
        let devices = OutputDevices.shared
        let store = SettingsStore.shared
        let lower = key.lowercased()
        if lower == "system" || lower == "default" {
            guard let device = devices.defaultDevice else { throw AgentError.notFound("there's no system output right now. Run `audiolens outputs list`") }
            return FoundDevice(uid: device.uid, name: device.name, kind: device.transportName, connected: true)
        }
        if let device = devices.devices.first(where: { $0.uid == key }) ?? devices.devices.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return FoundDevice(uid: device.uid, name: device.name, kind: device.transportName, connected: true)
        }
        if !connectedOnly, let (k, s) = store.devices.first(where: { $0.key == key })
            ?? store.devices.first(where: { $0.value.name?.caseInsensitiveCompare(key) == .orderedSame }) {
            return FoundDevice(uid: k, name: s.name ?? k, kind: s.airPlay ? "AirPlay" : "Audio device", connected: false)
        }
        throw AgentError.notFound("no \(connectedOnly ? "connected " : "")output \"\(key)\". Run `audiolens outputs list\(connectedOnly ? "" : " --all")`")
    }

    // MARK: - Results

    @MainActor
    static var permissionText: String {
        switch CapturePermission.shared.status {
        case .authorized: "allowed"
        case .denied: "denied"
        case .unknown: "not asked yet"
        }
    }

    static func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }

    @MainActor
    static func listName(_ app: AudioApp) -> String {
        let engine = AudioEngine.shared
        if SettingsStore.shared.app(app.id).ignored { return "ignored" }
        if engine.visibleApps.contains(where: { $0.id == app.id }) { return "listed" }
        if engine.recentApps.contains(where: { $0.id == app.id }) { return "recent" }
        return "none"
    }

    @MainActor
    static func appSummary(_ app: AudioApp, list: String) -> JSONObject {
        let engine = AudioEngine.shared
        let s = SettingsStore.shared.app(app.id)
        var result: JSONObject = [
            "id": app.id, "name": app.name, "running": app.isRunning, "playing": engine.isAudible(app),
            "volume": percent(s.volume), "muted": s.muted, "pinned": s.pinned, "ignored": s.ignored,
            "output": outputName(s.outputUID), "adjusted": engine.isTapped(app.id), "list": list,
        ]
        if let uid = s.outputUID { result["outputUID"] = uid }
        if let problem = engine.failures[app.id] { result["problem"] = problem }
        if list == "recent", let date = engine.lastPlayedDate(app.id) { result["lastPlayed"] = JSON.date(date) }
        return result
    }

    /// "system", or the chosen device's name (marked when it isn't connected).
    @MainActor
    static func outputName(_ uid: String?) -> String {
        guard let uid else { return "system" }
        if let device = OutputDevices.shared.device(uid: uid) { return device.name }
        return (SettingsStore.shared.device(uid).name ?? uid) + " (not connected)"
    }

    static func appChanges(_ before: AppAudioSettings, _ after: AppAudioSettings) -> JSONObject {
        var changes: JSONObject = [:]
        if after.volume != before.volume { changes["volume"] = percent(after.volume) }
        if after.muted != before.muted { changes["muted"] = after.muted }
        if after.outputUID != before.outputUID { changes["outputUID"] = after.outputUID ?? "system" }
        if after.pinned != before.pinned { changes["pinned"] = after.pinned }
        if after.ignored != before.ignored { changes["ignored"] = after.ignored }
        return changes
    }

    @MainActor
    static func deviceSummary(uid: String, name: String, kind: String, connected: Bool) -> JSONObject {
        let devices = OutputDevices.shared
        let store = SettingsStore.shared
        let s = store.device(uid)
        var result: JSONObject = [
            "name": name, "uid": uid, "kind": kind, "connected": connected, "systemOutput": uid == devices.defaultUID,
            "eq": s.eqEnabled, "eqPreset": EQPreset.matching(s.eqGains)?.name ?? "Custom",
            "restoreVolume": s.restoreVolume, "lockVolume": s.lockVolume, "inGroup": store.isInGroup(uid),
        ]
        if let volume = devices.volume(forUID: uid) { result["volume"] = percent(volume) }
        if uid == devices.defaultUID { result["muted"] = devices.muted }
        if let correction = s.correction { result["correction"] = correction.enabled ? correction.name : correction.name + " (off)" }
        return result
    }

    @MainActor
    static func groupSummary() -> JSONObject {
        let store = SettingsStore.shared
        let devices = OutputDevices.shared
        let members: [JSONObject] = store.output.members.map { key in
            let device = devices.devices.first { store.memoryKey($0.uid) == key }
            return ["name": device?.name ?? store.device(key).name ?? key, "uid": device?.uid ?? key, "connected": device != nil]
        }
        var result: JSONObject = ["on": store.output.enabled, "syncOffsetMs": store.output.syncOffsetMs, "members": members,
                                  "playing": AudioEngine.shared.activeGroup != nil, "multiRoomOn": store.multiRoom.enabled]
        if let group = AudioEngine.shared.activeGroup { result["playingOn"] = group.map(\.name) }
        return result
    }

    @MainActor
    static func multiRoomSummary() -> JSONObject {
        let settings = SettingsStore.shared.multiRoom
        var result: JSONObject = ["on": settings.enabled, "includeMac": settings.includeMac, "syncOffsetMs": settings.syncOffsetMs,
                                  "macOutput": AudioEngine.shared.macOutput?.name ?? "none"]
        // A test copy never creates the stream's player.
        if AgentSocket.isTestRun {
            result["running"] = false
        } else {
            let stream = MultiRoomStream.shared
            result["running"] = stream.running
            result["onAirPlay"] = stream.onAirPlay
            if let delay = stream.delay { result["delaySeconds"] = (delay * 10).rounded() / 10 }
        }
        return result
    }

    static func page(_ rows: [JSONObject], _ args: Args, key: String) throws -> JSONObject {
        let limit = try args.int("limit", default: 50), offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be above 0 and --offset 0 or more") }
        let slice = Array(rows.dropFirst(offset).prefix(limit))
        var result: JSONObject = [key: slice, "total": rows.count]
        if offset + slice.count < rows.count { result["nextOffset"] = offset + slice.count }
        return result
    }
}
