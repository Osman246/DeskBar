import Foundation
import UserNotifications

/// Sends a macOS notification when something needs attention. Each alert fires once, then
/// stays quiet until the problem has cleared, and at most once every 30 minutes.
@MainActor
final class SmartAlerts: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case memory, heat, battery, disk, devices
        var id: String { rawValue }

        var title: String {
            switch self {
            case .memory: "Memory full"
            case .heat: "Mac running hot"
            case .battery: "Battery low"
            case .disk: "Disk almost full"
            case .devices: "Headphones or mouse low"
            }
        }

        var detail: String {
            switch self {
            case .memory: "When macOS reports high memory pressure"
            case .heat: "When the Mac starts slowing down to cool off"
            case .battery: "At 20% and 10% while unplugged"
            case .disk: "When less than 10 GB is free"
            case .devices: "When a Bluetooth device drops below 15%"
            }
        }
    }

    @Published private(set) var enabled: Set<Kind>
    @Published private(set) var permissionDenied = false

    private var active: Set<String> = []          // problems currently going on
    private var lastSent: [String: Date] = [:]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "alerts") ?? Kind.allCases.map(\.rawValue)
        enabled = Set(saved.compactMap(Kind.init))
    }

    var summary: String { enabled.isEmpty ? "Off" : "\(enabled.count) on" }

    func isOn(_ kind: Kind) -> Bool { enabled.contains(kind) }

    func set(_ kind: Kind, _ on: Bool) {
        if on { enabled.insert(kind) } else { enabled.remove(kind) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "alerts")
        if on { requestPermission() }
    }

    func requestPermission() {
        guard !enabled.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.permissionDenied = !granted }
        }
    }

    /// Called after each refresh with the latest readings.
    func check(_ stats: Stats) {
        if let battery = stats.battery, !battery.onPower {
            evaluate(.battery, key: "battery10", when: battery.percent <= 10,
                     body: "\(battery.percent)% left. Plug in soon.")
            evaluate(.battery, key: "battery20", when: battery.percent <= 20 && battery.percent > 10,
                     body: "\(battery.percent)% left" + (battery.minutesLeft.map { ", about \($0 / 60)h \($0 % 60)m." } ?? "."))
        } else {
            clear("battery10")
            clear("battery20")
        }

        let top = stats.memoryUsers.first.map { " \($0.name) is using \(Format.bytes($0.bytes))." } ?? ""
        evaluate(.memory, key: "memory", when: stats.memory?.pressure == .high,
                 body: "Apps may slow down." + top)

        let hot = stats.thermal == .serious || stats.thermal == .critical
        evaluate(.heat, key: "heat", when: hot,
                 body: "macOS is slowing the chip down to cool it" + (stats.cpuTemp.map { " (\(Int($0))°C)." } ?? ".")
                     + (stats.topApp.map { " \($0.name) is the busiest app." } ?? ""))

        if let disk = stats.storage {
            evaluate(.disk, key: "disk", when: disk.free < 10_000_000_000,
                     body: "Only \(Format.bytes(UInt64(disk.free))) free. Try Clean up in DeskBar.")
        }

        for device in stats.bluetooth {
            let lowest = device.levels.min() ?? 100
            evaluate(.devices, key: "bt-\(device.name)", when: lowest < 15,
                     title: "\(device.name) low", body: "Battery at \(lowest)%.")
        }
    }

    private func evaluate(_ kind: Kind, key: String, when condition: Bool, title: String? = nil, body: String) {
        guard condition else { return clear(key) }
        guard enabled.contains(kind), !active.contains(key) else { return }
        active.insert(key)
        if let last = lastSent[key], Date().timeIntervalSince(last) < 1800 { return }
        lastSent[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = title ?? kind.title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key + "\(Date().timeIntervalSince1970)",
                                                                     content: content, trigger: nil))
        HistoryStore.shared.logAlert(title: content.title, body: body)
    }

    private func clear(_ key: String) { active.remove(key) }
}
