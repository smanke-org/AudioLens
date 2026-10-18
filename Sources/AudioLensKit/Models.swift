import Foundation

/// What AudioLens remembers about one app, keyed by its bundle identifier.
public struct AppAudioSettings: Codable, Equatable, Sendable {
    /// 0 is silent, 1 is the app's own level, up to `AppAudioSettings.maxBoost` with boost on.
    public var volume: Double = 1
    public var muted = false
    /// Stays in the list while silent.
    public var pinned = false
    /// Left alone entirely: no tap, so the app sounds exactly as it would without AudioLens.
    public var ignored = false
    /// The output device's UID, or nil to follow the system output.
    public var outputUID: String?
    /// The app's name when it was last seen, for pinned and ignored apps that aren't running.
    public var name: String?

    public init(volume: Double = 1, muted: Bool = false, pinned: Bool = false, ignored: Bool = false,
                outputUID: String? = nil, name: String? = nil) {
        self.volume = volume
        self.muted = muted
        self.pinned = pinned
        self.ignored = ignored
        self.outputUID = outputUID
        self.name = name
    }

    public static let maxBoost = 1.5

    /// Whether anything differs from how the app sounds without AudioLens.
    public var changesSound: Bool {
        abs(volume - 1) > 0.001 || muted || outputUID != nil
    }

    // Decoded loosely, so a file from a newer version with extra or missing fields still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = min(max(try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1, 0), Self.maxBoost)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        outputUID = try c.decodeIfPresent(String.self, forKey: .outputUID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

/// The ten graphic-EQ bands, in hertz.
public enum EQBands {
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    public static let count = frequencies.count
    /// ±12 dB per band.
    public static let range: ClosedRange<Double> = -12...12
    /// The bandwidth of each band: one octave apart, so Q ≈ 1.41 keeps neighbors from piling up.
    public static let q = 1.41
}

/// A named curve for the ten bands.
public struct EQPreset: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let gains: [Double]

    public static let flat = EQPreset(name: "Flat", gains: Array(repeating: 0, count: EQBands.count))

    public static let all: [EQPreset] = [
        flat,
        EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Reducer", gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        EQPreset(name: "Treble Reducer", gains: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6]),
        EQPreset(name: "Vocal Clarity", gains: [-2, -2, -1, 0, 2, 3, 4, 3, 1, 0]),
        EQPreset(name: "Podcast", gains: [-4, -3, -1, 1, 2, 3, 3, 2, 0, -1]),
        EQPreset(name: "Loudness", gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
        EQPreset(name: "Late Night", gains: [-3, -2, 0, 1, 2, 2, 1, 0, -2, -3]),
        EQPreset(name: "Acoustic", gains: [4, 3, 2, 1, 1, 1, 2, 3, 2, 1]),
        EQPreset(name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 1, 2, 4, 5]),
        EQPreset(name: "Rock", gains: [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]),
        EQPreset(name: "Classical", gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        EQPreset(name: "Small Speakers", gains: [-6, -3, 1, 3, 2, 1, 1, 2, 2, 1]),
    ]

    /// The preset these gains match exactly, if any.
    public static func matching(_ gains: [Double]) -> EQPreset? {
        all.first { preset in
            preset.gains.count == gains.count && zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.05 }
        }
    }
}

/// One filter of a parametric EQ, as headphone-correction files describe them.
public struct ParametricFilter: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case peak, lowShelf, highShelf, lowPass, highPass
    }

    public var kind: Kind
    public var frequency: Double
    public var gain: Double
    public var q: Double

    public init(kind: Kind, frequency: Double, gain: Double, q: Double) {
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }
}

/// A correction curve for a particular headphone model.
public struct HeadphoneCorrection: Codable, Equatable, Sendable {
    /// "Apple AirPods Pro", as the source names it.
    public var name: String
    /// Who measured it, such as "crinacle on 711".
    public var source: String?
    public var preamp: Double
    public var filters: [ParametricFilter]
    public var enabled = true

    public init(name: String, source: String? = nil, preamp: Double, filters: [ParametricFilter], enabled: Bool = true) {
        self.name = name
        self.source = source
        self.preamp = preamp
        self.filters = filters
        self.enabled = enabled
    }
}

/// What AudioLens remembers about one output device, keyed by its UID.
public struct DeviceSettings: Codable, Equatable, Sendable {
    /// The device's name when it was last seen, for devices that aren't connected.
    public var name: String?
    /// Put the volume back to `DeviceVolumes`' last level when the device becomes the output.
    public var restoreVolume = true
    /// Put the volume back whenever anything else changes it.
    public var lockVolume = false
    public var eqEnabled = false
    public var eqGains: [Double] = EQPreset.flat.gains
    public var correction: HeadphoneCorrection?
    /// An AirPlay speaker, which can only be reconnected through the AirPlay picker.
    public var airPlay = false

    public init(name: String? = nil) { self.name = name }

    /// Whether the EQ or the correction changes the sound at all.
    public var processesSound: Bool {
        (eqEnabled && eqGains.contains { abs($0) > 0.05 }) || correction?.enabled == true
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        restoreVolume = try c.decodeIfPresent(Bool.self, forKey: .restoreVolume) ?? true
        lockVolume = try c.decodeIfPresent(Bool.self, forKey: .lockVolume) ?? false
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? false
        let gains = try c.decodeIfPresent([Double].self, forKey: .eqGains) ?? EQPreset.flat.gains
        eqGains = gains.count == EQBands.count
            ? gains.map { min(max($0, EQBands.range.lowerBound), EQBands.range.upperBound) }
            : EQPreset.flat.gains
        correction = try c.decodeIfPresent(HeadphoneCorrection.self, forKey: .correction)
        airPlay = try c.decodeIfPresent(Bool.self, forKey: .airPlay) ?? false
    }
}

/// The window layouts. Compact is reached from any of them and isn't chosen here.
public enum WindowLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    case sourceList, mixingDesk, dialBoard, deviceInspector

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sourceList: "Source List"
        case .mixingDesk: "Mixing Desk"
        case .dialBoard: "Dial Board"
        case .deviceInspector: "Device Inspector"
        }
    }

    /// The window's natural size for the layout.
    public var defaultSize: (width: Double, height: Double) {
        switch self {
        case .sourceList: (880, 560)
        case .mixingDesk: (920, 540)
        case .dialBoard: (900, 600)
        case .deviceInspector: (1200, 640)
        }
    }

    /// The narrowest the window can be and still fit the layout without clipping.
    public var minimumWidth: Double {
        switch self {
        case .sourceList: 760
        case .mixingDesk: 640
        case .dialBoard: 640
        case .deviceInspector: 1120
        }
    }

    public static let standard = WindowLayout.sourceList
}

/// Percent text for a 0…2 volume: "80%", "145%".
public func percentText(_ volume: Double) -> String {
    "\(Int((volume * 100).rounded()))%"
}
