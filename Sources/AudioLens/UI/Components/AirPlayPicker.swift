import AppKit
import CoreAudio
import Network
import Observation
import SwiftUI

/// An AirPlay speaker found on the network.
struct AirPlaySpeaker: Identifiable, Hashable {
    var id: String { name }
    let name: String
    /// The model the speaker announces, such as "AudioAccessory5,1" (a HomePod mini) or "AppleTV14,1".
    var model: String?

    /// What sort of device it is, for grouping, in the order the groups are shown.
    enum Kind: Int, CaseIterable, Comparable {
        case homePod, appleTV, tv, speaker, mac

        var title: String {
            switch self {
            case .homePod: "HomePods"
            case .appleTV: "Apple TVs"
            case .tv: "TVs"
            case .speaker: "Speakers"
            case .mac: "Macs"
            }
        }

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var kind: Kind {
        let m = (model ?? "").lowercased(), n = name.lowercased()
        if m.hasPrefix("audioaccessory") || n.contains("homepod") { return .homePod }
        if m.hasPrefix("appletv") || n.contains("apple tv") { return .appleTV }
        if m.hasPrefix("mac") || n.contains("macbook") || n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") { return .mac }
        if n.contains(" tv") || n.hasSuffix("tv") || n.contains("television") { return .tv }
        return .speaker
    }

    var symbol: String {
        let m = (model ?? "").lowercased(), n = name.lowercased()
        switch kind {
        case .homePod: return m.hasPrefix("audioaccessory5") || n.contains("homepod mini") ? "homepodmini" : "homepod"
        case .appleTV: return "appletv"
        case .tv: return "tv"
        case .speaker: return "hifispeaker"
        case .mac: return m.hasPrefix("macbook") || n.contains("macbook") ? "laptopcomputer" : "desktopcomputer"
        }
    }
}

/// Finds AirPlay speakers on the network through Bonjour, the way they announce themselves.
///
/// macOS gives apps no way to list or connect AirPlay speakers for the Mac's own sound: the
/// public AirPlay picker only routes a player inside the app, and the system audio route is
/// reserved for Apple's apps. So AudioLens lists what Bonjour shows and sends you to Sound
/// settings to connect, where one click makes the speaker the output. Once connected it's an
/// ordinary output device, and AudioLens remembers its volume and EQ like any other.
@Observable
@MainActor
final class AirPlayBrowser {
    static let shared = AirPlayBrowser()

    private(set) var speakers: [AirPlaySpeaker] = []
    /// Set when macOS refused local network access.
    private(set) var denied = false

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var found: [String: [String: AirPlaySpeaker]] = [:]

