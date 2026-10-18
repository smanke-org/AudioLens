import AudioLensKit
import AudioToolbox
import CoreAudio
import Foundation

/// One app's audio, captured and played back through AudioLens:
///
///     app's processes ──tap (muted at the source)──▶ private aggregate device ──▶ output device(s)
///                                                    └ IOProc: volume, EQ, limiter, sync delay
///
/// The tap mutes the app's own output while AudioLens plays the captured copy, so what you
/// hear is the processed sound only. Everything here is private to AudioLens: other apps never
/// see the tap or the aggregate, and both go away if AudioLens quits or crashes.
///
/// With several outputs (a group, such as the laptop and an AirPlay HomePod), the aggregate
/// holds all of them. Each gets its own processor, so each keeps its own EQ, and its own delay:
/// the slowest output plays as soon as it can and the faster ones are held back to match it.
@MainActor
final class TapPipeline {
    let appID: String
    let processObjects: [AudioObjectID]
    /// The outputs, the clock device first.
    let deviceUIDs: [String]
    var deviceUID: String { deviceUIDs[0] }
    let processors: [StereoProcessor]
    /// For meters: the first output's processor.
    var processor: StereoProcessor { processors[0] }
    private let delays: [DelayLine]
    /// Set when the app plays through the multi-room stream: its sound goes to the stream's
    /// ring, and to the Mac's output only if the user wants it there (delayed to match).
    let feed: StreamFeed?
    private let latencies: [Int]
    private(set) var sampleRate: Double = 48000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListener: CA.Listener?

    enum PipelineError: LocalizedError {
        case tap(OSStatus), aggregate(OSStatus), notReady, ioProc(OSStatus), start(OSStatus)
        var errorDescription: String? {
            switch self {
            case .tap(let s): "macOS refused to capture the app's audio (\(s))."
            case .aggregate(let s): "macOS couldn't set up the output (\(s))."
            case .notReady: "The output device didn't start in time."
            case .ioProc(let s), .start(let s): "The output device couldn't start (\(s))."
            }
        }
    }

