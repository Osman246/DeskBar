import AppKit
import CoreAudio
import CoreMediaIO
import Darwin
import IOKit
import Sensors

/// One-shot system readings. Everything here is cheap enough to call every couple of seconds
/// except where noted.
enum Readers {
    // MARK: Memory

    struct Memory {
        var used: UInt64
        var total: UInt64
        var pressure: Pressure
        var app: UInt64          // memory apps have asked for
        var wired: UInt64        // locked in by macOS itself
        var compressed: UInt64   // squeezed to make room
        var cached: UInt64       // recently used files, freed on demand
        enum Pressure: String { case normal = "Normal", moderate = "Moderate", high = "High" }
    }

    /// "Used" matches Activity Monitor: app memory + wired + compressed.
    static func memory() -> Memory? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(info.internal_page_count) - UInt64(info.purgeable_count)
        let used = (app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * page
        let cached = (UInt64(info.external_page_count) + UInt64(info.purgeable_count)) * page

        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        let pressure: Memory.Pressure = level >= 4 ? .high : level == 2 ? .moderate : .normal
        return Memory(used: used, total: ProcessInfo.processInfo.physicalMemory, pressure: pressure,
                      app: app * page, wired: UInt64(info.wire_count) * page,
                      compressed: UInt64(info.compressor_page_count) * page, cached: cached)
    }

    // MARK: Storage

