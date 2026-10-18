import AudioLensKit
import AudioToolbox
import CoreAudio
import Foundation

/// One app's audio, captured and played back through AudioLens:
///
///     app's processes ──tap (muted at the source)──▶ private aggregate device ──▶ output device
///                                                    └ IOProc: volume, EQ, limiter
///
/// The tap mutes the app's own output while AudioLens plays the captured copy, so what you
/// hear is the processed sound only. Everything here is private to AudioLens: other apps never
/// see the tap or the aggregate, and both go away if AudioLens quits or crashes.
@MainActor
final class TapPipeline {
    let appID: String
    let processObjects: [AudioObjectID]
    let deviceUID: String
    let processor = StereoProcessor()
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

    init(appID: String, name: String, processObjects: [AudioObjectID], device: OutputDevice,
         volume: Double, muted: Bool, trimDB: Double, chain: (Double) -> EQChain, onRateChange: @escaping @MainActor () -> Void) throws {
        self.appID = appID
        self.processObjects = processObjects
        self.deviceUID = device.uid
        processor.setVolume(volume, muted: muted, trimDB: trimDB)

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

        // 2. A private aggregate device: the output device, with the tap as its input. The
        // tap's clock follows the app's output device; drift compensation keeps the two in step,
        // except over Bluetooth, where both already follow the same clock and compensating
        // only adds a periodic crackle.
        let aggregateUID = OutputDevices.ownUIDPrefix + "tap." + UUID().uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioLens – \(name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceClockDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: !device.isBluetooth,
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
        let deadline = Date().addingTimeInterval(2)
        while CA.streamCount(aggregate, kAudioObjectPropertyScopeOutput) == 0 || CA.streamCount(aggregate, kAudioObjectPropertyScopeInput) == 0 {
            guard Date() < deadline else {
                destroy()
                throw PipelineError.notReady
            }
            usleep(10_000)
        }
        sampleRate = CA.nominalSampleRate(aggregate)
        processor.setChain(chain(sampleRate))

        // 3. The IOProc, on Core Audio's real-time thread.
        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, Self.ioBlock(processor))
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
        NSLog("AudioLens: tapping \(name) (\(processObjects.count) process\(processObjects.count == 1 ? "" : "es")) → \(device.name) at \(Int(sampleRate)) Hz")
    }

    /// Updates the EQ for the current sample rate.
    func setChain(_ chain: (Double) -> EQChain) {
        processor.setChain(chain(sampleRate))
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

    /// The aggregate's inputs are the output device's own inputs (a headset's microphone,
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

    /// The real-time render block. It reads the last input buffer (the tap), processes it,
    /// and writes the result to the output in whatever layout the device uses.
    nonisolated private static func ioBlock(_ processor: StereoProcessor) -> AudioDeviceIOBlock {
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
            let done = processor.process(interleaved: source, channels: sourceChannels, frames: frames)
            let left = processor.left, right = processor.right

            if outChannels >= 2 {
                // Interleaved: left and right into the first two channels, silence in the rest.
                guard let out = first.mData?.assumingMemoryBound(to: Float.self) else { return }
                for i in 0..<frames {
                    let base = i * outChannels
                    if i < done {
                        out[base] = left[i]
                        out[base + 1] = right[i]
                    } else {
                        out[base] = 0; out[base + 1] = 0
                    }
                    if outChannels > 2 { for c in 2..<outChannels { out[base + c] = 0 } }
                }
                if outputs.count > 1 { for b in 1..<outputs.count { if let d = outputs[b].mData { memset(d, 0, Int(outputs[b].mDataByteSize)) } } }
            } else if outputs.count >= 2 {
                // One channel per buffer: left, right, then silence.
                for b in 0..<outputs.count {
                    guard let out = outputs[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = min(frames, Int(outputs[b].mDataByteSize) / MemoryLayout<Float>.size)
                    let src: UnsafeMutablePointer<Float>? = b == 0 ? left : b == 1 ? right : nil
                    for i in 0..<n { out[i] = (src != nil && i < done) ? src![i] : 0 }
                }
            } else {
                // A mono device: the average of both sides.
                guard let out = first.mData?.assumingMemoryBound(to: Float.self) else { return }
                for i in 0..<frames { out[i] = i < done ? (left[i] + right[i]) * 0.5 : 0 }
            }
        }
    }
}
