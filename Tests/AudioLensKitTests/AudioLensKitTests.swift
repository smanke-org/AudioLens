import Foundation
import Testing
@testable import AudioLensKit

@Suite struct EQMathTests {
    @Test func peakingFilterHitsItsGainAtTheCenter() {
        let b = Biquad.peaking(frequency: 1000, gain: 6, q: 1.41, sampleRate: 48000)
        #expect(abs(b.response(at: 1000, sampleRate: 48000) - 6) < 0.05)
        #expect(abs(b.response(at: 30, sampleRate: 48000)) < 0.2)
    }

    @Test func shelvesReachTheirGainAtTheFarEnd() {
        let low = Biquad.lowShelf(frequency: 105, gain: 4, q: 0.7, sampleRate: 48000)
        #expect(abs(low.response(at: 20, sampleRate: 48000) - 4) < 0.3)
        #expect(abs(low.response(at: 5000, sampleRate: 48000)) < 0.1)
        let high = Biquad.highShelf(frequency: 8000, gain: -5, q: 0.7, sampleRate: 48000)
        #expect(abs(high.response(at: 20000, sampleRate: 48000) + 5) < 0.6)
    }

    @Test func flatSettingsBypass() {
        var settings = DeviceSettings()
        settings.eqEnabled = true
        #expect(EQChain(settings: settings, sampleRate: 48000).isBypass)
        #expect(!settings.processesSound)
    }

    @Test func boostsGetHeadroomSoTheChainNeverExceedsZeroDB() {
        var settings = DeviceSettings()
        settings.eqEnabled = true
        settings.eqGains = [8, 8, 6, 0, 0, 0, 0, 0, 0, 0]
        let chain = EQChain(settings: settings, sampleRate: 48000)
        let peak = chain.response(at: EQChain.logFrequencies(count: 200), sampleRate: 48000).max() ?? 0
        #expect(peak <= 0.05)
        #expect(chain.preamp < 1)
    }

    @Test func presetsMatchByGains() {
        #expect(EQPreset.matching(EQPreset.all[1].gains)?.name == "Bass Boost")
        #expect(EQPreset.matching([1, 0, 0, 0, 0, 0, 0, 0, 0, 0]) == nil)
    }
}

@Suite struct ProcessorTests {
    private func sine(frames: Int, frequency: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).flatMap { i -> [Float] in
            let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / 48000))
            return [v, v]
        }
    }

    @Test func unityPassesAudioThrough() {
        let p = StereoProcessor()
        let input = sine(frames: 512, frequency: 440)
        input.withUnsafeBufferPointer { _ = p.process(interleaved: $0.baseAddress, channels: 2, frames: 512) }
        for i in 0..<512 { #expect(abs(p.left[i] - input[i * 2]) < 1e-6) }
    }

    @Test func muteFadesToSilence() {
        let p = StereoProcessor()
        p.setVolume(1, muted: true)
        let input = sine(frames: 256, frequency: 440)
        input.withUnsafeBufferPointer { _ = p.process(interleaved: $0.baseAddress, channels: 2, frames: 256) }
        // The first buffer after a change starts at the new level.
        #expect((0..<256).allSatisfy { p.left[$0] == 0 })
    }

    @Test func volumeChangesRampAcrossABuffer() {
        let p = StereoProcessor()
        let input = [Float](repeating: 0.5, count: 1024)
        input.withUnsafeBufferPointer { _ = p.process(interleaved: $0.baseAddress, channels: 2, frames: 512) }
        p.setVolume(0.5, muted: false)
        input.withUnsafeBufferPointer { _ = p.process(interleaved: $0.baseAddress, channels: 2, frames: 512) }
        let target = 0.5 * StereoProcessor.amplitude(forVolume: 0.5)
        #expect(p.left[0] > target)
        #expect(abs(p.left[511] - target) < 1e-4)
    }

    @Test func boostIsLimitedBelowFullScale() {
        let p = StereoProcessor()
        p.setVolume(AppAudioSettings.maxBoost, muted: false)
        let input = sine(frames: 4096, frequency: 220, amplitude: 0.95)
        input.withUnsafeBufferPointer { _ = p.process(interleaved: $0.baseAddress, channels: 2, frames: 4096) }
        #expect((0..<4096).allSatisfy { abs(p.left[$0]) <= 1 })
        #expect(p.takePeak() > 0.9)
        #expect(p.takePeak() == 0)
    }

    @Test func trimTakesBackWhatTheDeviceVolumeCarries() {
        // An app at 30% with the device volume moved to that level needs no gain of its own.
        let p = StereoProcessor()
        p.setVolume(0.3, muted: false, trimDB: StereoProcessor.decibels(forVolume: 0.3))
        let input = [Float](repeating: 0.25, count: 512)
        input.withUnsafeBufferPointer { _ = p.process(interleaved: $0.baseAddress, channels: 2, frames: 256) }
        #expect(abs(p.left[255] - 0.25) < 1e-4)
    }

    @Test func monoIsCopiedToBothSides() {
        let p = StereoProcessor()
        let input: [Float] = [0.1, 0.2, 0.3]
        input.withUnsafeBufferPointer { _ = p.process(interleaved: $0.baseAddress, channels: 1, frames: 3) }
        #expect(p.right[2] == 0.3 && p.left[1] == 0.2)
    }

    @Test func eqChainChangesTheSignal() {
        let p = StereoProcessor()
        var settings = DeviceSettings()
        settings.eqEnabled = true
        settings.eqGains = [0, 0, 0, 0, 0, -12, 0, 0, 0, 0]
        p.setChain(EQChain(settings: settings, sampleRate: 48000))
        let input = sine(frames: 4800, frequency: 1000)
        input.withUnsafeBufferPointer { _ = p.process(interleaved: $0.baseAddress, channels: 2, frames: 4800) }
        let tail = (2400..<4800).map { abs(p.left[$0]) }.max() ?? 1
        #expect(tail < 0.2)
    }
}

