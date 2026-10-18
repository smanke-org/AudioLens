import Foundation
import os
import Synchronization

/// The sound processing for one app: volume, the output device's EQ chain, and a soft
/// limiter, on stereo audio.
///
/// `process` runs on Core Audio's real-time thread, so it never allocates, never waits for a
/// lock and never calls into Objective-C. Settings arrive from the main thread through a lock
/// the audio thread only *tries* to take: if the main thread holds it at that instant, the
/// audio thread keeps the previous settings for one more buffer.
public final class StereoProcessor: @unchecked Sendable {
    /// Frames one call can process. Core Audio buffers are a few hundred frames; anything
    /// past this is left silent rather than overrunning the scratch space.
    public static let maxFrames = 16384
    public static let maxSections = 40

    private struct Settings {
        var gain: Float = 1
        var chain = EQChain.bypass
        var generation = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Settings())
    private let peakBits = Atomic<UInt32>(0)

    // Audio-thread state, only touched inside `process`.
    private var generation = -1
    private var targetGain: Float = 1
    private var currentGain: Float = 1
    private var preamp: Double = 1
    private var sectionCount = 0
    /// b0 b1 b2 a1 a2 per section.
    private let coefficients: UnsafeMutablePointer<Double>
    /// Transposed direct form II: two state values per section, per channel.
    private let stateL: UnsafeMutablePointer<Double>
    private let stateR: UnsafeMutablePointer<Double>
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>
    private var firstBuffer = true

    public init() {
        coefficients = .allocate(capacity: Self.maxSections * 5)
        stateL = .allocate(capacity: Self.maxSections * 2)
        stateR = .allocate(capacity: Self.maxSections * 2)
        left = .allocate(capacity: Self.maxFrames)
        right = .allocate(capacity: Self.maxFrames)
        coefficients.initialize(repeating: 0, count: Self.maxSections * 5)
        stateL.initialize(repeating: 0, count: Self.maxSections * 2)
        stateR.initialize(repeating: 0, count: Self.maxSections * 2)
        left.initialize(repeating: 0, count: Self.maxFrames)
        right.initialize(repeating: 0, count: Self.maxFrames)
    }

    deinit {
        coefficients.deallocate()
        stateL.deallocate()
        stateR.deallocate()
        left.deallocate()
        right.deallocate()
    }

    /// The slider position, 0…1.5, as an amplitude. Loudness doubles for roughly every 10 dB,
    /// so 50% sounds about half as loud and 150% about one and a half times as loud.
    public static func amplitude(forVolume volume: Double) -> Float {
        guard volume > 0 else { return 0 }
        return Float(pow(volume, 1.66))
    }

    /// From the main thread: the level to fade to (0 when muted).
    public func setVolume(_ volume: Double, muted: Bool) {
        let gain = muted ? 0 : Self.amplitude(forVolume: volume)
        shared.withLock { $0.gain = gain; $0.generation &+= 1 }
    }

    /// From the main thread: the output device's EQ chain.
    public func setChain(_ chain: EQChain) {
        let capped = chain.sections.count > Self.maxSections
            ? EQChain(sections: Array(chain.sections.prefix(Self.maxSections)), preamp: chain.preamp) : chain
        shared.withLock { $0.chain = capped; $0.generation &+= 1 }
    }

    /// The loudest sample since the last call, 0…1 (or more while boosting), for meters.
    public func takePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    /// Picks up new settings if the main thread isn't holding them at this instant.
    private func adoptSettings() {
        let seen = generation
        let coefficients = self.coefficients
        let attempt = shared.withLockIfAvailableUnchecked { s -> (Float, Int, Double, Int)? in
            guard s.generation != seen else { return nil }
            // Coefficients are copied out while the lock is held; nothing here allocates.
            let n = s.chain.sections.count
            for (i, b) in s.chain.sections.enumerated() {
                let c = coefficients + i * 5
                c[0] = b.b0; c[1] = b.b1; c[2] = b.b2; c[3] = b.a1; c[4] = b.a2
            }
            return (s.gain, s.generation, s.chain.preamp, n)
        }
        guard let attempt, let (gain, gen, pre, count) = attempt else { return }
        if count != sectionCount {
            // A different chain shape: start its filters from silence.
            stateL.update(repeating: 0, count: Self.maxSections * 2)
            stateR.update(repeating: 0, count: Self.maxSections * 2)
        }
        targetGain = gain
        if firstBuffer { currentGain = gain }
        preamp = pre
        sectionCount = count
        generation = gen
    }

    /// Processes one buffer of interleaved input (`channels` per frame; nil means silence)
    /// into `left` and `right`, and returns how many frames are there.
    @discardableResult
    public func process(interleaved input: UnsafePointer<Float>?, channels: Int, frames requested: Int) -> Int {
        adoptSettings()
        firstBuffer = false
        let frames = min(requested, Self.maxFrames)
        guard frames > 0 else { return 0 }

        // Deinterleave: mono copies to both sides; more than two channels keeps the first two.
        if let input, channels > 0 {
            if channels == 1 {
                for i in 0..<frames { left[i] = input[i]; right[i] = input[i] }
            } else {
                for i in 0..<frames { left[i] = input[i * channels]; right[i] = input[i * channels + 1] }
            }
        } else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
        }

        // Filters, in double precision: a 32 Hz band at 48 kHz is too close to the unit circle
        // for single precision to stay quiet.
        if sectionCount > 0 {
            filter(left, frames: frames, state: stateL)
            filter(right, frames: frames, state: stateR)
        }

        // Volume, faded across the buffer so changes don't click, then a soft limiter that
        // leaves everything under -1 dBFS alone.
        let start = currentGain, end = targetGain
        let step = (end - start) / Float(frames)
        var gain = start
        var peak: Float = 0
        let threshold: Float = 0.891
        for i in 0..<frames {
            gain += step
            var l = left[i] * gain, r = right[i] * gain
            l = Self.softLimit(l, threshold: threshold)
            r = Self.softLimit(r, threshold: threshold)
            left[i] = l; right[i] = r
            peak = max(peak, abs(l), abs(r))
        }
        currentGain = end

        let previous = Float(bitPattern: peakBits.load(ordering: .relaxed))
        if peak > previous { peakBits.store(peak.bitPattern, ordering: .relaxed) }
        return frames
    }

    private func filter(_ samples: UnsafeMutablePointer<Float>, frames: Int, state: UnsafeMutablePointer<Double>) {
        let pre = preamp
        for i in 0..<frames {
            var x = Double(samples[i]) * pre
            for s in 0..<sectionCount {
                let c = coefficients + s * 5
                let z = state + s * 2
                let y = c[0] * x + z[0]
                z[0] = c[1] * x - c[3] * y + z[1]
                z[1] = c[2] * x - c[4] * y
                x = y
            }
            // Denormals cost hundreds of cycles each on some CPUs.
            samples[i] = abs(x) < 1e-20 ? 0 : Float(x)
        }
    }

    /// Unchanged below the threshold; above it, eased toward ±1 so it never clips.
    @inline(__always)
    public static func softLimit(_ x: Float, threshold: Float) -> Float {
        let a = abs(x)
        guard a > threshold else { return x }
        let headroom = 1 - threshold
        let limited = threshold + headroom * tanh((a - threshold) / headroom)
        return x < 0 ? -limited : limited
    }
}
