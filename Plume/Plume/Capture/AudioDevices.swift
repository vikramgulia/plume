import Foundation
import CoreAudio

struct AudioInputDevice: Equatable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool
    let isBuiltIn: Bool
}

/// Picks which microphone Plume records from. Bluetooth headphones switch to the low-quality
/// hands-free profile as soon as their microphone is opened, which mutes or degrades what is
/// playing in them, so by default Plume uses the Mac's own microphone instead when it has one.
enum AudioInputChoice {
    /// - preferredUID: a microphone chosen in Settings, or nil for automatic.
    /// - Returns: the device to use, or nil to leave the system default alone.
    static func pick(preferredUID: String?, devices: [AudioInputDevice], defaultID: AudioDeviceID?) -> AudioInputDevice? {
        if let preferredUID, let chosen = devices.first(where: { $0.uid == preferredUID }) {
            return chosen
        }
        guard let defaultDevice = devices.first(where: { $0.id == defaultID }) else { return nil }
        if defaultDevice.isBluetooth, let builtIn = devices.first(where: { $0.isBuiltIn }) {
            return builtIn
        }
        return defaultDevice
    }
}

enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(inputDevice(for:))
    }

    static func defaultInputID() -> AudioDeviceID? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return (id == nil || id == 0) ? nil : id
    }

    /// The microphone to record from, given the user's setting.
    static func chooseInput(preferredUID: String?) -> AudioInputDevice? {
        AudioInputChoice.pick(preferredUID: preferredUID, devices: inputDevices(), defaultID: defaultInputID())
    }

    private static func inputDevice(for id: AudioDeviceID) -> AudioInputDevice? {
        guard inputChannelCount(id) > 0 else { return nil }
        let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
        return AudioInputDevice(
            id: id,
            uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
            name: string(id, kAudioObjectPropertyName) ?? "Unknown",
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
            isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
