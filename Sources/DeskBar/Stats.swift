import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import IOKit.ps
import Sensors

/// Live readings shown in the panel. Fast values refresh every 2 s, network checks
/// (ping) every 10 s, Bluetooth every minute and the public IP every 10 minutes.
@MainActor
final class Stats: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Battery {
        var percent: Int
        var charging: Bool
        var onPower: Bool
        var minutesLeft: Int?  // to empty, or to full while charging
    }

    struct WiFi {
        var on: Bool
        var name: String?      // nil when macOS hides it (no Location access)
        var linkMbps: Int
        var signal: Int        // RSSI in dBm
        var connected: Bool { signal != 0 }
    }

    @Published var battery: Battery?
    @Published var wifi = WiFi(on: false, name: nil, linkMbps: 0, signal: 0)
    @Published var pingMs: Int?
    @Published var cpuPercent: Double = 0
    @Published var cpuTemp: Double?

    @Published var memory: Readers.Memory?
    @Published var storage: (free: Int64, total: Int64)?
    @Published var download: Double = 0   // bytes per second
    @Published var upload: Double = 0
    @Published var publicIP: String?
    @Published var vpn = false
    @Published var power: Readers.Power?
    @Published var topApp: TopAppTracker.TopApp?
    @Published var memoryUsers: [TopAppTracker.MemoryUser] = []
    @Published var cpuUsers: [TopAppTracker.CPUUser] = []
    @Published var ports: [Ports.Port] = []
    @Published var coreUsage: [Double] = []      // 0–100 per core, efficiency cores first
    @Published var diskRead: Double = 0          // bytes per second
    @Published var diskWrite: Double = 0
    @Published var volumes: [Readers.Volume] = []
    @Published var folderSizes: [(name: String, bytes: UInt64)] = []
    @Published var scanningFolders = false
    @Published var gpuPercent: Int?
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var fans: [Int] = []
    @Published var bootTime = Readers.bootTime()
    @Published var micInUse = false
    @Published var cameraInUse = false
    @Published var camerasInUse: [String] = []
    @Published var bluetooth: [Readers.BluetoothDevice] = []

    @Published var cpuHistory = History()
    @Published var tempHistory = History()
    @Published var downHistory = History()
    @Published var upHistory = History()
    @Published var powerHistory = History()
    /// Seconds between graph points; the snapshot mode shortens it.
    var historyInterval: TimeInterval = 10

    private var lastTicks: (UInt32, UInt32, UInt32, UInt32)?
    private var lastBytes: (received: UInt64, sent: UInt64, at: Date)?
    private var lastDisk: (read: UInt64, written: UInt64, at: Date)?
    private var lastCores: [(busy: UInt64, total: UInt64)] = []
    /// Called after every refresh; Smart alerts hooks in here.
    var onRefresh: ((Stats) -> Void)?
    private var lastHistoryPoint = Date.distantPast
    private var historyBuffer: (cpu: [Double], temp: [Double], down: [Double], up: [Double], power: [Double]) = ([], [], [], [], [])
    private let topApps = TopAppTracker()
    private var tick = 0
    private var timers: [Timer] = []
    private let location = CLLocationManager()


    override init() {
        super.init()
        location.delegate = self
        // First readings wait until SwiftUI has finished building the app.
        DispatchQueue.main.async {
            self.refreshFast()
            Task { await self.refreshNetwork() }
            Task { await self.refreshSlow() }
        }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in self.refreshFast() }
            },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { @MainActor in await self.refreshNetwork() }
            },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in await self.refreshSlow() }
            },
        ]
    }

    var locationDenied: Bool {
        [.denied, .restricted].contains(location.authorizationStatus)
    }

    /// Asks for Location access so macOS reveals the Wi-Fi name.
    func requestWiFiName() {
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else {
            openLink("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refreshFast() }
    }

    /// Slow readings (sensors, IORegistry, file system) happen on a background queue; the results
    /// are published together on the main thread so animations never wait on them.
    private var refreshing = false
    private struct Slow {
        var battery: Battery?, wifi: WiFi, temp: Double, memory: Readers.Memory?, power: Readers.Power?
        var gpu: Int?, fans: [Int], mic: Bool, cameras: [String]
        var storage: (free: Int64, total: Int64)?, volumes: [Readers.Volume]?
    }

    func refreshFast() {
        guard !refreshing else { return }
        refreshing = true
        let includeDisks = tick % 15 == 0
        tick += 1
        DispatchQueue.global(qos: .utility).async {
            let slow = Slow(battery: Self.readBattery(), wifi: Self.readWiFi(), temp: sensors_cpu_temperature(),
                            memory: Readers.memory(), power: Readers.power(), gpu: Readers.gpuPercent(),
                            fans: Readers.fanSpeeds(), mic: Readers.micInUse(), cameras: Readers.camerasInUse(),
                            storage: includeDisks ? Readers.storage() : nil, volumes: includeDisks ? Readers.volumes() : nil)
            DispatchQueue.main.async { self.publish(slow) }
        }
    }

    private func publish(_ slow: Slow) {
        refreshing = false
        battery = slow.battery
        wifi = slow.wifi
        if let usage = readCPU() { cpuPercent = usage }
        cpuTemp = slow.temp > 0 ? slow.temp : nil
        memory = slow.memory
        power = slow.power
        gpuPercent = slow.gpu
        thermal = ProcessInfo.processInfo.thermalState
        if fans != slow.fans { fans = slow.fans }
        if micInUse != slow.mic { micInUse = slow.mic }
        if camerasInUse != slow.cameras { camerasInUse = slow.cameras }
        if cameraInUse != !slow.cameras.isEmpty { cameraInUse = !slow.cameras.isEmpty }
        topApp = topApps.sample()
        memoryUsers = topApps.memoryUsers
        cpuUsers = topApps.cpuUsers
        readCores()
        readDisk()
        let newPorts = Ports.read(chargerWatts: power?.chargerWatts, charging: battery?.charging ?? false)
        if newPorts != ports { ports = newPorts }
        readTraffic()
        if let storage = slow.storage { self.storage = storage }
        if let volumes = slow.volumes { self.volumes = volumes }
        recordHistory()
        if Demo.on { applyDemo() }
        onRefresh?(self)
    }

    /// Believable made-up readings for screenshots and the demo video, so nothing from this Mac shows.
    private func applyDemo() {
        let gb: UInt64 = 1_000_000_000
        battery = Battery(percent: 86, charging: false, onPower: false, minutesLeft: 412)
        wifi = WiFi(on: true, name: "Studio", linkMbps: 1200, signal: -52)
        pingMs = 18
        cpuPercent = 12
        cpuTemp = 42
        coreUsage = [22, 18, 15, 12, 9, 7, 6, 4, 3, 2]
        gpuPercent = 3
        fans = []
        thermal = .nominal
        memory = Readers.Memory(used: 98 * gb / 10, total: 16 * gb, pressure: .normal, app: 61 * gb / 10,
                                wired: 22 * gb / 10, compressed: 8 * gb / 10, cached: 31 * gb / 10)
        storage = (free: 214_000_000_000, total: 494_000_000_000)
        volumes = [Readers.Volume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", free: 214_000_000_000,
                                  total: 494_000_000_000, purgeable: 18_000_000_000, isInternal: true, ejectable: false)]
        diskRead = 420_000
        diskWrite = 96_000
        download = 1_250_000
        upload = 180_000
        power = Readers.Power(systemWatts: 6.8, chargerWatts: nil, chargerName: nil, cycles: 112, health: 96, batteryTemp: 31)
        topApp = TopAppTracker.TopApp(name: "Safari", percent: 18, app: nil)
        memoryUsers = [("Safari", 21), ("Xcode", 18), ("Final Cut Pro", 12), ("Music", 4)].enumerated().map { i, user in
            TopAppTracker.MemoryUser(name: user.0, bytes: UInt64(user.1) * gb / 10, app: nil, pid: pid_t(9000 + i))
        }
        cpuUsers = [("Safari", 18.0, 0.4), ("Xcode", 12.0, 0.3), ("Final Cut Pro", 8.0, 0.2)].enumerated().map { i, user in
            TopAppTracker.CPUUser(name: user.0, percent: user.1, share: user.2, app: nil, pid: pid_t(9000 + i))
        }
        ports = []
        micInUse = false
        cameraInUse = false
        camerasInUse = []
        bluetooth = []
        bootTime = Date().addingTimeInterval(-3 * 86_400)   // "up 3 days"
    }


    func refreshNetwork() async {
        async let ping = Self.ping()
        pingMs = Demo.on ? 18 : await ping
        vpn = Readers.vpnActive()
    }

    private var lastIPCheck = Date.distantPast
    private var lastIPNetwork: String?

    func refreshSlow() async {
        bluetooth = Demo.on ? [] : await Readers.bluetooth()
        // Public IP every 10 minutes, or straight away after switching networks.
        if Date().timeIntervalSince(lastIPCheck) > 600 || wifi.name != lastIPNetwork {
            lastIPCheck = Date()
            lastIPNetwork = wifi.name
            publicIP = Demo.on ? "203.0.113.24" : await Readers.publicIP()
        }
    }

    /// Sizes of the folders in your home folder, on request (it can take a minute).
    func scanFolders() async {
        guard !scanningFolders else { return }
        scanningFolders = true
        folderSizes = await Readers.homeFolderSizes()
        scanningFolders = false
    }

    private func readCores() {
        let now = Readers.coreTicks()
        if now.count == lastCores.count {
            coreUsage = zip(now, lastCores).map { current, last in
                let total = Double(current.total &- last.total)
                return total > 0 ? Double(current.busy &- last.busy) / total * 100 : 0
            }
        }
        lastCores = now
    }

    private func readDisk() {
        let now = Readers.diskBytes()
        let date = Date()
        if let last = lastDisk, now.read >= last.read, now.written >= last.written {
            let seconds = date.timeIntervalSince(last.at)
            if seconds > 0 {
                diskRead = Double(now.read - last.read) / seconds
                diskWrite = Double(now.written - last.written) / seconds
            }
        }
        lastDisk = (now.read, now.written, date)
    }

    private func readTraffic() {
        let now = Readers.networkBytes()
        let date = Date()
        if let last = lastBytes, now.received >= last.received, now.sent >= last.sent {
            let seconds = date.timeIntervalSince(last.at)
            if seconds > 0 {
                download = Double(now.received - last.received) / seconds
                upload = Double(now.sent - last.sent) / seconds
            }
        }
        lastBytes = (now.received, now.sent, date)
    }

    /// Averages the 2-second readings into one graph point per `historyInterval`.
    private func recordHistory() {
        historyBuffer.cpu.append(cpuPercent)
        if let cpuTemp { historyBuffer.temp.append(cpuTemp) }
        historyBuffer.down.append(download)
        historyBuffer.up.append(upload)
        if let watts = power?.systemWatts { historyBuffer.power.append(watts) }
        guard Date().timeIntervalSince(lastHistoryPoint) >= historyInterval else { return }
        lastHistoryPoint = Date()
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        if let v = average(historyBuffer.cpu) { cpuHistory.add(v) }
        if let v = average(historyBuffer.temp) { tempHistory.add(v) }
        if let v = average(historyBuffer.down) { downHistory.add(v) }
        if let v = average(historyBuffer.up) { upHistory.add(v) }
        if let v = average(historyBuffer.power) { powerHistory.add(v) }
        historyBuffer = ([], [], [], [], [])
    }

    // MARK: Readers

    nonisolated private static func readBattery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info["Type"] as? String == "InternalBattery",
                  let current = info["Current Capacity"] as? Int,
                  let max = info["Max Capacity"] as? Int, max > 0 else { continue }
            let charging = info["Is Charging"] as? Bool ?? false
            let minutes = info[charging ? "Time to Full Charge" : "Time to Empty"] as? Int
            return Battery(percent: current * 100 / max,
                           charging: charging,
                           onPower: info["Power Source State"] as? String == "AC Power",
                           minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil  // desktop Mac
    }

    nonisolated private static func readWiFi() -> WiFi {
        guard let iface = CWWiFiClient.shared().interface() else {
            return WiFi(on: false, name: nil, linkMbps: 0, signal: 0)
        }
        return WiFi(on: iface.powerOn(), name: iface.ssid(),
                    linkMbps: Int(iface.transmitRate()), signal: iface.rssiValue())
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let now = info.cpu_ticks  // user, system, idle, nice
        defer { lastTicks = now }
        guard let last = lastTicks else { return nil }
        let busy = Double((now.0 &- last.0) &+ (now.1 &- last.1) &+ (now.3 &- last.3))
        let total = busy + Double(now.2 &- last.2)
        return total > 0 ? busy / total * 100 : nil
    }

    /// Round trip to Cloudflare's DNS server, as a rough "is the internet fast" check.
    private static func ping() async -> Int? {
        let output = await Shell.run("/sbin/ping", ["-c", "1", "-t", "2", "1.1.1.1"])
        guard let range = output.range(of: #"time=([\d.]+)"#, options: .regularExpression) else { return nil }
        return Double(output[range].dropFirst(5)).map { Int($0.rounded()) }
    }

}

private func openLink(_ link: String) {
    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
}
