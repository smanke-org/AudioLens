import Foundation
import Synchronization

/// A single-producer, single-consumer ring of stereo audio: an app's tap writes into it on
/// Core Audio's real-time thread, and the multi-room mixer reads from it on its own thread.
/// Neither side locks or allocates. If the reader falls more than the capacity behind, the
/// oldest audio is skipped.
public final class MixRing: @unchecked Sendable {
    public let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    public init(seconds: Double = 2, sampleRate: Double = 48000) {
        capacity = max(Int(seconds * sampleRate), 64)
        samples = .allocate(capacity: capacity * 2)
        samples.initialize(repeating: 0, count: capacity * 2)
    }

    deinit { samples.deallocate() }

    /// Frames written and not yet read (at most `capacity`).
    public var available: Int {
        min(written.load(ordering: .acquiring) - read.load(ordering: .relaxed), capacity)
    }

    /// Producer side.
    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var w = written.load(ordering: .relaxed)
        for i in 0..<frames {
            let slot = (w % capacity) * 2
            samples[slot] = left[i]
            samples[slot + 1] = right[i]
            w += 1
        }
        written.store(w, ordering: .releasing)
    }

    /// Consumer side: adds up to `frames` frames into interleaved stereo `out`, returns how many.
    @discardableResult
    public func mix(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let w = written.load(ordering: .acquiring)
        var r = read.load(ordering: .relaxed)
        if w - r > capacity { r = w - capacity }
        let n = min(frames, w - r)
        for i in 0..<n {
            let slot = ((r + i) % capacity) * 2
            out[i * 2] += samples[slot]
            out[i * 2 + 1] += samples[slot + 1]
        }
        read.store(r + n, ordering: .relaxed)
        return n
    }

    /// Consumer side: drops everything waiting, so reading starts with the newest audio.
    public func skipToNewest() {
        read.store(written.load(ordering: .acquiring), ordering: .relaxed)
    }
}

/// What a multi-room tap does with its sound: feeds a ring for the AirPlay stream, and plays
/// on the Mac's own output only if asked (delayed to match AirPlay).
public final class StreamFeed: @unchecked Sendable {
    public let ring: MixRing
    private let macOutput = Atomic<Bool>(true)
    private let macGainBits = Atomic<UInt32>(Float(1).bitPattern)

    public init(ring: MixRing) { self.ring = ring }

    /// Extra gain for the Mac's own output only (to take back the level the Mac's hardware
    /// volume carries); the stream gets the app's sound as it is.
    public var macGain: Float {
        get { Float(bitPattern: macGainBits.load(ordering: .relaxed)) }
        set { macGainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    public var playsOnMac: Bool {
        get { macOutput.load(ordering: .relaxed) }
        set { macOutput.store(newValue, ordering: .relaxed) }
    }
}