    static func storage() -> (free: Int64, total: Int64)? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        guard let free = values?.volumeAvailableCapacityForImportantUsage,
              let total = values?.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }

    // MARK: Network traffic

    /// Total bytes received and sent on physical interfaces (Wi-Fi and Ethernet) since boot.
    /// Uses the 64-bit counters, which don't wrap at 4 GB.
    static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var received: UInt64 = 0, sent: UInt64 = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil,
                       String(cString: nameBuffer).hasPrefix("en") {
                        received += info.ifm_data.ifi_ibytes
                        sent += info.ifm_data.ifi_obytes
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }

    /// A VPN shows up as a tunnel interface with an IPv4 address.
    static func vpnActive() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard ["utun", "ipsec", "ppp"].contains(where: name.hasPrefix),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            return true
        }
        return false
    }

    /// Asks ipify for the address the internet sees. Network call; run every few minutes.
    static func publicIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > 45 ? nil : text
    }

    // MARK: Battery and power

    struct Power {
        var systemWatts: Double?    // what the Mac is drawing right now
        var chargerWatts: Int?      // rating of the plugged-in charger
        var chargerName: String?
        var cycles: Int?
        var health: Int?            // max capacity vs. design, in %
        var batteryTemp: Double?    // °C
    }

    static func power() -> Power? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let info = properties?.takeRetainedValue() as? [String: Any] else { return nil }

        var power = Power()
        if let telemetry = info["PowerTelemetryData"] as? [String: Any], let load = telemetry["SystemLoad"] as? Int, load > 0 {
            power.systemWatts = Double(load) / 1000
        } else if let amps = info["InstantAmperage"] as? Int, let volts = info["Voltage"] as? Int {
            power.systemWatts = abs(Double(amps) * Double(volts)) / 1_000_000
        }
        if info["ExternalConnected"] as? Bool == true, let adapter = info["AdapterDetails"] as? [String: Any] {
            power.chargerWatts = adapter["Watts"] as? Int
            power.chargerName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
        }
        power.cycles = info["CycleCount"] as? Int
        if let max = info["AppleRawMaxCapacity"] as? Int, let design = info["DesignCapacity"] as? Int, design > 0 {
            power.health = min(100, max * 100 / design)
        }
        if let temp = info["Temperature"] as? Int { power.batteryTemp = Double(temp) / 100 }
        return power
    }

    // MARK: GPU, fans, uptime

    static func gpuPercent() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let usage = stats["Device Utilization %"] as? Int {
                best = max(best ?? 0, usage)
            }
        }
        return best
    }

    static func fanSpeeds() -> [Int] {
        var rpm = [Double](repeating: 0, count: 4)
        let count = Int(sensors_fan_speeds(&rpm, 4))
        return rpm.prefix(min(count, 4)).map { Int($0.rounded()) }
    }

    static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }

    // MARK: CPU cores

    /// How many of the first cores are efficiency cores (they're listed before the performance cores).
    static let efficiencyCores: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &count, &size, nil, 0) == 0 ? Int(count) : 0
    }()

    /// Cumulative busy and total ticks for each core; diff two readings to get usage.
    static func coreTicks() -> [(busy: UInt64, total: UInt64)] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(cpuCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            return (user + system + nice, user + system + nice + idle)
        }
    }

    // MARK: Disks

    /// Total bytes read and written by all disks since boot.
    static func diskBytes() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? UInt64) ?? 0
            written += (stats["Bytes (Write)"] as? UInt64) ?? 0
        }
        return (read, written)
    }

    struct Volume: Identifiable {
        var url: URL
        var name: String
        var free: Int64
        var total: Int64
        var purgeable: Int64      // space macOS can free on its own (caches, iCloud copies)
        var isInternal: Bool
        var ejectable: Bool
        var id: URL { url }
    }

    static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                                      .volumeIsEjectableKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable == true,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let important = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            let plain = Int64(v.volumeAvailableCapacity ?? 0)
            let isRoot = v.volumeIsRootFileSystem == true
            return Volume(url: url, name: isRoot ? "Macintosh HD" : (v.volumeLocalizedName ?? url.lastPathComponent),
                          free: important, total: Int64(total), purgeable: max(0, important - plain),
                          isInternal: v.volumeIsInternal ?? isRoot, ejectable: v.volumeIsEjectable == true || v.volumeIsInternal == false)
        }
        .sorted { $0.isInternal && !$1.isInternal }
    }

    /// Sizes of the folders in your home folder, biggest first. Slow (seconds to a minute).
    /// macOS may ask permission the first time DeskBar looks in Desktop, Documents or Downloads.
    static func homeFolderSizes() async -> [(name: String, bytes: UInt64)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return await withTaskGroup(of: (String, UInt64).self) { group in
            for folder in folders {
                group.addTask {
                    let output = await Shell.run("/usr/bin/du", ["-sk", folder.path])
                    let kb = UInt64(output.split(separator: "\t").first ?? "") ?? 0
                    return (folder.lastPathComponent, kb * 1024)
                }
            }
            var sizes: [(String, UInt64)] = []
            for await entry in group where entry.1 > 0 { sizes.append(entry) }
            return sizes.sorted { $0.1 > $1.1 }.map { (name: $0.0, bytes: $0.1) }
        }
    }

    // MARK: Camera and microphone

    /// True while any app is recording from the default microphone.
    static func micInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    /// Names of the cameras currently in use (e.g. "FaceTime HD Camera", "iPhone Camera").
    static func camerasInUse() -> [String] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var running: UInt32 = 0, got: UInt32 = 0
            var runningAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                           mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                           mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            guard CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr,
                  running != 0 else { return nil }
            // Continuity Camera (an iPhone as webcam) reports no transport type, unlike the built-in
            // camera ('bltn') and USB webcams ('usb '); the phone's name can be anything ("S Phone").
            // Report it with a "Continuity:" prefix.
            var transportAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyTransportType),
                                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var transport: UInt32 = 0
            CMIOObjectGetPropertyData(device, &transportAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &transport)
            let virtualNames = ["virtual", "obs", "snap camera", "camo"]
            var nameAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
                                                        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var name: Unmanaged<CFString>?
            let label = CMIOObjectGetPropertyData(device, &nameAddress, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &got, &name) == noErr
                ? (name?.takeRetainedValue() as String?) ?? "Camera" : "Camera"
            let continuity = (transport == 0 || transport == 0x2020_2020 || transport == 0x6363_776C || transport == 0x6363_7764)
                && !virtualNames.contains { label.lowercased().contains($0) }
            return continuity ? "Continuity:" + label : label
        }
    }

    /// True while any app is using any camera.
    static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in devices {
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }

    // MARK: Bluetooth

    struct BluetoothDevice: Identifiable {
        var name: String
        var battery: String?   // e.g. "L 80% · R 75% · Case 40%"
        var levels: [Int] = [] // the same numbers, for alerts
        var id: String { name }
    }

    /// Connected Bluetooth devices with their battery levels. Slow (~1 s); run every minute.
    static func bluetooth() async -> [BluetoothDevice] {
        let output = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = root["device_connected"] as? [[String: Any]] else { return [] }
        return connected.flatMap { entry in
            entry.map { name, value -> BluetoothDevice in
                let info = value as? [String: Any] ?? [:]
                let parts: [(String, String)] = [("", "device_batteryLevelMain"), ("L ", "device_batteryLevelLeft"),
                                                 ("R ", "device_batteryLevelRight"), ("Case ", "device_batteryLevelCase")]
                let levels = parts.compactMap { label, key in (info[key] as? String).map { label + $0 } }
                // The case often reports 0% while it's closed, so it doesn't count towards "low".
                let numbers = parts.dropLast().compactMap { _, key in
                    (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) }
                }
                return BluetoothDevice(name: name.trimmingCharacters(in: .whitespaces),
                                       battery: levels.isEmpty ? nil : levels.joined(separator: " · "), levels: numbers)
            }
        }
        .sorted { $0.name < $1.name }
    }

}

