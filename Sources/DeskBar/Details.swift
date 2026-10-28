import SwiftUI

/// Heading inside a detail module.
struct DetailHeading: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(text).font(.system(size: 11, weight: .semibold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
        .padding(.bottom, 4)
    }
}

/// An app row with its icon, a value, a bar and an optional Quit button.
struct AppUsageRow: View {
    let name: String
    let pid: pid_t
    let value: String
    let fraction: Double
    let tint: Color
    var quit: NSRunningApplication? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary).monospacedDigit()
                if let quit, quit.processIdentifier != getpid() {
                    Button("Quit") { quit.terminate() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            Bar(fraction: fraction, tint: tint, height: 3)
        }
        .font(.system(size: 11.5))
    }
}

// MARK: CPU

struct CPUDetails: View {
    @ObservedObject var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailHeading(text: "Performance", trailing: Format.thermal(stats.thermal))
            if let top = stats.topApp {
                AppUsageRow(name: top.name, pid: top.app?.processIdentifier ?? 0,
                            value: "\(Int(top.percent.rounded()))% CPU",
                            fraction: min(1, top.percent / 100), tint: .accentColor, quit: top.app)
                    .padding(.bottom, 4)
            }
            InfoRow("Efficiency cores", coreAverage(efficiency: true), dot: .teal)
            InfoRow("Performance cores", coreAverage(efficiency: false), dot: .accentColor)
            InfoRow("GPU", stats.gpuPercent.map { "\($0)%" } ?? "–")
            InfoRow(stats.fans.count > 1 ? "Fans" : "Fan",
                    stats.fans.isEmpty ? "None" : stats.fans.map { $0 == 0 ? "Off" : "\($0.formatted()) rpm" }.joined(separator: " · "))
            InfoRow("Uptime", stats.bootTime.map { Format.uptime(since: $0) } ?? "–")
            Graph(series: [(stats.tempHistory.values, .orange)], caption: "Temperature · last hour",
                  peak: "\(Int((stats.tempHistory.values.max() ?? 0).rounded()))°C", floor: 100)
        }
    }

    private func coreAverage(efficiency: Bool) -> String {
        let split = Readers.efficiencyCores
        let cores = efficiency ? stats.coreUsage.prefix(split) : stats.coreUsage.dropFirst(split)
        guard !cores.isEmpty else { return "–" }
        return "\(Int((cores.reduce(0, +) / Double(cores.count)).rounded()))% · \(cores.count) cores"
    }
}

// MARK: Memory

/// What's using memory: the biggest apps, then where the rest of "used" goes.
struct MemoryDetails: View {
    @ObservedObject var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            DetailHeading(text: "Using memory", trailing: stats.memory.map { "pressure \($0.pressure.rawValue.lowercased())" })
            let users = stats.memoryUsers
            let biggest = Double(users.first?.bytes ?? 1)
            ForEach(users) { user in
                AppUsageRow(name: user.name, pid: user.pid, value: Format.bytes(user.bytes),
                            fraction: Double(user.bytes) / biggest, tint: .purple, quit: user.app)
            }
            if users.isEmpty {
                Text("Checking…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if let memory = stats.memory {
                SplitBar(parts: [(Double(memory.app), .purple), (Double(memory.wired), .pink),
                                 (Double(memory.compressed), .orange), (Double(memory.cached), .gray.opacity(0.6))],
                         total: Double(memory.total))
                    .padding(.top, 6)
                HStack(spacing: 10) {
                    Legend(color: .purple, text: "Apps \(Format.bytes(memory.app))")
                    Legend(color: .pink, text: "Wired \(Format.bytes(memory.wired))")
                    Legend(color: .orange, text: "Compressed \(Format.bytes(memory.compressed))")
                }
                Legend(color: .gray.opacity(0.6), text: "Cached files \(Format.bytes(memory.cached)), freed when needed")
            }
        }
    }
}

struct SplitBar: View {
    let parts: [(Double, Color)]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: max(0, geo.size.width * part.0 / max(total, 1) - 1))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.1))
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }
}

// MARK: Disk

