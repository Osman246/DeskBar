import AppKit
import CoreAudio
import IOKit

/// What's plugged into each physical port, read from the port controllers in the IORegistry.
enum Ports {
    enum Side: String { case left = "Left", right = "Right" }

    struct Port: Identifiable, Equatable {
        var id: String          // IORegistry port name, e.g. "Port-USB-C@2"
        var name: String        // "Thunderbolt 4"
        var side: Side
        var z: Double           // position along the side of the 3D model (cm, negative = back)
        var connected: Bool
        var detail: String      // "Studio Display · 5K", "Charging · 20 W", "Empty"
    }

    /// Physical layout of the 14-inch M4 MacBook Pro (Mac16,1). The USB-C numbering was
    /// confirmed by plugging monitors into each port; z values come from the 3D model.
    static let layout: [(id: String, name: String, side: Side, z: Double)] = [
        ("Port-MagSafe 3@1", "MagSafe 3", .left, -8.2),
        ("Port-USB-C@2", "Thunderbolt 4", .left, -6.4),
        ("Port-USB-C@1", "Thunderbolt 4", .left, -4.9),
        ("headphones", "Headphones", .left, -3.65),
        ("Port-HDMI@3", "HDMI", .right, -8.25),
        ("Port-USB-C@4", "Thunderbolt 4", .right, -6.4),
        ("Port-SD Card@1", "SD card", .right, -4.4),
    ]

    static func read(chargerWatts: Int?, charging: Bool) -> [Port] {
        var states: [String: (active: Bool, transports: [String])] = [:]
        for cls in ["AppleHPMInterfaceType10", "AppleHPMInterfaceType11", "AppleHDMIPortController", "AppleSDXCSlot"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iterator) == KERN_SUCCESS else { continue }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                func property(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                guard let id = property("PortDescription") as? String else { continue }
                states[id] = ((property("ConnectionActive") as? Bool) ?? false, (property("TransportsActive") as? [String]) ?? [])
            }
            IOObjectRelease(iterator)
        }

        let displays = externalDisplays()
        let displayPorts = layout.filter { states[$0.id]?.transports.contains("DisplayPort") == true }.count

        return layout.map { slot in
            if slot.id == "headphones" {
                let plugged = headphonesPlugged()
                return Port(id: slot.id, name: slot.name, side: slot.side, z: slot.z, connected: plugged,
                            detail: plugged ? "Connected" : "Empty")
            }
            let state = states[slot.id]
            let active = state?.active ?? false
            var detail = "Empty"
            if active {
                let transports = state?.transports ?? []
                if slot.id.hasPrefix("Port-MagSafe") {
                    detail = charging ? "Charging" : "Connected"
                    if let watts = chargerWatts { detail += " · \(watts) W" }
                } else if slot.id.hasPrefix("Port-SD") {
                    detail = "Card inserted"
                } else if transports.contains("DisplayPort") {
                    // Name the display when every external display is the same model (or there's one).
                    if let first = displays.first, displays.count == displayPorts, displays.allSatisfy({ $0 == first }) {
                        detail = first
                    } else {
                        detail = "Display"
                    }
                } else if transports.contains("CIO") {
                    detail = "Thunderbolt device"
                } else if transports.contains("USB3") || transports.contains("USB2") {
                    detail = "USB device"
                } else if transports == ["CC"] {
                    detail = "Charger"
                } else {
                    detail = "Connected"
                }
            }
            return Port(id: slot.id, name: slot.name, side: slot.side, z: slot.z, connected: active, detail: detail)
        }
    }

    /// External displays as "Name · 4K".
    private static func externalDisplays() -> [String] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) == 0 else { return nil }
            let width = CGDisplayPixelsWide(id) * Int(screen.backingScaleFactor)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixels = max(width, mode?.pixelWidth ?? 0)
            let resolution = pixels >= 5000 ? "5K" : pixels >= 3800 ? "4K" : pixels >= 2500 ? "QHD" : "HD"
            // Identical monitors are named "Monitor (1)", "Monitor (2)"; drop the number.
            let name = DisplayNames.friendly(screen.localizedName)
            return "\(name) · \(resolution)"
        }
    }

    /// The built-in audio output switches its data source to headphones when something is plugged in.
    private static func headphonesPlugged() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return false }
        for device in devices {
            var transport = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var kind: UInt32 = 0
            var kindSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transport, 0, nil, &kindSize, &kind) == noErr,
                  kind == kAudioDeviceTransportTypeBuiltIn else { continue }
            var source = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                    mScope: kAudioDevicePropertyScopeOutput,
                                                    mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &source, 0, nil, &valueSize, &value) == noErr,
               value == 0x6864_706E /* 'hdpn' */ { return true }
        }
        return false
    }
}

extension NSScreen {
    var isBuiltIn: Bool {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }
}

/// Display names as you know them. Some monitors report an internal model code instead of their
/// retail name; add those to `known`. The "(1)"/"(2)" macOS adds to identical monitors is dropped.
enum DisplayNames {
    private static let known: [String: String] = [:]   // model code → retail name

    static func friendly(_ name: String) -> String {
        let base = name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        return known[base] ?? base
    }
}