    init(appID: String, name: String, processObjects: [AudioObjectID], devices: [OutputDevice],
         volume: Double, muted: Bool, trimDB: Double, syncOffsetMs: Double, feed: StreamFeed? = nil,
         chain: (OutputDevice, Double) -> EQChain, onRateChange: @escaping @MainActor () -> Void) throws {
        precondition(!devices.isEmpty)
        self.appID = appID
        self.feed = feed
        self.processObjects = processObjects
        self.deviceUIDs = devices.map(\.uid)
        processors = devices.map { _ in StereoProcessor() }
        delays = devices.map { _ in DelayLine(maxSeconds: 12) }
        latencies = devices.map { Self.outputLatency($0.objectID) }
        for p in processors { p.setVolume(volume, muted: muted, trimDB: trimDB) }

        // 1. The tap: a stereo mix of the app's processes, muted where they'd normally play.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "AudioLens – \(name)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw PipelineError.tap(tapStatus) }
        tapID = tap

        // 2. A private aggregate device: the output device(s), with the tap as its input. The
        // first device is the clock; the others, and the tap, are drift-compensated to it,
        // except the tap over Bluetooth, where both already follow the same clock and
        // compensating only adds a periodic crackle.
        let clock = devices[0]
        let aggregateUID = OutputDevices.ownUIDPrefix + "tap." + UUID().uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioLens – \(name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceClockDeviceKey: clock.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: devices.enumerated().map { index, device in
                [kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: index > 0]
            },
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: !clock.isBluetooth,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard aggregateStatus == noErr else {
            destroy()
            throw PipelineError.aggregate(aggregateStatus)
        }
        aggregateID = aggregate

        // The aggregate assembles itself asynchronously; wait (briefly) for its streams.
        let expectedOutputs = devices.reduce(0) { $0 + max(CA.streamCount($1.objectID, kAudioObjectPropertyScopeOutput), 1) }
        let deadline = Date().addingTimeInterval(3)
        while CA.streamCount(aggregate, kAudioObjectPropertyScopeOutput) < min(expectedOutputs, devices.count)
                || CA.streamCount(aggregate, kAudioObjectPropertyScopeInput) == 0 {
            guard Date() < deadline else {
                destroy()
                throw PipelineError.notReady
            }
            usleep(10_000)
        }
        sampleRate = CA.nominalSampleRate(aggregate)
        for (i, device) in devices.enumerated() { processors[i].setChain(chain(device, sampleRate)) }
        setSyncOffset(syncOffsetMs)

        // Which of the aggregate's output buffers belong to which device, in sub-device order.
        var ranges: [Range<Int>] = []
        var start = 0
        for device in devices {
            let count = CA.streamCount(device.objectID, kAudioObjectPropertyScopeOutput)
            ranges.append(start..<(start + count))
            start += count
        }
        if start != CA.streamCount(aggregate, kAudioObjectPropertyScopeOutput) {
            // Not the layout expected: everything to the first device's processor, all buffers.
            ranges = [0..<CA.streamCount(aggregate, kAudioObjectPropertyScopeOutput)]
            NSLog("AudioLens: output streams didn't line up with the devices; playing one mix to all")
        }

        // 3. The IOProc, on Core Audio's real-time thread.
        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil,
                                                            Self.ioBlock(processors: processors, delays: delays, ranges: ranges, feed: feed))
        guard procStatus == noErr, let proc else {
            destroy()
            throw PipelineError.ioProc(procStatus)
        }
        procID = proc
        disableHardwareInputs()

        let startStatus = AudioDeviceStart(aggregate, proc)
        guard startStatus == noErr else {
            destroy()
            throw PipelineError.start(startStatus)
        }

        // A Bluetooth headset that switches into call mode changes rate; the aggregate can't
        // follow that live, so the engine rebuilds it.
        let startRate = sampleRate
        rateListener = CA.Listener(aggregate, kAudioDevicePropertyNominalSampleRate) {
            if abs(CA.nominalSampleRate(aggregate) - startRate) > 1 { onRateChange() }
        }
        let names = devices.map(\.name).joined(separator: " + ")
        NSLog("AudioLens: tapping \(name) (\(processObjects.count) process\(processObjects.count == 1 ? "" : "es")) → \(names) at \(Int(sampleRate)) Hz, delays \(delays.map(\.delayFrames))")
    }

    func setVolume(_ volume: Double, muted: Bool, trimDB: Double) {
        for p in processors { p.setVolume(volume, muted: muted, trimDB: trimDB) }
    }

    /// Updates the EQ of each output for the current sample rate.
    func setChain(_ chain: (String, Double) -> EQChain) {
        for (i, uid) in deviceUIDs.enumerated() { processors[i].setChain(chain(uid, sampleRate)) }
    }

    /// Holds the Mac's own output back by the multi-room stream's delay.
    func setStreamDelay(seconds: Double) {
        guard feed != nil else { return }
        delays[0].delayFrames = Int(seconds * sampleRate)
    }

    /// Re-aligns the outputs with the user's fine-tuning, without rebuilding.
    func setSyncOffset(_ ms: Double) {
        guard delays.count > 1 else { return }
        let extra = Int(ms / 1000 * sampleRate)
        for (i, frames) in DelayLine.alignment(latencies: latencies, extra: extra).enumerated() { delays[i].delayFrames = frames }
    }

    func stop() {
        destroy()
    }

