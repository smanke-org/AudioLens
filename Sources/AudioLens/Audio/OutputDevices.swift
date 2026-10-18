import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// An output device as AudioLens shows it.
struct OutputDevice: Identifiable, Hashable {
    var id: String { uid }
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// An SF Symbol for the kind of device.
    var symbol: String { Self.symbol(name: name, transport: transport) }

    static func symbol(name: String, transport: UInt32) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("homepod mini") { return "homepodmini" }
        if lower.contains("homepod") { return "homepod" }
        if lower.contains("apple tv") || lower.contains("appletv") { return "appletv" }
        if lower.contains("beats") { return "beats.headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return lower.contains("macbook") ? "laptopcomputer" : "speaker.wave.2"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2"
        }
    }

    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        default: "Audio device"
        }
    }
}

/// The Mac's output devices, the system output, and each device's volume — which AudioLens
/// remembers per device and puts back when the device becomes the output again.
@Observable
@MainActor
final class OutputDevices {
    static let shared = OutputDevices()

    /// Every output device, system output first.
    private(set) var devices: [OutputDevice] = []
    private(set) var defaultUID: String?
    /// The system output's volume, 0…1, or nil if it has no volume control.
    private(set) var volume: Double?
    private(set) var muted = false

    var defaultDevice: OutputDevice? { devices.first { $0.uid == defaultUID } }

    @ObservationIgnored private var listeners: [CA.Listener] = []
    @ObservationIgnored private var volumeListeners: [CA.Listener] = []
    @ObservationIgnored private var watchedVolumeDevice: AudioObjectID = 0
    /// Until this moment, changes to the system output's volume are taken back to the
    /// remembered level: macOS sets a newly connected device's volume a beat after switching
    /// to it, which would otherwise undo the restore.
    @ObservationIgnored private var restoreUntil = Date.distantPast
    @ObservationIgnored private var restoring = false
    /// The hardware volume AudioLens last set on the system output, to recognize its echo.
    @ObservationIgnored private var lastSetHardware: Double?

    /// The private aggregate devices AudioLens makes for its taps have this UID prefix.
    static let ownUIDPrefix = "com.smanke.AudioLens."

    private init() {}

    func start() {
        listeners = [
            CA.Listener(CA.system, kAudioHardwarePropertyDevices) { OutputDevices.shared.refresh() },
            CA.Listener(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { OutputDevices.shared.defaultChanged() },
        ].compactMap { $0 }
        refresh()
        defaultChanged(initial: true)
    }

    func refresh() {
        let defaultID = CA.defaultOutputDevice()
        var list: [OutputDevice] = []
        for id in CA.deviceIDs() {
            guard CA.channelCount(id, kAudioObjectPropertyScopeOutput) > 0,
                  let uid = CA.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(Self.ownUIDPrefix),
                  CA.get(id, kAudioDevicePropertyIsHidden, default: UInt32(0)) == 0 else { continue }
            let name = CA.string(id, kAudioObjectPropertyName) ?? "Output"
            list.append(OutputDevice(objectID: id, uid: uid, name: name, transport: CA.transport(id)))
        }
        list.sort { a, b in
            if (a.objectID == defaultID) != (b.objectID == defaultID) { return a.objectID == defaultID }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if list != devices {
            if list.contains(where: { d in d.transport == kAudioDeviceTransportTypeAirPlay && !devices.contains { $0.uid == d.uid } }) {
                ConnectHint.shared.dismiss()
            }
            devices = list
            // Remember names, so settings for a disconnected device still read well.
            for device in list {
                let known = SettingsStore.shared.device(device.uid)
                let airPlay = device.transport == kAudioDeviceTransportTypeAirPlay
                if known.name != device.name || known.airPlay != airPlay {
                    SettingsStore.shared.updateDevice(device.uid) { $0.name = device.name; $0.airPlay = airPlay }
                }
            }
            AudioEngine.shared.devicesChanged()
        }
        defaultUID = list.first { $0.objectID == defaultID }?.uid
    }

    func device(uid: String?) -> OutputDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    // MARK: - System output

    private func defaultChanged(initial: Bool = false) {
        refresh()
        let id = CA.defaultOutputDevice()
        if id != watchedVolumeDevice {
            watchedVolumeDevice = id
            volumeListeners = [
                CA.Listener(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput) {
                    OutputDevices.shared.volumeChanged()
                },
                CA.Listener(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput) {
                    OutputDevices.shared.readVolume()
                },
            ].compactMap { $0 }
        }
        // The new output's volume still carries whatever trim AudioLens left on it.
        trimDB = defaultUID.map { SettingsStore.shared.trim(for: $0) } ?? 0
        readVolume()
        if let uid = defaultUID {
            let settings = SettingsStore.shared.device(uid)
            if settings.restoreVolume || settings.lockVolume, let saved = SettingsStore.shared.savedVolume(for: uid) {
                // Again shortly after, past macOS's own late adjustment for a new connection.
                restoreUntil = Date().addingTimeInterval(initial ? 0.5 : 3)
                applyRemembered(saved, to: id)
                if !initial {
                    for delay in [0.4, 1.2] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            MainActor.assumeIsolated {
                                guard CA.defaultOutputDevice() == id else { return }
                                OutputDevices.shared.applyRemembered(saved, to: id)
                            }
                        }
                    }
                }
            } else if let volume {
                SettingsStore.shared.saveVolume(volume, for: uid)
            }
        }
        AudioEngine.shared.defaultOutputChanged()
    }

