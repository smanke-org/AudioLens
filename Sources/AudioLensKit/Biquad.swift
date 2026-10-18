import Foundation

/// One second-order filter section, normalized so a0 = 1. Coefficients from Robert
/// Bristow-Johnson's "Audio EQ Cookbook".
public struct Biquad: Equatable, Sendable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Passes everything unchanged.
    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    private static func normalized(_ b0: Double, _ b1: Double, _ b2: Double,
                                   _ a0: Double, _ a1: Double, _ a2: Double) -> Biquad {
        Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// A frequency the sample rate can represent, kept clear of 0 and Nyquist.
    private static func clamp(_ frequency: Double, _ sampleRate: Double) -> Double {
        min(max(frequency, 10), sampleRate * 0.49)
    }

    public static func peaking(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        guard abs(gain) > 0.001 else { return .identity }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * clamp(frequency, sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 0.05))
        let c = cos(w0)
        return normalized(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    public static func lowShelf(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        guard abs(gain) > 0.001 else { return .identity }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * clamp(frequency, sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 0.05))
        let c = cos(w0)
        let s = 2 * sqrt(a) * alpha
        return normalized(a * ((a + 1) - (a - 1) * c + s),
                          2 * a * ((a - 1) - (a + 1) * c),
                          a * ((a + 1) - (a - 1) * c - s),
                          (a + 1) + (a - 1) * c + s,
                          -2 * ((a - 1) + (a + 1) * c),
                          (a + 1) + (a - 1) * c - s)
    }

    public static func highShelf(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        guard abs(gain) > 0.001 else { return .identity }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * clamp(frequency, sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 0.05))
        let c = cos(w0)
        let s = 2 * sqrt(a) * alpha
        return normalized(a * ((a + 1) + (a - 1) * c + s),
                          -2 * a * ((a - 1) + (a + 1) * c),
                          a * ((a + 1) + (a - 1) * c - s),
                          (a + 1) - (a - 1) * c + s,
                          2 * ((a - 1) - (a + 1) * c),
                          (a + 1) - (a - 1) * c - s)
    }

    public static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * clamp(frequency, sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 0.05))
        let c = cos(w0)
        return normalized((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    public static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * clamp(frequency, sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 0.05))
        let c = cos(w0)
        return normalized((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    public static func filter(_ f: ParametricFilter, sampleRate: Double) -> Biquad {
        switch f.kind {
        case .peak: peaking(frequency: f.frequency, gain: f.gain, q: f.q, sampleRate: sampleRate)
        case .lowShelf: lowShelf(frequency: f.frequency, gain: f.gain, q: f.q, sampleRate: sampleRate)
        case .highShelf: highShelf(frequency: f.frequency, gain: f.gain, q: f.q, sampleRate: sampleRate)
        case .lowPass: lowPass(frequency: f.frequency, q: f.q, sampleRate: sampleRate)
        case .highPass: highPass(frequency: f.frequency, q: f.q, sampleRate: sampleRate)
        }
    }

    /// The filter's gain at a frequency, in dB.
    public func response(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let magnitude = sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30))
        return 20 * log10(max(magnitude, 1e-9))
    }
}

/// Everything one output device does to the sound: its EQ bands, its headphone correction,
/// and the preamp that keeps the two from clipping.
public struct EQChain: Equatable, Sendable {
    public var sections: [Biquad]
    /// Linear gain applied before the filters.
    public var preamp: Double

    public static let bypass = EQChain(sections: [], preamp: 1)

    public init(sections: [Biquad], preamp: Double) {
        self.sections = sections
        self.preamp = preamp
    }

    public var isBypass: Bool { sections.isEmpty && abs(preamp - 1) < 1e-6 }

    /// The chain for a device's settings at a sample rate.
    public init(settings: DeviceSettings, sampleRate: Double) {
        var sections: [Biquad] = []
        var preampDB = 0.0
        if let correction = settings.correction, correction.enabled {
            sections += correction.filters.map { Biquad.filter($0, sampleRate: sampleRate) }.filter { $0 != .identity }
            preampDB += correction.preamp
        }
        if settings.eqEnabled {
            sections += zip(EQBands.frequencies, settings.eqGains).map {
                Biquad.peaking(frequency: $0, gain: $1, q: EQBands.q, sampleRate: sampleRate)
            }.filter { $0 != .identity }
        }
        guard !sections.isEmpty else {
            self = .bypass
            return
        }
        // Headroom for the user's own boosts, on top of what the correction file asks for.
        let peak = EQChain.peakResponse(of: sections, sampleRate: sampleRate) + preampDB
        if peak > 0 { preampDB -= peak }
        self.init(sections: sections, preamp: pow(10, preampDB / 20))
    }

    /// The highest gain the sections reach anywhere in the audible range, in dB.
    public static func peakResponse(of sections: [Biquad], sampleRate: Double) -> Double {
        var peak = -Double.infinity
        for frequency in logFrequencies(count: 160) where frequency < sampleRate / 2 {
            let total = sections.reduce(0) { $0 + $1.response(at: frequency, sampleRate: sampleRate) }
            peak = max(peak, total)
        }
        return peak.isFinite ? peak : 0
    }

    /// The chain's total response, in dB, at each frequency.
    public func response(at frequencies: [Double], sampleRate: Double) -> [Double] {
        let pre = 20 * log10(max(preamp, 1e-9))
        return frequencies.map { f in sections.reduce(pre) { $0 + $1.response(at: f, sampleRate: sampleRate) } }
    }

    /// Frequencies spaced evenly on a log scale from 20 Hz to 20 kHz.
    public static func logFrequencies(count: Int) -> [Double] {
        (0..<count).map { 20 * pow(1000, Double($0) / Double(max(count - 1, 1))) }
    }
}