struct DiskDetails: View {
    @ObservedObject var stats: Stats
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            DetailHeading(text: "Drives", trailing: "read \(Format.rate(stats.diskRead)) · write \(Format.rate(stats.diskWrite))")
            ForEach(stats.volumes) { volume in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive").frame(width: 14)
                        Text(volume.name).lineLimit(1)
                        Spacer()
                        Text("\(Format.bytes(UInt64(volume.free))) free of \(Format.bytes(UInt64(volume.total)))")
                            .foregroundStyle(.secondary)
                        if volume.ejectable && !volume.isInternal {
                            Button {
                                try? NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                                stats.volumes = Readers.volumes()
                            } label: { Image(systemName: "eject") }
                            .buttonStyle(.borderless)
                            .help("Eject")
                        }
                    }
                    Bar(fraction: 1 - Double(volume.free) / Double(volume.total),
                        tint: volume.free < 10_000_000_000 ? .red : .teal, height: 3)
                    if volume.purgeable > 1_000_000_000 {
                        Text("Includes \(Format.bytes(UInt64(volume.purgeable))) macOS can clear on its own (caches, iCloud copies)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)  // wrap instead of truncating in the menu bar window
                    }
                }
                .font(.system(size: 11.5))
            }

            Divider().padding(.vertical, 4)
            DetailHeading(text: "What's using space in your home folder")
            if stats.folderSizes.isEmpty {
                HStack {
                    Button(stats.scanningFolders ? "Scanning…" : "Find out") { Task { await stats.scanFolders() } }
                        .disabled(stats.scanningFolders)
                        .controlSize(.small)
                    Text("Takes up to a minute").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            } else {
                let biggest = Double(stats.folderSizes.first?.bytes ?? 1)
                ForEach(stats.folderSizes.prefix(6), id: \.name) { folder in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Button(folder.name) {
                                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder.name))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text(Format.bytes(folder.bytes)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Bar(fraction: Double(folder.bytes) / biggest, tint: .teal, height: 3)
                    }
                    .font(.system(size: 11.5))
                }
                HStack {
                    Button("Scan again") { Task { await stats.scanFolders() } }.disabled(stats.scanningFolders)
                    Button("Clean up Downloads") { actions.cleanUpDownloads() }
                }
                .font(.system(size: 11))
                .padding(.top, 2)
            }
        }
    }
}

// MARK: Battery

struct BatteryDetails: View {
    @ObservedObject var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailHeading(text: "Battery", trailing: chargeLine)
            Graph(series: [(stats.powerHistory.values, .green)], caption: "Power draw · last hour",
                  peak: Format.watts(stats.powerHistory.values.max() ?? 0))
            InfoRow("Using now", stats.power?.systemWatts.map(Format.watts) ?? "–")
            if let watts = stats.power?.chargerWatts {
                InfoRow("Charger", "\(watts) W" + (watts < 30 ? " · slow charger" : ""))
            } else {
                InfoRow("Charger", "Not plugged in")
            }
            InfoRow("Health", [stats.power?.health.map { "\($0)% of new" }, stats.power?.cycles.map { "\($0) cycles" }]
                .compactMap { $0 }.joined(separator: " · "))
            InfoRow("Temperature", stats.power?.batteryTemp.map { "\(Int($0.rounded()))°C" } ?? "–")

            if !stats.cpuUsers.isEmpty {
                Divider().padding(.vertical, 4)
                // macOS doesn't expose per-app watts, and the screen and other parts draw power
                // too, so show each app's share of CPU work, which is what drains the battery fastest.
                DetailHeading(text: "Using the most power", trailing: "share of CPU work")
                let biggest = stats.cpuUsers.first?.share ?? 1
                ForEach(stats.cpuUsers) { user in
                    AppUsageRow(name: user.name, pid: user.pid, value: "\(Int((user.share * 100).rounded()))%",
                                fraction: user.share / max(biggest, 0.01), tint: .green, quit: user.app)
                }
            }
        }
    }

    private var chargeLine: String {
        guard let b = stats.battery else { return "On mains power" }
        var text = "\(b.percent)%"
        if let minutes = b.minutesLeft {
            text += b.charging ? " · full in \(minutes / 60)h \(minutes % 60)m" : " · \(minutes / 60)h \(minutes % 60)m left"
        } else if b.charging {
            text += " · charging"
        } else if b.onPower {
            text += " · plugged in"
        }
        return text
    }
}