    /// The system output's level, as the user set it. With `trimDB` at 0 this is the device's
    /// own volume; otherwise the device sits `trimDB` above or below it.
    private func readVolume() {
        let id = CA.defaultOutputDevice()
        volume = Self.volume(of: id).map { logical(fromHardware: $0, of: id, trimDB: trimDB) }
        muted = CA.get(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, default: UInt32(0)) != 0
    }

    private func volumeChanged() {
        readVolume()
        // Core Audio announces AudioLens's own changes too, a moment after they're made.
        if let hw = Self.volume(of: watchedVolumeDevice), let last = lastSetHardware, abs(hw - last) < 0.003 { return }
        lastSetHardware = nil
        guard !restoring, let uid = defaultUID, let volume else { return }
        let settings = SettingsStore.shared.device(uid)
        let saved = SettingsStore.shared.savedVolume(for: uid)
        if let saved, abs(saved - volume) > 0.005, settings.lockVolume || Date() < restoreUntil {
            applyRemembered(saved, to: watchedVolumeDevice)
            return
        }
        SettingsStore.shared.saveVolume(volume, for: uid)
    }

    private func applyRemembered(_ value: Double, to id: AudioObjectID) {
        let target = physical(value, of: id, trimDB: trimDB).scalar
        guard let current = Self.volume(of: id), abs(current - target) > 0.005 else { return }
        restoring = true
        Self.setVolume(target, of: id)
        lastSetHardware = Self.volume(of: id)
        restoring = false
        readVolume()
        NSLog("AudioLens: restored \(defaultDevice?.name ?? "output") to \(Int(value * 100))%")
    }

    /// From AudioLens's own sliders: becomes the remembered level too, locked or not.
    func setSystemVolume(_ value: Double) {
        let id = CA.defaultOutputDevice()
        let v = min(max(value, 0), 1)
        if let uid = defaultUID { SettingsStore.shared.saveVolume(v, for: uid) }
        restoring = true
        Self.setVolume(physical(v, of: id, trimDB: trimDB).scalar, of: id)
        lastSetHardware = Self.volume(of: id)
        if v > 0, muted { CA.set(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, value: UInt32(0)) }
        restoring = false
        readVolume()
    }

    func setSystemMuted(_ value: Bool) {
        CA.set(CA.defaultOutputDevice(), kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, value: UInt32(value ? 1 : 0))
        readVolume()
    }

