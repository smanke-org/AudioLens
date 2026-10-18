import AppKit
import CoreAudio
import AudioLensKit
import AVFoundation
import AVKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Multi-room AirPlay: the apps AudioLens handles, mixed into one live stream that AudioLens's
/// own player sends to any number of AirPlay speakers at once.
///
/// macOS sends the Mac's own sound to one AirPlay speaker at a time, but an app's player can
/// play to several (Music does), and the player's AirPlay picker allows it. So each app's tap
/// writes its processed audio into a ring (`StreamFeed`); a mixer adds them up in real time
/// and appends the result to an endless WAV that the player reads through a resource loader.
/// AirPlay buffers that stream for a couple of seconds; the delay is measured from the player's
/// position, and the Mac's own speakers (if they play too) are delayed by it to stay in step.
@Observable
@MainActor
final class MultiRoomStream {
    static let shared = MultiRoomStream()

    let player = AVPlayer()
    private(set) var running = false
    /// How long after AudioLens hands audio to the stream the speakers play it, in seconds.
    private(set) var delay: Double?

    @ObservationIgnored private let core = StreamCore()
    @ObservationIgnored private var feeds: [String: StreamFeed] = [:]
    @ObservationIgnored private var meter: Timer?

    var settings: SettingsStore.MultiRoom { SettingsStore.shared.multiRoom }

    func feed(for appID: String) -> StreamFeed {
        if let feed = feeds[appID] { return feed }
        let feed = StreamFeed(ring: MixRing(seconds: 2))
        feed.playsOnMac = macPlays
        feeds[appID] = feed
        core.setFeeds(Array(feeds.values))
        return feed
    }

    func removeFeed(_ appID: String) {
        guard feeds.removeValue(forKey: appID) != nil else { return }
        core.setFeeds(Array(feeds.values))
    }

    /// Follows the settings: starts or stops the stream, and whether the Mac plays along.
    func apply() {
        for feed in feeds.values { feed.playsOnMac = macPlays }
        if settings.enabled, !running { start() }
        if !settings.enabled, running { stop() }
    }

    private func start() {
        running = true
        delay = nil
        core.start()
        let asset = AVURLAsset(url: URL(string: "audiolens-stream://mix/live.wav")!)
        asset.resourceLoader.setDelegate(core, queue: core.queue)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()
        meter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MultiRoomStream.shared.measure() }
        }
        NSLog("AudioLens: multi-room stream started")
    }

    private func stop() {
        running = false
        meter?.invalidate()
        meter = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        core.stop()
        delay = nil
        NSLog("AudioLens: multi-room stream stopped")
    }

    /// The delay is how far the stream's newest audio is ahead of what the player is playing.
    /// Whether the player is playing on the Mac rather than on AirPlay speakers.
    ///
    /// Read from Core Audio: the devices AudioLens's own process is sending sound to, besides
    /// its private tap devices. The player, playing locally, appears there; on AirPlay it
    /// doesn't. (Asking the player itself for its route can deadlock inside AVFoundation.)
    private func playerIsLocal() -> Bool {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(CA.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr,
              object != kAudioObjectUnknown else { return false }
        let devices = CA.array(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput, of: AudioObjectID.self)
        return devices.contains { id in
            !(CA.string(id, kAudioDevicePropertyDeviceUID) ?? "").hasPrefix(OutputDevices.ownUIDPrefix)
        }
    }

    /// How far behind live the speakers should run: AirPlay buffers a couple of seconds.
    static let targetDelay = 3.0
    @ObservationIgnored private var lastCatchUp = Date.distantPast
    @ObservationIgnored private var airPlaySince = Date.distantPast

    /// Whether the player is on AirPlay speakers rather than the Mac.
    private(set) var onAirPlay = false

    private func measure() {
        guard running else { return }
        // The player is never muted: a mute set while it played locally stayed on the HomePods
        // after switching. Instead, while it plays on the Mac, the Mac's direct sound is off.
        let external = !playerIsLocal()
        if external != onAirPlay {
            onAirPlay = external
            if external { airPlaySince = Date() }
            delay = nil
            NSLog("AudioLens: multi-room player is \(external ? "on AirPlay" : "on the Mac")")
            apply()
            AudioEngine.shared.streamDelayChanged()
        }
        let playing = player.currentTime().seconds
        if ProcessInfo.processInfo.environment["AUDIOLENS_LOG_STREAM"] != nil { NSLog("AudioLens: multi-room status=\(player.timeControlStatus.rawValue) reason=\(player.reasonForWaitingToPlay?.rawValue ?? "-") time=\(String(format: "%.2f", playing)) produced=\(String(format: "%.2f", core.producedSeconds)) rate=\(player.rate) likely=\(player.currentItem?.isPlaybackLikelyToKeepUp ?? false) buffered=\(player.currentItem?.loadedTimeRanges.last.map { String(format: "%.1f", CMTimeRangeGetEnd($0.timeRangeValue).seconds) } ?? "-")") }
        guard playing.isFinite, playing > 0.5 else { return }
        let measured = core.producedSeconds - playing + core.mixerLag
        guard measured > 0, measured < 15 else { return }
        // The player falls behind while it switches to AirPlay (it stalled about 5 s in
        // testing) and never catches up on its own, leaving the speakers 10 s behind the apps.
        // Once it's been steady on AirPlay for a while, jump it forward to near live.
        if onAirPlay, measured > Self.targetDelay + 1.5, Date().timeIntervalSince(lastCatchUp) > 20,
           Date().timeIntervalSince(airPlaySince) > 6, player.rate > 0 {
            lastCatchUp = Date()
            let target = CMTime(seconds: core.producedSeconds - Self.targetDelay + core.mixerLag, preferredTimescale: 48000)
            NSLog("AudioLens: multi-room catching up from \(String(format: "%.1f", measured)) s behind")
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            delay = nil
            return
        }
        // Smoothed, so the Mac's delay doesn't wobble with each reading.
        let next = delay.map { $0 * 0.8 + measured * 0.2 } ?? measured
        if abs(next - (delay ?? 0)) > 0.002 || delay == nil {
            delay = next
            AudioEngine.shared.streamDelayChanged()
        }
    }

    /// Whether the Mac's own output plays directly: only with the player on AirPlay and the
    /// Mac wanted too. Until speakers are picked, the player itself is what the Mac hears.
    var macPlays: Bool { onAirPlay && settings.includeMac }

    /// The delay for the Mac's own speakers, in seconds, with the user's fine-tuning; none
    /// while the player isn't on AirPlay.
    var macDelay: Double {
        guard onAirPlay else { return 0 }
        return max(0, (delay ?? Self.targetDelay) + settings.syncOffsetMs / 1000)
    }
}

