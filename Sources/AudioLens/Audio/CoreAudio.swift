import AudioToolbox
import CoreAudio
import Foundation

/// Small typed wrappers over the Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var a = address(selector, scope, element)
        return AudioObjectHasProperty(object, &a)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, default value: T) -> T {
        var a = address(selector, scope, element)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &result)
        return status == noErr ? result : value
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, value: T) -> OSStatus {
        var a = address(selector, scope, element)
        var v = value
        return AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, buffer) == noErr else { return [] }
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return (0..<count).map { typed[$0] }
    }

    /// Calls `handler` on the main queue whenever the property changes. Keep the returned
    /// token to remove it.
    final class Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock

        init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
              handler: @escaping @MainActor () -> Void) {
            self.object = object
            self.address = CA.address(selector, scope, element)
            self.block = { _, _ in MainActor.assumeIsolated { handler() } }
            guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        }

        deinit {
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }

    // MARK: - Devices

    static func deviceIDs() -> [AudioObjectID] {
        array(system, kAudioHardwarePropertyDevices, of: AudioObjectID.self)
    }

    static func device(uid: String) -> AudioObjectID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultOutputDevice() -> AudioObjectID {
        get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        array(device, kAudioDevicePropertyStreams, scope, of: AudioStreamID.self).count
    }

    static func channelCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transport(_ device: AudioObjectID) -> UInt32 {
        get(device, kAudioDevicePropertyTransportType, default: UInt32(0))
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        get(device, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
    }

    // MARK: - Processes

    static func processObjects() -> [AudioObjectID] {
        array(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }
}