    /// Makes a device the system output.
    func makeDefault(_ uid: String) {
        guard let device = device(uid: uid) else { return }
        CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, value: device.objectID)
    }

    /// A device's volume as the user set it, or the level AudioLens remembers for it if it's
    /// not connected.
    func volume(forUID uid: String) -> Double? {
        if uid == defaultUID, let volume { return volume }
        if let device = device(uid: uid), let hw = Self.volume(of: device.objectID) {
            return logical(fromHardware: hw, of: device.objectID, trimDB: SettingsStore.shared.trim(for: uid))
        }
        return SettingsStore.shared.savedVolume(for: uid)
    }

    /// Sets a connected device's volume, or the level it gets when it next connects.
    func setVolume(_ value: Double, forUID uid: String) {
        if uid == defaultUID { return setSystemVolume(value) }
        let v = min(max(value, 0), 1)
        SettingsStore.shared.saveVolume(v, for: uid)
        if let device = device(uid: uid) {
            Self.setVolume(physical(v, of: device.objectID, trimDB: SettingsStore.shared.trim(for: uid)).scalar, of: device.objectID)
        }
    }

    // MARK: - Carrying app levels in the device volume

    /// How many dB the system output's own volume sits above (or below) the user's level.
    ///
    /// AudioLens moves the device volume to the level of the loudest app it adjusts and turns
    /// the quieter ones down from there. The point is what happens when AudioLens isn't
    /// running: taps vanish when it quits or crashes, and apps play at the device's own
    /// volume. With the level carried there, the loudest app keeps exactly the level you
    /// heard, and the others rise only to it, not to full volume.
    private(set) var trimDB: Double = 0

    /// Moves the system output's own volume to the user's level plus `desired` dB, as far as
    /// the device allows, and returns the trim actually applied (0 if the device can't be
    /// measured in dB).
    @discardableResult
    func setTrim(_ desired: Double) -> Double {
        guard let uid = defaultUID else { return trimDB }
        let id = CA.defaultOutputDevice()
        guard abs(desired - trimDB) > 0.25 else { return trimDB }
        guard let level = volume else { return trimDB }
        let (scalar, applied) = physical(level, of: id, trimDB: desired)
        guard abs(applied - trimDB) > 0.25 else { return trimDB }
        restoring = true
        Self.setVolume(scalar, of: id)
        lastSetHardware = Self.volume(of: id)
        restoring = false
        trimDB = applied
        NSLog("AudioLens: system output carries \(String(format: "%+.1f", applied)) dB (hardware \(Int(scalar * 100))%, your level \(Int(level * 100))%)")
        SettingsStore.shared.saveTrim(applied, for: uid)
        readVolume()
        return applied
    }

    /// The user's level for a hardware volume that sits `trimDB` from it.
    private func logical(fromHardware hw: Double, of id: AudioObjectID, trimDB: Double) -> Double {
        guard abs(trimDB) > 0.01, hw > 0.0005, let curve = VolumeCurve(id), let db = curve.decibels(forScalar: hw) else { return hw }
        return curve.scalar(forDecibels: db - trimDB)
    }

    /// The hardware volume for a user level plus `trimDB`, clamped to what the device can do,
    /// and the trim that clamping leaves.
    private func physical(_ level: Double, of id: AudioObjectID, trimDB: Double) -> (scalar: Double, applied: Double) {
        guard abs(trimDB) > 0.01, level > 0.0005, let curve = VolumeCurve(id), let db = curve.decibels(forScalar: level) else { return (level, 0) }
        let target = min(max(db + trimDB, curve.range.lowerBound), curve.range.upperBound)
        return (curve.scalar(forDecibels: target), target - db)
    }

    /// A device's volume curve: how its volume (0…1, as macOS shows it) maps to dB.
    ///
    /// Only the dB→volume translation is used. On the built-in speakers (macOS 27) the
    /// opposite translation follows a different curve and disagrees with the device's own dB
    /// reading (45% reads −20.9 dB but translates to −34.9 dB), so volume→dB is found here by
    /// searching the dB→volume curve instead.
    struct VolumeCurve {
        let device: AudioObjectID
        let range: ClosedRange<Double>

        init?(_ device: AudioObjectID) {
            guard let range = CA.volumeRangeDB(device) else { return nil }
            self.device = device
            self.range = range
            // It must translate and rise from one end to the other, or it can't be searched.
            guard let low = CA.translateVolume(device, kAudioDevicePropertyVolumeDecibelsToScalar, Float32(range.lowerBound)),
                  let high = CA.translateVolume(device, kAudioDevicePropertyVolumeDecibelsToScalar, Float32(range.upperBound)),
                  high > low else { return nil }
        }

        func scalar(forDecibels db: Double) -> Double {
            let clamped = min(max(db, range.lowerBound), range.upperBound)
            let s = CA.translateVolume(device, kAudioDevicePropertyVolumeDecibelsToScalar, Float32(clamped)) ?? 0
            return min(max(Double(s), 0), 1)
        }

        func decibels(forScalar target: Double) -> Double? {
            var lo = range.lowerBound, hi = range.upperBound
            for _ in 0..<32 {
                let mid = (lo + hi) / 2
                if scalar(forDecibels: mid) < target { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
    }

    static func volume(of id: AudioObjectID) -> Double? {
        if CA.has(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput) {
            return Double(CA.get(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, default: Float32(0)))
        }
        if CA.has(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element: 1) {
            return Double(CA.get(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element: 1, default: Float32(0)))
        }
        return nil
    }

    static func setVolume(_ value: Double, of id: AudioObjectID) {
        let v = Float32(min(max(value, 0), 1))
        if CA.has(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput) {
            CA.set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, value: v)
        } else {
            for element: UInt32 in [1, 2] where CA.has(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element: element) {
                CA.set(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element: element, value: v)
            }
        }
    }
}
