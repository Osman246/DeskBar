import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's sound outputs: which one is playing, switching between them, and volume.
@MainActor
final class SoundOutput: ObservableObject {
    struct Device: Identifiable {
        var id: AudioDeviceID
        var name: String
        var icon: String
    }

    @Published var devices: [Device] = []
    @Published var current: AudioDeviceID = 0
    @Published var volume: Double = 0.5
    @Published var hasVolume = false

    var currentName: String { devices.first { $0.id == current }?.name ?? "–" }
    var summary: String { hasVolume ? "\(currentName) · \(Int((volume * 100).rounded()))%" : currentName }

    func refresh() {
        current = Self.defaultOutput() ?? 0
        devices = Self.allDeviceIDs().compactMap { id in
            guard Self.outputChannels(id) > 0, let name = Self.name(id) else { return nil }
            let transport = Self.transport(id)
            // Skip aggregate and virtual helper devices (e.g. from screen recorders) unless selected.
            if [kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual].contains(transport), id != current { return nil }
            return Device(id: id, name: name, icon: Self.icon(transport, name: name))
        }
        if let level = Self.volume(of: current) {
            volume = level
            hasVolume = true
        } else {
            hasVolume = false
        }
    }

    func select(_ id: AudioDeviceID) {
        var device = id
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = Self.address(selector)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        }
        refresh()
    }

    func setVolume(_ value: Double) {
        volume = value
        var level = Float32(value)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(current, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func icon(_ transport: UInt32, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods") || lower.contains("headphone") || lower.contains("bose") { return "headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "hifispeaker"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        default: return "speaker.wave.2"
        }
    }

    private static func volume(of id: AudioDeviceID) -> Double? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &level) == noErr ? Double(level) : nil
    }
}