/// The stream itself, on its own queue: mixes the feeds in real time and serves the WAV.
final class StreamCore: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "AudioLens.multiroom", qos: .userInteractive)
    static let rate = 48000
    /// The mixer stays this far behind real time, so each ring has audio waiting.
    let mixerLag = 0.15
    private let headerSize: Int64 = 44
    private let fakeLength: Int64 = 4_000_000_000

    private var feeds: [StreamFeed] = []
    private var timer: DispatchSourceTimer?
    private var startedAt = Date()
    private var produced: Int64 = 0
    /// PCM bytes (16-bit stereo) from stream byte `base` on.
    private var pcm = Data()
    private var base: Int64 = 0
    private var pending: [AVAssetResourceLoadingRequest] = []
    private let lock = NSLock()
    private var producedSnapshot: Int64 = 0

    var producedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(producedSnapshot) / Double(Self.rate)
    }

    func setFeeds(_ list: [StreamFeed]) {
        queue.async { self.feeds = list }
    }

    func start() {
        queue.async {
            self.startedAt = Date()
            self.produced = 0
            self.pcm = Data()
            self.base = 0
            self.pending = []
            for feed in self.feeds { feed.ring.skipToNewest() }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            for request in self.pending where !request.isFinished { request.finishLoading() }
            self.pending = []
        }
    }

    /// Mixes whatever is due since the last tick, in real time, and feeds waiting requests.
    private func tick() {
        let due = Int64((Date().timeIntervalSince(startedAt) - mixerLag) * Double(Self.rate)) - produced
        guard due > 0 else { return }
        let frames = Int(min(due, Int64(Self.rate)))
        var mix = [Float](repeating: 0, count: frames * 2)
        mix.withUnsafeMutableBufferPointer { out in
            for feed in feeds { feed.ring.mix(into: out.baseAddress!, frames: frames) }
        }
        var bytes = Data(count: frames * 4)
        bytes.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<(frames * 2) {
                let limited = StereoProcessor.softLimit(mix[i], threshold: 0.891)
                p[i] = Int16(max(-1, min(1, limited)) * 32767).littleEndian
            }
        }
        pcm.append(bytes)
        produced += Int64(frames)
        lock.lock(); producedSnapshot = produced; lock.unlock()
        // Keep the last 30 seconds for the player to read back.
        let keep = 30 * Self.rate * 4
        if pcm.count > keep + Self.rate * 4 {
            let drop = pcm.count - keep
            pcm.removeFirst(drop)
            base += Int64(drop)
        }
        serve()
    }

    // MARK: - Resource loader

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = UTType.wav.identifier
            info.contentLength = fakeLength
            info.isByteRangeAccessSupported = true
        }
        if request.dataRequest == nil {
            request.finishLoading()
        } else {
            pending.append(request)
            serve()
        }
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === request }
    }

    private func serve() {
        let produced = headerSize + base + Int64(pcm.count)
        pending.removeAll { request in
            guard !request.isFinished, !request.isCancelled, let data = request.dataRequest else { return true }
            let end = data.requestsAllDataToEndOfResource ? fakeLength : data.requestedOffset + Int64(data.requestedLength)
            var offset = data.currentOffset
            // Far ahead of anything made (a probe of the end of the "file"): silence, done.
            if offset > produced + Int64(Self.rate * 4 * 30) {
                data.respond(with: Data(count: Int(min(end - offset, 65536))))
                request.finishLoading()
                return true
            }
            var sent = 0
            while offset < min(end, produced), sent < 1_048_576 {
                let chunk = bytes(from: offset, upTo: min(end, produced, offset + 262_144))
                guard !chunk.isEmpty else { break }
                data.respond(with: chunk)
                offset += Int64(chunk.count)
                sent += chunk.count
            }
            if offset >= end || (data.requestsAllDataToEndOfResource && offset - data.requestedOffset >= 1_048_576) {
                request.finishLoading()
                return true
            }
            return false
        }
    }

    /// Bytes of the stream: the WAV header, then PCM (silence where it's been trimmed).
    private func bytes(from offset: Int64, upTo end: Int64) -> Data {
        var out = Data()
        var at = offset
        if at < headerSize {
            let header = wavHeader()
            let stop = Int(min(end, headerSize))
            out.append(contentsOf: header[Int(at)..<stop])
            at = Int64(stop)
        }
        guard at < end else { return out }
        let pcmStart = at - headerSize
        if pcmStart < base {
            let gap = Int(min(base, end - headerSize) - pcmStart)
            out.append(Data(count: gap))
            at += Int64(gap)
        }
        guard at < end else { return out }
        let from = Int(at - headerSize - base), to = Int(end - headerSize - base)
        if from < pcm.count { out.append(pcm.subdata(in: pcm.startIndex + from ..< pcm.startIndex + min(to, pcm.count))) }
        return out
    }

    private func wavHeader() -> [UInt8] {
        var h: [UInt8] = []
        func u32(_ v: UInt32) { h += withUnsafeBytes(of: v.littleEndian, Array.init) }
        func u16(_ v: UInt16) { h += withUnsafeBytes(of: v.littleEndian, Array.init) }
        let dataSize = UInt32(truncatingIfNeeded: fakeLength - headerSize)
        h += Array("RIFF".utf8); u32(dataSize &+ 36); h += Array("WAVE".utf8)
        h += Array("fmt ".utf8); u32(16); u16(1); u16(2); u32(UInt32(Self.rate)); u32(UInt32(Self.rate * 4)); u16(4); u16(16)
        h += Array("data".utf8); u32(dataSize)
        return h
    }
}