    /// Starts browsing, the first time a list that shows speakers appears (so the Local Network
    /// prompt comes when it means something).
    func start() {
        guard browsers.isEmpty else { return }
        for type in ["_airplay._tcp", "_raop._tcp"] {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                NSLog("AudioLens: AirPlay \(type) found \(results.count)")
                let speakers = results.compactMap { Self.speaker(from: $0, type: type) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AirPlayBrowser.shared.update(type, speakers) }
                }
            }
            browser.stateUpdateHandler = { state in
                NSLog("AudioLens: AirPlay browser \(type) \(state)")
                if case .failed = state { DispatchQueue.main.async { MainActor.assumeIsolated { AirPlayBrowser.shared.denied = true } } }
                if case .waiting(let error) = state, case .dns = error {
                    DispatchQueue.main.async { MainActor.assumeIsolated { AirPlayBrowser.shared.denied = true } }
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    nonisolated private static func speaker(from result: NWBrowser.Result, type: String) -> AirPlaySpeaker? {
        guard case .service(let rawName, _, _, _) = result.endpoint else { return nil }
        // RAOP names are "MACADDRESS@Name".
        var name = rawName
        if type == "_raop._tcp", let at = name.firstIndex(of: "@") { name = String(name[name.index(after: at)...]) }
        var model: String?
        if case .bonjour(let txt) = result.metadata { model = txt["model"] ?? txt["am"] }
        return AirPlaySpeaker(name: name, model: model)
    }

    private func update(_ type: String, _ list: [AirPlaySpeaker]) {
        denied = false
        found[type] = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, b in a.model == nil ? b : a })
        var merged: [String: AirPlaySpeaker] = [:]
        for group in found.values {
            for (name, speaker) in group where merged[name]?.model == nil { merged[name] = speaker }
        }
        let this = Host.current().localizedName ?? ""
        let names = Set(merged.keys)
        speakers = merged.values.filter { speaker in
            // Not this Mac, and not the second member of a stereo pair ("Bedroom (2)").
            guard speaker.name != this else { return false }
            if let open = speaker.name.range(of: " (", options: .backwards), speaker.name.hasSuffix(")"),
               names.contains(String(speaker.name[..<open.lowerBound])) { return false }
            return true
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Speakers that aren't already connected as an output.
    var unconnected: [AirPlaySpeaker] {
        let connected = Set(OutputDevices.shared.devices.map { $0.name })
        return speakers.filter { !connected.contains($0.name) }
    }

    /// Opens Sound settings' output list and says which speaker to click.
    func connect(_ name: String?) {
        if let name { OutputDevices.shared.pendingAirPlay = (name, Date()) }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?output") {
            NSWorkspace.shared.open(url)
        }
        ConnectHint.shared.show(name: name)
    }
}

/// A short note floating over Sound settings: which speaker to click.
@MainActor
final class ConnectHint {
    static let shared = ConnectHint()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(name: String?) {
        let text = name.map { "In Sound settings, click “\($0)” under Output." }
            ?? "In Sound settings, click the AirPlay speaker under Output."
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        self.panel = panel
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 12) {
                Image(systemName: "airplay.audio").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("AudioLens then remembers its volume and EQ.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(width: 420, height: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.maxY - 110))
        }
        panel.orderFrontRegardless()
        hide?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    /// Called when a new output appears, to clear the note once the speaker connects.
    func dismiss() {
        hide?.cancel()
        panel?.orderOut(nil)
    }
}

/// The AirPlay button: a menu of speakers on the network; choosing one starts connecting it.
struct AirPlayIcon: View {
    @State private var browser = AirPlayBrowser.shared

    var body: some View {
        Menu {
            let speakers = browser.speakers
            let control = AirPlaySpeakers.shared
            if speakers.isEmpty {
                Text(browser.denied ? "Allow Local Network access for AudioLens to see AirPlay speakers" : "Looking for AirPlay speakers…")
            } else {
                Section(control.isTrusted ? "Play on an AirPlay speaker" : "Connect an AirPlay speaker") {
                    ForEach(speakers) { speaker in
                        Button {
                            if control.isTrusted { control.select(control.isOn(speaker.name) ? nil : speaker.name) } else { browser.connect(speaker.name) }
                        } label: {
                            Label(speaker.name, systemImage: control.isTrusted && control.isOn(speaker.name) ? "checkmark" : speaker.symbol)
                        }
                    }
                }
            }
            Divider()
            Button("Open Sound Settings…") { browser.connect(nil) }
        } label: {
            Image(systemName: "airplay.audio")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("AirPlay: connect a HomePod, Apple TV or other AirPlay speaker")
        .accessibilityLabel("AirPlay speakers")
        .onAppear { browser.start() }
    }
}

/// "Connect…" for an AirPlay speaker that isn't connected.
struct AirPlayConnectButton: View {
    let name: String?
    /// Just an icon, for narrow sidebars.
    var iconOnly = false

