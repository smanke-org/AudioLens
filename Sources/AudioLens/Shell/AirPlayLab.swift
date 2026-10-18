import AppKit
import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

/// A test window (AUDIOLENS_AIRPLAY_LAB=<path to a sound file>): does audio AudioLens plays
/// itself reach several AirPlay speakers at once, the way Music's does?
///
/// 1. AVPlayer with a file, as Music plays: the baseline.
/// 2. A tone generated live and fed to AVSampleBufferAudioRenderer, the way captured app
///    audio would have to travel.
///
/// Both follow the app's own AirPlay route, chosen with the picker at the top.
@MainActor
final class AirPlayLab: NSObject {
    static let shared = AirPlayLab()

    private var window: NSWindow?
    let player = AVPlayer()
    let renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private var feeding = false
    private var framesQueued: Int64 = 0
    private let rate = 48000.0
    var log: [String] = []

    func show(file: String) {
        if let url = URL(string: file), url.scheme != nil {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        } else {
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: file)))
        }
        synchronizer.addRenderer(renderer)
        let hosting = NSHostingController(rootView: AirPlayLabView(lab: self))
        let window = NSWindow(contentViewController: hosting)
        window.title = "AirPlay Test"
        window.setContentSize(NSSize(width: 460, height: 360))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Test 1: AVPlayer

    func playFile() {
        player.seek(to: .zero)
        player.play()
        note("AVPlayer playing the test file")
    }

    func stopFile() {
        player.pause()
        note("AVPlayer stopped")
    }

    // MARK: - Test 3: live audio through the player

    private let liveLoader = LiveWAVLoader()

    /// The player plays an endless WAV that's generated as it's read, as captured audio would be.
    func playLiveThroughPlayer() {
        let asset = AVURLAsset(url: URL(string: "audiolens-live://tone/stream.wav")!)
        asset.resourceLoader.setDelegate(liveLoader, queue: liveLoader.queue)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()
        note("Player playing a live, endless stream")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.note("player status \(self.player.currentItem?.status.rawValue ?? -1), error \(self.player.currentItem?.error?.localizedDescription ?? "none"), time \(self.player.currentTime().seconds)")
        }
    }

    // MARK: - Test 2: live samples

    func playLive() {
        guard !feeding else { return }
        feeding = true
        framesQueued = 0
        renderer.flush()
        let queue = DispatchQueue(label: "AirPlayLab.feed")
        renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                while self.feeding, self.renderer.isReadyForMoreMediaData {
                    guard let buffer = self.toneBuffer(frames: 4800) else { break }
                    self.renderer.enqueue(buffer)
                }
            }
        }
        synchronizer.setRate(1, time: .zero)
        note("Live tone started (sample buffer renderer)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.note("renderer status \(self.renderer.status.rawValue), error \(self.renderer.error?.localizedDescription ?? "none"), output \(self.renderer.audioOutputDeviceUniqueID ?? "app route")")
        }
    }

    func stopLive() {
        feeding = false
        synchronizer.setRate(0, time: synchronizer.currentTime())
        renderer.stopRequestingMediaData()
        renderer.flush()
        note("Live tone stopped")
    }

    /// 0.1 s of a 330 Hz tone with a slow pulse, so it's easy to tell from the file's tone.
    private func toneBuffer(frames: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { return nil }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block else { return nil }
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let t = Double(framesQueued + Int64(i)) / rate
            let v = Float(0.25 * sin(2 * .pi * 330 * t) * (0.6 + 0.4 * sin(2 * .pi * 1.5 * t)))
            samples[i * 2] = v
            samples[i * 2 + 1] = v
        }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        let pts = CMTime(value: framesQueued, timescale: CMTimeScale(rate))
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        framesQueued += Int64(frames)
        return sample
    }

    func note(_ s: String) {
        NSLog("AudioLens AirPlayLab: \(s)")
        log.append(s)
        NotificationCenter.default.post(name: .init("AirPlayLabLog"), object: nil)
    }
}

/// The picker, bound to the lab's player.
private struct LabPicker: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.player = player
        return picker
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

private struct AirPlayLabView: View {
    let lab: AirPlayLab
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("1. Choose speakers:").font(.headline)
                LabPicker(player: lab.player).frame(width: 34, height: 28)
                Text("(check several HomePods)").foregroundStyle(.secondary)
            }
            HStack {
                Text("2. Test 1, file (AVPlayer):").frame(width: 200, alignment: .leading)
                Button("Play") { lab.playFile() }
                Button("Stop") { lab.stopFile() }
            }
            HStack {
                Text("3. Test 2, live tone (samples):").frame(width: 200, alignment: .leading)
                Button("Play") { lab.playLive() }
                Button("Stop") { lab.stopLive() }
            }
            HStack {
                Text("4. Test 3, live through player:").frame(width: 200, alignment: .leading)
                Button("Play") { lab.playLiveThroughPlayer() }
                Button("Stop") { lab.stopFile() }
            }
            Text("Test 1 is a steady 440 Hz tone; test 2 a lower pulsing tone; test 3 an even lower, faster-pulsing tone. Note which speakers each plays on, and for test 3 how long after Play it starts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .onReceive(NotificationCenter.default.publisher(for: .init("AirPlayLabLog"))) { _ in lines = lab.log }
    }
}


/// Serves an endless 16-bit stereo 48 kHz WAV of a pulsing 220 Hz tone, made up on demand for
/// whatever byte range the player asks for.
final class LiveWAVLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "AudioLens.liveWAV")
    private let rate = 48000
    private let length: Int64 = 2_000_000_000

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = UTType.wav.identifier
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        if let data = request.dataRequest {
            let start = data.currentOffset
            let wanted = data.requestsAllDataToEndOfResource ? 2 * 1024 * 1024 : data.requestedLength - Int(start - data.requestedOffset)
            let count = max(0, min(wanted, 2 * 1024 * 1024))
            data.respond(with: bytes(from: start, count: count))
            NSLog("AudioLens AirPlayLab: served \(count) bytes at \(start)")
        }
        request.finishLoading()
        return true
    }

    private func bytes(from offset: Int64, count: Int) -> Data {
        var out = Data(count: count)
        let header = wavHeader()
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let pos = offset + Int64(i)
                if pos < 44 { p[i] = header[Int(pos)]; continue }
                let sampleByte = Int(pos - 44)
                let frame = sampleByte / 4
                let t = Double(frame) / Double(rate)
                let v = 0.25 * sin(2 * .pi * 220 * t) * (0.6 + 0.4 * sin(2 * .pi * 2 * t))
                let s = Int16(max(-1, min(1, v)) * 32767)
                let u = UInt16(bitPattern: s)
                // Left and right are the same; little-endian.
                p[i] = (sampleByte % 2 == 0) ? UInt8(u & 0xFF) : UInt8(u >> 8)
            }
        }
        return out
    }

    private func wavHeader() -> [UInt8] {
        var h: [UInt8] = []
        func u32(_ v: UInt32) { h += withUnsafeBytes(of: v.littleEndian, Array.init) }
        func u16(_ v: UInt16) { h += withUnsafeBytes(of: v.littleEndian, Array.init) }
        let dataSize = UInt32(length - 44)
        h += Array("RIFF".utf8); u32(dataSize + 36); h += Array("WAVE".utf8)
        h += Array("fmt ".utf8); u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        h += Array("data".utf8); u32(dataSize)
        return h
    }
}
