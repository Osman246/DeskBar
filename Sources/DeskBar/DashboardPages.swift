import AppKit
import Charts
import SceneKit
import SwiftUI

private let gridColumns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

private func externalScreens() -> [NSScreen] {
    NSScreen.screens.filter {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false
    }
}

// MARK: Overview

/// The window's own 3D scene: larger than the panel's, no opening animation. Released with the page.
@MainActor
final class DashboardScene: ObservableObject {
    let mac: MacScene = {
        let scene = MacScene(size: CGSize(width: 880, height: 440))
        scene.playsIntro = false
        scene.frameRate = 30
        return scene
    }()
}

struct OverviewPage: View {
    let model: AppModel
    @ObservedObject var stats: Stats
    @StateObject private var scene = DashboardScene()
    @StateObject private var history = HistoryModel()

    init(model: AppModel) {
        self.model = model
        stats = model.stats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DeskStage(mac: scene.mac, stats: stats)
            LazyVGrid(columns: gridColumns, spacing: 12) {
                Metric(title: "CPU", value: "\(Int(stats.cpuPercent.rounded()))", unit: "%",
                       detail: [stats.cpuTemp.map { "\(Int($0.rounded()))°C" }, stats.fans.first.map { $0 == 0 ? "fan off" : "fan \($0) rpm" }]
                           .compactMap { $0 }.joined(separator: " · "),
                       fraction: stats.cpuPercent / 100)
                if let memory = stats.memory {
                    Metric(title: "Memory", value: Format.bytes(memory.used), detail: "of \(Format.bytes(memory.total)) · pressure \(memory.pressure.rawValue.lowercased())",
                           fraction: Double(memory.used) / Double(memory.total), tint: memory.pressure == .normal ? .purple : .orange)
                }
                if let disk = stats.storage {
                    Metric(title: "Storage", value: Format.bytes(UInt64(disk.free)), unit: "free", detail: "of \(Format.bytes(UInt64(disk.total)))",
                           fraction: 1 - Double(disk.free) / Double(disk.total), tint: .teal)
                }
                if let battery = stats.battery {
                    Metric(title: "Battery", value: "\(battery.percent)", unit: "%",
                           detail: battery.charging ? "Charging" + (stats.power?.chargerWatts.map { " · \($0) W" } ?? "") : battery.onPower ? "Plugged in" : "On battery",
                           fraction: Double(battery.percent) / 100, tint: battery.percent <= 20 && !battery.onPower ? .red : .green)
                }
                Metric(title: "Network", value: Format.rate(stats.download),
                       detail: stats.wifi.connected ? "\(stats.wifi.name ?? "Wi-Fi") · \(stats.pingMs.map { "\($0) ms" } ?? "no internet")" : "Not connected")
            }
            GroupSection("Today", accessory: { Text(todaySummary) }) {
                if history.samples.count < 3 {
                    CollectingHistory()
                } else {
                    HistoryChart(samples: history.samples, value: { $0.cpu }, format: { "\(Int($0))%" }, yMax: 100, range: .day,
                                 appsAt: { history.apps(at: $0, bucket: 60) }, height: 110)
                }
            }
        }
        .onAppear { history.load(.day) }
    }

    /// "6 h 12 min at your desk · hottest 78°C at 2:40 pm (DaVinci Resolve) · 2 charges"
    private var todaySummary: String {
        let samples = history.samples
        guard samples.count >= 3 else { return "" }
        var parts: [String] = []
        let deskMinutes = samples.filter { $0.displays > 0 }.count
        if deskMinutes > 0 { parts.append("\(Duration.text(Double(deskMinutes * 60))) at your desk") }
        if let hottest = samples.filter({ $0.temperature != nil }).max(by: { $0.temperature! < $1.temperature! }) {
            let app = history.apps(at: hottest.date, bucket: 60).first.map { " (\($0.name))" } ?? ""
            parts.append("hottest \(Int(hottest.temperature!.rounded()))°C at \(hottest.date.formatted(date: .omitted, time: .shortened))\(app)")
        }
        let charges = zip(samples, samples.dropFirst()).filter { !$0.0.charging && $0.1.charging }.count
        if charges > 0 { parts.append("\(charges) charge\(charges == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// The 3D desk at window size, with a MacBook / Desk switch.
struct DeskStage: View {
    static var still: NSImage?
    @ObservedObject var mac: MacScene
    @ObservedObject var stats: Stats

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let still = DeskStage.still {
                    Image(nsImage: still).resizable()   // snapshot tests
                } else {
                    MacSceneView(mac: mac).opacity(mac.loaded ? 1 : 0)
                }
            }
            .aspectRatio(mac.size.width / mac.size.height, contentMode: .fit)
            if mac.modelMissing && DeskStage.still == nil {
                FlatMac(mac: mac)
            } else if !mac.loaded && DeskStage.still == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(alignment: .bottom) {
                HStack(spacing: 6) {
                    ForEach(mac.pills) { pill in
                        Label { Text(pill.text) } icon: { Circle().fill(pill.color).frame(width: 6, height: 6) }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                Spacer()
                Segments(selection: Binding(get: { mac.mode == .desk }, set: { if $0 != (mac.mode == .desk) { mac.toggleDesk() } }),
                         options: [false, true]) {
                    Image(systemName: $0 ? "display.2" : "laptopcomputer")
                        .accessibilityLabel($0 ? "Desk" : "MacBook")
                }
                .fixedSize()
                .help("Show your MacBook or your whole desk")
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .onAppear { mac.loadIfNeeded(); push() }
        .onChange(of: mac.loaded) { _, loaded in
            push()
            if loaded && !externalScreens().isEmpty { mac.toggleDesk() }   // with monitors, open on the whole desk
        }
        .onChange(of: stats.cpuTemp) { _, _ in push() }
        .onChange(of: stats.ports) { _, _ in push() }
        .onChange(of: stats.battery?.charging) { _, _ in push() }
        .onChange(of: stats.camerasInUse) { _, _ in push() }
        .onChange(of: stats.micInUse) { _, _ in push() }
    }

    private func push() { mac.update(MacHero.state(stats: stats, warning: nil)) }
}

// MARK: Performance

struct PerformancePage: View {
    @ObservedObject var stats: Stats
    let range: TimeRange
    @StateObject private var history = HistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                Metric(title: "CPU", value: "\(Int(stats.cpuPercent.rounded()))", unit: "%", detail: "\(stats.coreUsage.count) cores",
                       fraction: stats.cpuPercent / 100)
                Metric(title: "Temperature", value: stats.cpuTemp.map { "\(Int($0.rounded()))" } ?? "–", unit: "°C",
                       detail: Format.thermal(stats.thermal), fraction: (stats.cpuTemp ?? 0) / 100, tint: .orange)
                Metric(title: "GPU", value: "\(stats.gpuPercent ?? 0)", unit: "%", fraction: Double(stats.gpuPercent ?? 0) / 100, tint: .pink)
                Metric(title: "Fan", value: stats.fans.first.map { $0 == 0 ? "Off" : "\($0)" } ?? "–",
                       unit: (stats.fans.first ?? 0) > 0 ? "rpm" : "", detail: stats.bootTime.map { "Up \(Format.uptime(since: $0))" } ?? "")
            }
            if history.samples.count < 3 {
                GroupSection("CPU") { CollectingHistory() }
            } else {
                GroupSection("CPU", accessory: { Text(peakText(history.samples.map(\.cpu), unit: "%")) }) {
                    HistoryChart(samples: history.samples, value: { $0.cpu }, format: { "\(Int($0))%" }, yMax: 100, range: range,
                                 appsAt: { history.apps(at: $0, bucket: range.bucket) })
                }
                HStack(alignment: .top, spacing: 16) {
                    GroupSection("Temperature", accessory: { Text(peakText(history.samples.compactMap(\.temperature), unit: "°C")) }) {
                        HistoryChart(samples: history.samples, value: { $0.temperature }, format: { "\(Int($0))°" }, tint: .orange,
                                     yMax: 100, range: range, height: 130, compact: true)
                    }
                    GroupSection("GPU", accessory: { Text(peakText(history.samples.map(\.gpu), unit: "%")) }) {
                        HistoryChart(samples: history.samples, value: { $0.gpu }, format: { "\(Int($0))%" }, tint: .pink,
                                     yMax: 100, range: range, height: 130, compact: true)
                    }
                }
            }
            GroupSection("Busiest apps", accessory: { Text("CPU time, \(range.subtitle.lowercased())") }) {
                if history.apps.isEmpty {
                    Text("Nothing recorded yet.").foregroundStyle(.secondary)
                } else {
                    let top = history.apps.first?.cpuSeconds ?? 1
                    ForEach(history.apps) { app in
                        HStack(spacing: 12) {
                            Image(nsImage: AppIcons.icon(named: app.name)).resizable().frame(width: 20, height: 20)
                            Text(app.name).frame(width: 170, alignment: .leading).lineLimit(1)
                            UsageBar(fraction: app.cpuSeconds / max(top, 1), tint: .accentColor)
                            Text(Duration.text(app.cpuSeconds)).foregroundStyle(.secondary).monospacedDigit().frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .onAppear { history.load(range) }
        .onChange(of: range) { _, new in history.load(new) }
    }

    private func peakText(_ values: [Double], unit: String) -> String {
        guard !values.isEmpty else { return "" }
        let avg = values.reduce(0, +) / Double(values.count)
        return "average \(Int(avg.rounded()))\(unit) · peak \(Int((values.max() ?? 0).rounded()))\(unit)"
    }
}

// MARK: Memory

struct MemoryPage: View {
    @ObservedObject var stats: Stats
    let range: TimeRange
    @StateObject private var history = HistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let memory = stats.memory {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    Metric(title: "Used", value: Format.bytes(memory.used), detail: "of \(Format.bytes(memory.total))",
                           fraction: Double(memory.used) / Double(memory.total), tint: .purple)
                    Metric(title: "Pressure", value: memory.pressure.rawValue,
                           detail: memory.pressure == .normal ? "Plenty of room" : "macOS is compressing memory to make room")
                    Metric(title: "Compressed", value: Format.bytes(memory.compressed), detail: "Squeezed to make room")
                    Metric(title: "Cached files", value: Format.bytes(memory.cached), detail: "Freed whenever it's needed")
                }
                GroupSection("Breakdown") {
                    Chart {
                        ForEach([("Apps", Double(memory.app), Color.purple), ("Wired", Double(memory.wired), Color.pink),
                                 ("Compressed", Double(memory.compressed), Color.orange), ("Cached", Double(memory.cached), Color.gray)], id: \.0) { part in
                            BarMark(x: .value("Bytes", part.1), stacking: .standard)
                                .foregroundStyle(by: .value("Kind", part.0))
                        }
                    }
                    .chartForegroundStyleScale(["Apps": Color.purple, "Wired": .pink, "Compressed": .orange, "Cached": .gray])
                    .chartXScale(domain: 0...Double(memory.total))
                    .chartXAxis(.hidden)
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 56)
                }
            }
            GroupSection("What's using memory") {
                let users = mergedMemoryUsers
                let top = Double(users.first?.bytes ?? 1)
                ForEach(users) { user in
                    HStack(spacing: 12) {
                        Image(nsImage: user.app?.icon ?? AppIcons.icon(named: user.name)).resizable().frame(width: 20, height: 20)
                        Text(user.name).frame(width: 170, alignment: .leading).lineLimit(1)
                        UsageBar(fraction: Double(user.bytes) / top, tint: .purple)
                        Text(Format.bytes(user.bytes)).foregroundStyle(.secondary).monospacedDigit().frame(width: 80, alignment: .trailing)
                        if let app = user.app, app.processIdentifier != getpid() {
                            Button("Quit") { app.terminate() }.controlSize(.small)
                        } else {
                            Color.clear.frame(width: 44, height: 1)
                        }
                    }
                }
            }
            GroupSection("Memory used") {
                if history.samples.count < 3 {
                    CollectingHistory()
                } else {
                    HistoryChart(samples: history.samples, value: { $0.memoryUsed }, format: { "\(Int(($0 / 1_073_741_824).rounded())) GB" },
                                 tint: .purple, yMax: Double(stats.memory?.total ?? 0), range: range, yTicks: [0, 4 * 1_073_741_824])
                }
            }
        }
        .onAppear { history.load(range) }
        .onChange(of: range) { _, new in history.load(new) }
    }

    /// Processes with the same name (e.g. two Terminal sessions) shown as one row.
    private var mergedMemoryUsers: [TopAppTracker.MemoryUser] {
        var byName: [String: TopAppTracker.MemoryUser] = [:]
        for user in stats.memoryUsers {
            if var existing = byName[user.name.lowercased()] {
                existing.bytes += user.bytes
                if existing.app == nil { existing.app = user.app }
                byName[user.name.lowercased()] = existing
            } else {
                byName[user.name.lowercased()] = user
            }
        }
        return byName.values.sorted { $0.bytes > $1.bytes }
    }
}

// MARK: Storage

struct StoragePage: View {
    @ObservedObject var stats: Stats
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(stats.volumes) { volume in
                GroupSection(volume.name, accessory: {
                    if volume.ejectable && !volume.isInternal {
                        Button("Eject") { try? NSWorkspace.shared.unmountAndEjectDevice(at: volume.url) }.controlSize(.small)
                    }
                }) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Format.bytes(UInt64(volume.free))) free").font(.system(.title2, design: .rounded, weight: .semibold))
                        Text("of \(Format.bytes(UInt64(volume.total)))").foregroundStyle(.secondary)
                    }
                    Gauge(value: 1 - Double(volume.free) / Double(volume.total)) { EmptyView() }
                        .gaugeStyle(.linearCapacity)
                        .tint(volume.free < 10_000_000_000 ? .red : .teal)
                    if volume.purgeable > 1_000_000_000 {
                        Text("Includes \(Format.bytes(UInt64(volume.purgeable))) macOS can clear on its own, such as caches and iCloud copies.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([volume.url]) }
                        if volume.isInternal { Button("Clean Up Downloads…") { actions.cleanUpDownloads() } }
                    }
                    .controlSize(.small)
                }
            }
            GroupSection("Your home folder", accessory: {
                Button(stats.scanningFolders ? "Scanning…" : stats.folderSizes.isEmpty ? "Scan" : "Scan Again") {
                    Task { await stats.scanFolders() }
                }
                .controlSize(.small)
                .disabled(stats.scanningFolders)
            }) {
                if stats.folderSizes.isEmpty {
                    Text(stats.scanningFolders ? "Measuring your folders. This can take a minute." : "Find out which folders take the most space.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(stats.folderSizes.prefix(8), id: \.name) { folder in
                        BarMark(x: .value("Size", Double(folder.bytes)), y: .value("Folder", folder.name))
                            .foregroundStyle(.teal)
                            .annotation(position: .trailing) {
                                Text(Format.bytes(folder.bytes)).font(.caption).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(min(stats.folderSizes.count, 8)) * 30)
                }
            }
        }
        .onAppear { if stats.volumes.isEmpty { stats.volumes = Readers.volumes() } }
    }
}