/// Apple's AirPlay picker for the multi-room stream: check any number of speakers.
struct MultiRoomPicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.player = MultiRoomStream.shared.player
        picker.isRoutePickerButtonBordered = true
        return picker
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// The Multi-room AirPlay switch, speakers, the Mac's own speakers, delay and sync.
struct MultiRoomControls: View {
    var compact = false
    @State private var store = SettingsStore.shared
    @State private var stream = MultiRoomStream.shared
    @State private var engine = AudioEngine.shared

    var body: some View {
        let on = Binding(get: { store.multiRoom.enabled }, set: { store.multiRoom.enabled = $0 })
        Toggle(isOn: on) {
            Text("Multi-room AirPlay")
            if !compact {
                Text("Play on several HomePods or Apple TVs at once, like Music does.")
            }
        }
        .controlSize(compact ? .small : .regular)
        if store.multiRoom.enabled {
            LabeledContent("Speakers") {
                HStack(spacing: 6) {
                    MultiRoomPicker().frame(width: 34, height: 26)
                    Text("Check every speaker to play on").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { store.multiRoom.includeMac }, set: { store.multiRoom.includeMac = $0 })) {
                Text("This Mac's speakers (\(engine.macOutput?.name ?? "this Mac"))")
                Text("Apple's list can't include this Mac, so it's here. Kept in sync with the AirPlay speakers.")
            }
            if store.multiRoom.includeMac {
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { store.multiRoom.syncOffsetMs },
                                              set: { store.multiRoom.syncOffsetMs = ($0 / 10).rounded() * 10; AudioEngine.shared.streamDelayChanged() }),
                               in: -3000...3000)
                            .frame(minWidth: 90)
                        Text(String(format: "%+.0f ms", store.multiRoom.syncOffsetMs)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }
                } label: {
                    Text("Sync")
                    Text("If the Mac sounds ahead of the speakers, move right; behind, move left.")
                }
            }
            Text(statusLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        let delay = stream.delay.map { String(format: "%.1f", $0) }
        if stream.running, !stream.onAirPlay { return "No AirPlay speakers picked yet: use the button above. Until then the Mac plays through the stream, a moment late." }
        let base = delay.map { "Speakers play about \($0) s after the app." } ?? "Starting the stream…"
        return base + " Fine for music and podcasts; send video and call apps to a device of their own (right-click › Play To) to keep them in sync."
    }
}