    private func destroy() {
        rateListener = nil
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// How late a device plays what it's given, in frames: its own latency, its safety offset
    /// and its first output stream's latency. AirPlay reports about half a second here.
    static func outputLatency(_ device: AudioObjectID) -> Int {
        let scope = kAudioObjectPropertyScopeOutput
        var frames = Int(CA.get(device, kAudioDevicePropertyLatency, scope, default: UInt32(0)))
            + Int(CA.get(device, kAudioDevicePropertySafetyOffset, scope, default: UInt32(0)))
        if let stream = CA.array(device, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self).first {
            frames += Int(CA.get(stream, kAudioStreamPropertyLatency, default: UInt32(0)))
        }
        return frames
    }

    /// The aggregate's inputs are the output devices' own inputs (a headset's microphone,
    /// say) followed by the tap. Only the tap is read, so the others are switched off: a
    /// running Bluetooth microphone would drop AirPods into low-quality call mode, and macOS
    /// would count a USB interface's inputs as microphone use.
    private func disableHardwareInputs() {
        guard let procID else { return }
        let inputs = CA.streamCount(aggregateID, kAudioObjectPropertyScopeInput)
        guard inputs > 1 else { return }
        // AudioHardwareIOProcStreamUsage: { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let header = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let size = header + inputs * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputs), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for i in 0..<inputs {
            raw.storeBytes(of: UInt32(i == inputs - 1 ? 1 : 0), toByteOffset: header + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw)
        if status != noErr { NSLog("AudioLens: couldn't switch off the device's own inputs (\(status))") }
    }

    /// The real-time render block. It reads the last input buffer (the tap), and for each
    /// output device processes it, delays it, and writes it in whatever layout that device uses.
    nonisolated private static func ioBlock(processors: [StereoProcessor], delays: [DelayLine], ranges: [Range<Int>],
                                            feed: StreamFeed?) -> AudioDeviceIOBlock {
        return { _, inputData, _, outputData, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            guard outputs.count > 0 else { return }

            // Frames come from the output side, which is what has to be filled.
            let first = outputs[0]
            let outChannels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)

            var source: UnsafePointer<Float>?
            var sourceChannels = 0
            if inputs.count > 0 {
                let tap = inputs[inputs.count - 1]
                if let data = tap.mData, tap.mNumberChannels > 0 {
                    sourceChannels = Int(tap.mNumberChannels)
                    let available = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
                    if available >= frames { source = UnsafePointer(data.assumingMemoryBound(to: Float.self)) }
                }
            }
            for (k, range) in ranges.enumerated() where k < processors.count && range.upperBound <= outputs.count {
                let processor = processors[k]
                let done = processor.process(interleaved: source, channels: sourceChannels, frames: frames)
                if k == 0, let feed {
                    // Into the multi-room stream as it is; the Mac plays it later, or not at all.
                    feed.ring.write(left: processor.left, right: processor.right, frames: done)
                    delays[k].process(left: processor.left, right: processor.right, frames: done)
                    write(outputs, range, left: processor.left, right: processor.right, done: feed.playsOnMac ? done : 0)
                    continue
                }
                delays[k].process(left: processor.left, right: processor.right, frames: done)
                write(outputs, range, left: processor.left, right: processor.right, done: done)
            }
        }
    }

    /// Writes stereo into one device's buffers: interleaved, one channel per buffer, or mono.
    nonisolated private static func write(_ outputs: UnsafeMutableAudioBufferListPointer, _ range: Range<Int>,
                                          left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, done: Int) {
        guard !range.isEmpty else { return }
        let first = outputs[range.lowerBound]
        let channels = max(Int(first.mNumberChannels), 1)
        if channels >= 2 {
            guard let out = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for i in 0..<frames {
                let base = i * channels
                out[base] = i < done ? left[i] : 0
                out[base + 1] = i < done ? right[i] : 0
                if channels > 2 { for c in 2..<channels { out[base + c] = 0 } }
            }
            for b in range.dropFirst() { if let d = outputs[b].mData { memset(d, 0, Int(outputs[b].mDataByteSize)) } }
        } else if range.count >= 2 {
            for (n, b) in range.enumerated() {
                guard let out = outputs[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = Int(outputs[b].mDataByteSize) / MemoryLayout<Float>.size
                let src: UnsafeMutablePointer<Float>? = n == 0 ? left : n == 1 ? right : nil
                for i in 0..<frames { out[i] = (src != nil && i < done) ? src![i] : 0 }
            }
        } else {
            guard let out = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<frames { out[i] = i < done ? (left[i] + right[i]) * 0.5 : 0 }
        }
    }
}