// MARK: Battery

struct BatteryPage: View {
    @ObservedObject var stats: Stats
    let range: TimeRange
    @StateObject private var history = HistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                if let b = stats.battery {
                    Metric(title: "Charge", value: "\(b.percent)", unit: "%", detail: chargeLine(b), fraction: Double(b.percent) / 100,
                           tint: b.percent <= 20 && !b.onPower ? .red : .green)
                }
                Metric(title: "Health", value: stats.power?.health.map { "\($0)" } ?? "–", unit: "%",
                       detail: stats.power?.cycles.map { "\($0) charge cycles" } ?? "", fraction: Double(stats.power?.health ?? 0) / 100, tint: .green)
                Metric(title: "Power draw", value: stats.power?.systemWatts.map { String(format: "%.1f", $0) } ?? "–", unit: "W",
                       detail: stats.power?.chargerWatts.map { "\($0) W charger" + ($0 < 30 ? " · slow for this Mac" : "") } ?? "Not plugged in")
                Metric(title: "Temperature", value: stats.power?.batteryTemp.map { "\(Int($0.rounded()))" } ?? "–", unit: "°C")
            }
            GroupSection("Charge") {
                if history.samples.count < 3 {
                    CollectingHistory()
                } else {
                    HistoryChart(samples: history.samples, value: { $0.battery }, format: { "\(Int($0))%" }, tint: .green, yMax: 100, range: range)
                }
            }
            GroupSection("Power draw") {
                if history.samples.count < 3 {
                    CollectingHistory()
                } else {
                    HistoryChart(samples: history.samples, value: { $0.watts }, format: { String(format: "%.0f W", $0) }, tint: .yellow,
                                 range: range, appsAt: { history.apps(at: $0, bucket: range.bucket) }, height: 140)
                }
            }
            GroupSection("Using the most power", accessory: { Text("share of CPU work right now") }) {
                let top = stats.cpuUsers.first?.share ?? 1
                ForEach(stats.cpuUsers) { user in
                    HStack(spacing: 12) {
                        Image(nsImage: AppIcons.icon(named: user.name)).resizable().frame(width: 20, height: 20)
                        Text(user.name).frame(width: 170, alignment: .leading).lineLimit(1)
                        UsageBar(fraction: user.share / max(top, 0.01), tint: .green)
                        Text("\(Int((user.share * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
        .onAppear { history.load(range) }
        .onChange(of: range) { _, new in history.load(new) }
    }

    private func chargeLine(_ b: Stats.Battery) -> String {
        if let m = b.minutesLeft { return b.charging ? "Full in \(m / 60) h \(m % 60) min" : "\(m / 60) h \(m % 60) min left" }
        return b.charging ? "Charging" : b.onPower ? "Plugged in" : "On battery"
    }
}

// MARK: Displays

struct DisplaysPage: View {
    @ObservedObject var stats: Stats
    @ObservedObject var display: DisplayControl

    struct Info: Identifiable {
        var id: CGDirectDisplayID
        var name: String
        var builtIn: Bool
        var width: Int, height: Int, refresh: Double
        var nativeWidth: Int, nativeHeight: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(infos) { info in
                GroupSection(info.name, accessory: { Text(info.builtIn ? "Built-in" : connection) }) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(info.width) × \(info.height)").font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                        Text("at \(Int(info.refresh.rounded())) Hz").foregroundStyle(.secondary)
                    }
                    let (ok, message) = health(info)
                    Label(message, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                    if let screen = display.screens.first(where: { matches($0, info) }) {
                        HStack(spacing: 10) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { screen.brightness }, set: { display.setBrightness($0, for: screen.id) }), in: 0...1)
                            Image(systemName: "sun.max").foregroundStyle(.secondary)
                            Text(screen.known ? "\(Int((screen.brightness * 100).rounded()))%" : "–")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            if externalScreens().isEmpty {
                ContentUnavailableView("No external displays", systemImage: "display.2",
                                       description: Text("Connect your monitors and they'll appear here with their connection and health."))
            }
        }
        .onAppear { display.refresh() }
    }

    private var infos: [Info] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            // The panel's own resolution is the mode macOS flags as native (not the scaled HiDPI modes).
            let all = (CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode]) ?? []
            let native = all.first { $0.ioFlags & 0x0200_0000 != 0 }
                ?? all.filter { $0.width == $0.pixelWidth }.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            return Info(id: id, name: DisplayNames.friendly(screen.localizedName),
                        builtIn: CGDisplayIsBuiltin(id) != 0, width: mode.pixelWidth, height: mode.pixelHeight,
                        refresh: mode.refreshRate > 0 ? mode.refreshRate : 60,
                        nativeWidth: native?.pixelWidth ?? mode.pixelWidth, nativeHeight: native?.pixelHeight ?? mode.pixelHeight)
        }
    }

    /// Ports currently carrying video.
    private var connection: String {
        let video = stats.ports.filter { $0.connected && $0.detail != "Charger" && ($0.id.hasPrefix("Port-USB-C") || $0.id.hasPrefix("Port-HDMI")) }
        guard !video.isEmpty else { return "External" }
        // macOS doesn't say which display is on which port, so name the connection type once.
        let kinds = Array(Set(video.map { "\($0.name.replacingOccurrences(of: " 4", with: "")) · \($0.side.rawValue.lowercased()) side" })).sorted()
        return kinds.joined(separator: ", ")
    }

    private func health(_ info: Info) -> (Bool, String) {
        if !info.builtIn && info.refresh < 50 {
            return (false, "Only \(Int(info.refresh.rounded())) Hz. This cable or port may not support \(info.nativeWidth >= 3840 ? "4K" : "this resolution") at 60 Hz.")
        }
        if info.width < info.nativeWidth {
            return (false, "Running below its full resolution of \(info.nativeWidth) × \(info.nativeHeight).")
        }
        return (true, "Healthy")
    }

    private func matches(_ screen: DisplayControl.Screen, _ info: Info) -> Bool {
        if case .builtIn = screen.kind { return info.builtIn }
        return !info.builtIn && info.name == DisplayNames.friendly(screen.name)
    }
}

