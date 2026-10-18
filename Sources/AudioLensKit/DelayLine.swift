import Foundation
import Synchronization

/// A stereo delay, for keeping outputs in step: a speaker that plays sooner than another
/// (the Mac's own speakers next to an AirPlay HomePod) is held back by the difference.
///
/// Real-time safe: the buffer is allocated up front and `process` never allocates or locks.
/// The delay can be changed from any thread; the audio thread picks it up on its next buffer.
public final class DelayLine: @unchecked Sendable {
    public let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private let delay = Atomic<Int>(0)

    /// `maxSeconds` of delay at `sampleRate`.
    public init(maxSeconds: Double = 3, sampleRate: Double = 48000) {
        capacity = max(Int(maxSeconds * sampleRate) + 1, 2)
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public var delayFrames: Int {
        get { delay.load(ordering: .relaxed) }
        set { delay.store(min(max(newValue, 0), capacity - 1), ordering: .relaxed) }
    }

    /// Delays the samples in place.
    public func process(left inL: UnsafeMutablePointer<Float>, right inR: UnsafeMutablePointer<Float>, frames: Int) {
        let d = delay.load(ordering: .relaxed)
        guard d > 0 else { return }
        for i in 0..<frames {
            left[writeIndex] = inL[i]
            right[writeIndex] = inR[i]
            var read = writeIndex - d
            if read < 0 { read += capacity }
            inL[i] = left[read]
            inR[i] = right[read]
            writeIndex += 1
            if writeIndex == capacity { writeIndex = 0 }
        }
    }

    /// The delay each output needs so they all sound together: the slowest gets none, the
    /// others the difference, plus `extra` frames (the user's fine-tuning; negative pulls the
    /// faster outputs earlier).
    public static func alignment(latencies: [Int], extra: Int) -> [Int] {
        guard let slowest = latencies.max() else { return [] }
        return latencies.map { latency in
            latency == slowest ? max(0, -extra) : max(0, slowest - latency + extra)
        }
    }
}