/// Finds which apps use the most CPU and memory, counting helper processes (browser
/// tabs, renderers) towards the app they belong to.
@MainActor
final class TopAppTracker {
    struct TopApp {
        var name: String
        var percent: Double   // of one core, like Activity Monitor
        var app: NSRunningApplication?
    }

    struct MemoryUser: Identifiable {
        var name: String
        var bytes: UInt64     // "Memory" column in Activity Monitor (physical footprint)
        var app: NSRunningApplication?
        var pid: pid_t
        var id: pid_t { pid }
    }

    struct CPUUser: Identifiable {
        var name: String
        var percent: Double   // of one core
        var share: Double     // of all CPU time used, 0–1
        var app: NSRunningApplication?
        var pid: pid_t
        var id: pid_t { pid }
    }

    /// Biggest memory users from the last `sample()`.
    private(set) var memoryUsers: [MemoryUser] = []
    /// Busiest apps from the last `sample()`; their share of CPU time is used to estimate power.
    private(set) var cpuUsers: [CPUUser] = []

    private var lastTimes: [pid_t: UInt64] = [:]
    private var lastSample = DispatchTime.now().uptimeNanoseconds
    private let ticksToNanos: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private let responsible: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                  "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }

    func sample() -> TopApp? {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - lastSample)
        lastSample = now

        var times: [pid_t: UInt64] = [:]
        var usageByOwner: [pid_t: Double] = [:]
        var memoryByOwner: [pid_t: UInt64] = [:]

        for pid in pids.prefix(max(0, count)) where pid > 0 {
            let owner = { let o = responsible?(pid) ?? pid; return o > 0 ? o : pid }()
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if ok == 0 { memoryByOwner[owner, default: 0] += usage.ri_phys_footprint }

            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let total = info.pti_total_user + info.pti_total_system
            times[pid] = total
            guard let previous = lastTimes[pid], total >= previous, elapsed > 0 else { continue }
            usageByOwner[owner, default: 0] += Double(total - previous) * ticksToNanos / elapsed * 100
        }
        lastTimes = times
        let totalCPU = usageByOwner.values.reduce(0, +)
        cpuUsers = usageByOwner.filter { $0.value >= 0.5 }.sorted { $0.value > $1.value }.prefix(4).map { pid, percent in
            let app = NSRunningApplication(processIdentifier: pid)
            return CPUUser(name: name(of: pid, app: app), percent: percent, share: totalCPU > 0 ? percent / totalCPU : 0,
                           app: app?.activationPolicy == .regular ? app : nil, pid: pid)
        }
        memoryUsers = memoryByOwner.sorted { $0.value > $1.value }.prefix(6).map { pid, bytes in
            let app = NSRunningApplication(processIdentifier: pid)
            return MemoryUser(name: name(of: pid, app: app), bytes: bytes,
                              app: app?.activationPolicy == .regular ? app : nil, pid: pid)
        }

        guard let (pid, percent) = usageByOwner.max(by: { $0.value < $1.value }) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return TopApp(name: name(of: pid, app: app), percent: percent, app: app?.activationPolicy == .regular ? app : nil)
    }

    private func name(of pid: pid_t, app: NSRunningApplication?) -> String {
        if let name = app?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(pid)" : name
    }
}

/// A rolling hour of samples for the small graphs.
struct History {
    var values: [Double] = []
    static let capacity = 360   // one point every 10 s

    mutating func add(_ value: Double) {
        values.append(value)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }
}