    var body: some View {
        Group {
            if iconOnly {
                Button { AirPlayBrowser.shared.connect(name) } label: {
                    Image(systemName: "airplay.audio").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            } else {
                Button("Connect…") { AirPlayBrowser.shared.connect(name) }.controlSize(.small)
            }
        }
        .help("Connect \(name ?? "this speaker"): opens Sound settings, where you click it")
        .accessibilityLabel("Connect \(name ?? "speaker")")
    }
}

extension AirPlayBrowser {
    /// Every speaker on the network, grouped by kind in display order: HomePods, Apple TVs,
    /// TVs, other speakers, then Macs.
    var groupedForList: [(kind: AirPlaySpeaker.Kind, speakers: [AirPlaySpeaker])] {
        Dictionary(grouping: speakers, by: \.kind).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

extension AirPlaySpeakers {
    /// Whether macOS is playing to the speaker. Known exactly after AudioLens has looked in
    /// Control Center; otherwise worked out from the AirPlay output AudioLens named.
    func isOn(_ name: String) -> Bool {
        if let value = checked[name] { return value }
        guard let airPlay = OutputDevices.shared.devices.first(where: { $0.transport == kAudioDeviceTransportTypeAirPlay }) else { return false }
        return airPlay.name.components(separatedBy: " + ").contains(name)
    }

    /// Whether Control Center offers the speaker (Apple TVs, for example, may not be).
    func isOffered(_ name: String) -> Bool { order.isEmpty || order.contains(name) }
}

/// One AirPlay speaker: a checkbox that adds it to or removes it from what macOS plays to.
struct AirPlaySpeakerRow: View {
    let speaker: AirPlaySpeaker
    var compact = false
    @State private var speakers = AirPlaySpeakers.shared

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            DeviceBadge(symbol: speaker.symbol, active: speakers.isOn(speaker.name), size: compact ? 22 : 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(speaker.name).lineLimit(1).truncationMode(.tail)
                if !compact, speakers.isOn(speaker.name) {
                    Text("Playing").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            if speakers.isTrusted {
                let on = speakers.isOn(speaker.name)
                Button {
                    speakers.select(on ? nil : speaker.name)
                } label: {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(speakers.working)
                .help(on ? "Stop playing on \(speaker.name)" : "Play on \(speaker.name) instead")
                .accessibilityLabel("Play on \(speaker.name)")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            } else {
                AirPlayConnectButton(name: speaker.name, iconOnly: compact)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Above the speakers: what this does, a refresh, and the Accessibility request if needed.
struct AirPlayHeaderNote: View {
    @State private var speakers = AirPlaySpeakers.shared

    var body: some View {
        if !speakers.isTrusted {
            VStack(alignment: .leading, spacing: 6) {
                Text("To pick the AirPlay speaker right here, allow AudioLens under Privacy & Security › Accessibility. Without it, Connect opens Sound settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow…") { speakers.requestTrust() }
                    Button("Open Accessibility Settings") { speakers.openAccessibilitySettings() }
                }
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                if speakers.working {
                    ProgressView().controlSize(.small)
                    Text("Changing speakers in Control Center…").font(.caption).foregroundStyle(.secondary)
                } else if let error = speakers.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("macOS plays to one AirPlay speaker at a time; pick it here. To add the Mac's own speakers or another output, use Play on several outputs. Control Center opens for a moment while AudioLens switches.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if speakers.current != nil || OutputDevices.shared.devices.contains(where: { $0.transport == kAudioDeviceTransportTypeAirPlay }) {
                    Button("Turn Off") { speakers.select(nil) }
                        .controlSize(.small)
                        .disabled(speakers.working)
                        .help("Stop AirPlay and go back to the Mac's own output")
                }
                Button {
                    speakers.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(speakers.working)
                .help("Check which speakers are on in Control Center")
            }
        }
    }
}

/// The speakers grouped under small labels, for the compact panel.
struct AirPlaySpeakerRows: View {
    var compact = false
    @State private var browser = AirPlayBrowser.shared

    var body: some View {
        let groups = browser.groupedForList
        AirPlayHeaderNote()
        ForEach(groups, id: \.kind) { group in
            Text(group.kind.title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.speakers) { AirPlaySpeakerRow(speaker: $0, compact: compact) }
        }
        .onAppear { browser.start() }
    }
}