@Suite struct AutoEQTests {
    @Test func parsesIndexLinesIncludingParenthesesInPaths() {
        let text = """
        # Index
        - [Apple AirPods Pro](./crinacle/711%20in-ear/Apple%20AirPods%20Pro) by crinacle on 711
        - [Model X (ANC On)](./Lab/in-ear/Model%20X%20(ANC%20On)) by Lab
        """
        let entries = AutoEQ.parseIndex(text)
        #expect(entries.count == 2)
        #expect(entries[1].name == "Model X (ANC On)")
        #expect(entries[1].path == "./Lab/in-ear/Model%20X%20(ANC%20On)")
        #expect(entries[0].source == "crinacle on 711")
        #expect(entries[0].parametricURL?.absoluteString ==
                "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/crinacle/711%20in-ear/Apple%20AirPods%20Pro/Apple%20AirPods%20Pro%20ParametricEQ.txt")
    }

    @Test func parsesParametricFiles() throws {
        let text = """
        Preamp: -6.0 dB
        Filter 1: ON LSC Fc 105 Hz Gain 2.6 dB Q 0.70
        Filter 2: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68
        Filter 3: OFF PK Fc 900 Hz Gain 3 dB Q 1
        Filter 4: ON HSC Fc 10000 Hz Gain -0.5 dB Q 0.70
        """
        let c = try AutoEQ.parseParametric(text, name: "Example Phones")
        #expect(c.preamp == -6)
        #expect(c.filters.count == 3)
        #expect(c.filters[0] == ParametricFilter(kind: .lowShelf, frequency: 105, gain: 2.6, q: 0.7))
        #expect(c.filters[2].kind == .highShelf)
    }

    @Test func rejectsFilesWithoutFilters() {
        #expect(throws: AutoEQ.ParseError.self) { try AutoEQ.parseParametric("hello", name: "x") }
    }

    @Test func searchPrefersPrefixAndShortNames() {
        let entries = [
            AutoEQ.Entry(name: "Apple AirPods Pro 2", source: "a", path: "x"),
            AutoEQ.Entry(name: "Apple AirPods Pro", source: "b", path: "y"),
            AutoEQ.Entry(name: "Other Brand", source: "c", path: "z"),
        ]
        let hits = AutoEQ.search(entries, for: "airpods pro")
        #expect(hits.map(\.name) == ["Apple AirPods Pro", "Apple AirPods Pro 2"])
    }
}

@Suite struct SettingsModelTests {
    @Test func decodesLooselyAndClamps() throws {
        let json = #"{"volume": 9, "pinned": true, "extra": 1}"#
        let s = try JSONDecoder().decode(AppAudioSettings.self, from: Data(json.utf8))
        #expect(s.volume == 1.5 && s.pinned && !s.muted)
        let d = try JSONDecoder().decode(DeviceSettings.self, from: Data(#"{"eqGains":[1,2]}"#.utf8))
        #expect(d.eqGains == EQPreset.flat.gains && d.restoreVolume)
    }

    @Test func percentText() {
        #expect(AudioLensKit.percentText(1.45) == "145%")
    }
}