// MARK: Network

struct NetworkPage: View {
    @ObservedObject var stats: Stats
    @ObservedObject var speedTest: SpeedTest
    let range: TimeRange
    @StateObject private var history = HistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                Metric(title: "Download", value: Format.rate(stats.download), tint: .blue)
                Metric(title: "Upload", value: Format.rate(stats.upload), tint: .orange)
                Metric(title: "Latency", value: stats.pingMs.map { "\($0)" } ?? "–", unit: "ms", detail: "to 1.1.1.1")
                Metric(title: "Wi-Fi", value: stats.wifi.connected ? "\(stats.wifi.linkMbps)" : "Off", unit: stats.wifi.connected ? "Mbps link" : "",
                       detail: stats.wifi.connected ? "\(stats.wifi.name ?? "Name hidden") · \(stats.wifi.signal) dBm" : "")
            }
            if history.samples.count < 3 {
                GroupSection("Traffic") { CollectingHistory() }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    GroupSection("Download") {
                        HistoryChart(samples: history.samples, value: { $0.download }, format: Format.rate, tint: .blue, range: range, height: 140, compact: true)
                    }
                    GroupSection("Upload") {
                        HistoryChart(samples: history.samples, value: { $0.upload }, format: Format.rate, tint: .orange, range: range, height: 140, compact: true)
                    }
                }
            }
            GroupSection("Connection") {
                ValueRow(title: "Public IP address", value: stats.publicIP ?? "Checking…", symbol: "globe")
                Divider()
                ValueRow(title: "VPN", value: stats.vpn ? "Connected" : "Off", symbol: "lock.shield")
            }
            GroupSection("Speed test", accessory: {
                Button(speedTest.running ? "Testing…" : "Run Test") { Task { await speedTest.run(network: stats.wifi.name) } }
                    .controlSize(.small)
                    .disabled(speedTest.running)
            }) {
                if speedTest.results.isEmpty {
                    Text("Measures your real download and upload speed with Apple's servers. Takes about 15 seconds.")
                        .foregroundStyle(.secondary)
                } else {
                    Table(speedTest.results) {
                        TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                        TableColumn("Download") { Text("\(Int($0.downMbps.rounded())) Mbps").monospacedDigit() }
                        TableColumn("Upload") { Text("\(Int($0.upMbps.rounded())) Mbps").monospacedDigit() }
                        TableColumn("Latency") { Text("\(Int($0.pingMs.rounded())) ms").monospacedDigit() }
                        TableColumn("Network") { Text($0.network ?? "–") }
                    }
                    .frame(height: CGFloat(min(speedTest.results.count, 6)) * 26 + 30)
                }
            }
        }
        .onAppear { history.load(range) }
        .onChange(of: range) { _, new in history.load(new) }
    }
}

// MARK: Devices

struct DevicesPage: View {
    @ObservedObject var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupSection("Ports") {
                Table(stats.ports) {
                    TableColumn("Port") { port in
                        Label(port.name, systemImage: symbol(port)).foregroundStyle(port.connected ? .primary : .secondary)
                    }
                    TableColumn("Side") { Text($0.side.rawValue) }.width(70)
                    TableColumn("Status") { port in
                        HStack(spacing: 6) {
                            Circle().fill(port.connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            Text(port.detail)
                        }
                    }
                }
                .frame(height: CGFloat(stats.ports.count) * 24 + 28)
            }
            GroupSection("Bluetooth") {
                if stats.bluetooth.isEmpty {
                    Text("Nothing connected.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(stats.bluetooth.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider() }
                        ValueRow(title: device.name, value: device.battery ?? "Connected", symbol: device.name.contains("AirPods") ? "airpods.pro" : "dot.radiowaves.left.and.right")
                    }
                }
            }
            GroupSection("Camera and microphone") {
                ValueRow(title: "Camera", value: stats.camerasInUse.isEmpty ? "Not in use"
                         : stats.camerasInUse.map { $0.replacingOccurrences(of: "Continuity:", with: "") }.joined(separator: ", "),
                         symbol: "video", tint: stats.cameraInUse ? .green : .secondary)
                Divider()
                ValueRow(title: "Microphone", value: stats.micInUse ? "In use" : "Not in use", symbol: "mic", tint: stats.micInUse ? .orange : .secondary)
            }
        }
    }

    private func symbol(_ port: Ports.Port) -> String {
        if port.id.hasPrefix("Port-MagSafe") { return "bolt" }
        if port.id.hasPrefix("Port-HDMI") { return "tv" }
        if port.id.hasPrefix("Port-SD") { return "sdcard" }
        if port.id == "headphones" { return "headphones" }
        return "cable.connector"
    }
}

// MARK: Alerts

struct AlertsPage: View {
    @ObservedObject var alerts: SmartAlerts
    @State private var events: [HistoryStore.AlertEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupSection("Notify me when") {
                ForEach(Array(SmartAlerts.Kind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider() }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                            Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(kind.title, isOn: Binding(get: { alerts.isOn(kind) }, set: { alerts.set(kind, $0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
            GroupSection("Recent", accessory: { Text("Last 30 days") }) {
                if events.isEmpty {
                    ContentUnavailableView("No alerts", systemImage: "bell.slash", description: Text("When something needs your attention, it's listed here."))
                        .frame(height: 180)
                } else {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider() }
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).fontWeight(.medium)
                                Text(event.body).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(event.date.formatted(.relative(presentation: .named))).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear { events = HistoryStore.shared.alerts(since: Date().addingTimeInterval(-30 * 86_400)) }
    }
}

/// A segmented control drawn in SwiftUI. On macOS 26 the AppKit control behind
/// `.pickerStyle(.segmented)` leaks a little memory every time it's measured, and the live pages
/// re-measure it with every stats update (every 2 seconds), so after a few days the app slows down.
struct Segments<Value: Hashable, Content: View>: View {
    @Binding var selection: Value
    let options: [Value]
    @ViewBuilder let label: (Value) -> Content
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { selection = option } label: {
                    label(option)
                        .font(.callout.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.snappy(duration: 0.2), value: selection)
    }
}
