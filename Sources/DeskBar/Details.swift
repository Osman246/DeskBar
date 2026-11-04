import SwiftUI

// The four detail views, opened from the stats row. Each answers first: what the number means
// and why, then the fix, the top three apps, and a few facts. History lives in the window.

/// The opening line of a detail view: a status symbol, what it means, and why.
struct DetailAnswer: View {
    let level: VitalLevel
    let title: String
    let reason: String
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol ?? defaultSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(reason).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)  // wrap instead of truncating in the panel
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var defaultSymbol: String {
        switch level {
        case .fine: "checkmark.circle.fill"
        case .close: "exclamationmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch level {
        case .fine: Color.green.opacity(0.7)
        case .close: Color(nsColor: .systemYellow)
        case .problem: .orange
        }
    }
}

/// An app with its icon, a value, a grey bar and, for ordinary apps, a Quit button.
struct AppUsageRow: View {
    let name: String
    let pid: pid_t
    let value: String
    let fraction: Double
    var quit: NSRunningApplication? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                } else {
                    Image(systemName: "app").font(.system(size: 11)).foregroundStyle(Color.secondaryText).frame(width: 14)
                }
                Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryText)
                if let quit, Stats.canQuit(quit), quit.processIdentifier != getpid() {
                    Button { quit.terminate() } label: {
                        Text("Quit").font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Bar(fraction: fraction, tint: Color.primary.opacity(0.45), height: 3).padding(.leading, 22)
        }
    }
}

/// A label on the left, a value on the right.
struct DetailFact: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Color.secondaryText)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

/// "CPU history in DeskBar ⌘O": the graphs and the longer story are in the window.
struct HistoryLink: View {
    let title: String

    var body: some View {
        Button { StatusPanel.shared?.openDashboard() } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                Spacer()
                Text("⌘O").foregroundStyle(Color.secondaryText)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: CPU

struct CPUDetails: View {
    @ObservedObject var stats: Stats

    var body: some View {
        let percent = Int(stats.cpuPercent.rounded())
        let cpuUsers = Self.merged(stats.cpuUsers)
        let top = cpuUsers.first
        VStack(alignment: .leading, spacing: 10) {
            if (stats.cpuTemp ?? 0) >= 85 || stats.thermal == .serious || stats.thermal == .critical {
                DetailAnswer(level: .problem, title: "Running hot · \(percent)%",
                             reason: (top.map { "\($0.name) is doing the most work. " } ?? "") + "Your Mac may slow down to cool off.")
            } else if stats.cpuPercent >= 70 {
                // Busy isn't a problem, so it isn't amber: it's what a Mac is for.
                DetailAnswer(level: .fine, title: "Working hard · \(percent)%",
                             reason: top.map { "\($0.name) is doing the most work." } ?? "Several apps are busy.", symbol: "bolt.circle.fill")
            } else {
                DetailAnswer(level: .fine, title: "Light load · \(percent)%",
                             reason: top.map { "\($0.name) is doing the most work." } ?? "Nothing's working it hard.", symbol: "leaf.circle.fill")
            }
            let users = Array(cpuUsers.prefix(3))
            let biggest = max(users.first?.percent ?? 1, 1)
            ForEach(users) { user in
                AppUsageRow(name: user.name, pid: user.pid, value: "\(Int(user.percent.rounded()))%",
                            fraction: min(1, user.percent / biggest), quit: user.app)
            }
            VStack(spacing: 4) {
                if let temp = stats.cpuTemp {
                    let peak = stats.tempHistory.values.max() ?? temp
                    DetailFact(label: "Temperature", value: "\(Int(temp.rounded()))°C · peak \(Int(peak.rounded()))°C this hour")
                }
                DetailFact(label: stats.fans.count > 1 ? "Fans" : "Fan",
                           value: stats.fans.isEmpty ? "None" : stats.fans.map { $0 == 0 ? "Off" : "\($0.formatted()) rpm" }.joined(separator: " · "))
                if let boot = stats.bootTime { DetailFact(label: "Up for", value: Format.uptime(since: boot)) }
            }
            HistoryLink(title: "CPU history in DeskBar")
        }
    }

    /// One line per app: helper processes that share an app's name ("Claude", "claude") are added together.
    static func merged(_ users: [TopAppTracker.CPUUser]) -> [TopAppTracker.CPUUser] {
        var byName: [String: TopAppTracker.CPUUser] = [:]
        var order: [String] = []
        for user in users {
            let key = user.name.lowercased()
            if var existing = byName[key] {
                existing.percent += user.percent
                existing.share += user.share
                if existing.app == nil { existing.app = user.app; existing.pid = user.pid; existing.name = user.name }
                byName[key] = existing
            } else {
                byName[key] = user
                order.append(key)
            }
        }
        return order.compactMap { byName[$0] }.sorted { $0.percent > $1.percent }
    }
}

// MARK: Memory

/// What's using memory, answer first, with each app on one line (helper processes merged).
struct MemoryDetails: View {
    @ObservedObject var stats: Stats
    let actions: Actions

    var body: some View {
        let users = Self.merged(stats.memoryUsers)
        let top = users.first
        VStack(alignment: .leading, spacing: 10) {
            if let memory = stats.memory {
                let used = String(format: "%.1f", Double(memory.used) / 1_073_741_824)
                let total = String(format: "%.0f", Double(memory.total) / 1_073_741_824)
                switch memory.pressure {
                case .high:
                    DetailAnswer(level: .problem, title: "Memory full · \(used) of \(total) GB",
                                 reason: "Apps need more than fits, so your Mac slows down." + (top.map { " \($0.name) uses the most." } ?? ""))
                case .moderate:
                    DetailAnswer(level: .close, title: "Filling up · \(used) of \(total) GB",
                                 reason: "macOS is compressing memory to fit." + (top.map { " \($0.name) uses the most." } ?? ""))
                default:
                    DetailAnswer(level: .fine, title: "Plenty free · \(used) of \(total) GB",
                                 reason: top.map { "\($0.name) uses the most." } ?? "Nothing is using much.")
                }
                if memory.pressure != .normal, let top, let app = top.app, Stats.canQuit(app), app.processIdentifier != getpid() {
                    HStack { PanelButton(title: "Quit \(top.name)", prominent: true) { app.terminate() }; Spacer() }
                }
            }
            let shown = Array(users.prefix(3))
            let biggest = Double(shown.first?.bytes ?? 1)
            ForEach(shown) { user in
                AppUsageRow(name: user.name, pid: user.pid, value: Format.bytes(user.bytes),
                            fraction: Double(user.bytes) / biggest, quit: user.app)
            }
            if users.isEmpty {
                Text("Checking…").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            if let memory = stats.memory {
                Text("Apps \(Format.bytes(memory.app)) · Compressed \(Format.bytes(memory.compressed)) · System \(Format.bytes(memory.wired)) · Cached \(Format.bytes(memory.cached)), freed when needed")
                    .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One line per app: helper processes that share an app's name ("Claude", "claude") are added together.
    static func merged(_ users: [TopAppTracker.MemoryUser]) -> [TopAppTracker.MemoryUser] {
        var byName: [String: TopAppTracker.MemoryUser] = [:]
        var order: [String] = []
        for user in users {
            let key = user.name.lowercased()
            if var existing = byName[key] {
                existing.bytes += user.bytes
                if existing.app == nil { existing.app = user.app; existing.pid = user.pid; existing.name = user.name }
                byName[key] = existing
            } else {
                byName[key] = user
                order.append(key)
            }
        }
        return order.compactMap { byName[$0] }.sorted { $0.bytes > $1.bytes }
    }
}

// MARK: Disk

struct DiskDetails: View {
    @ObservedObject var stats: Stats
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let disk = stats.storage {
                let free = Format.bytes(UInt64(max(0, disk.free)))
                let total = Format.bytes(UInt64(disk.total))
                let purgeable = stats.volumes.first { $0.isInternal }?.purgeable ?? 0
                let extra = purgeable > 1_000_000_000 ? " macOS can also clear \(Format.bytes(UInt64(purgeable))) of caches on its own when it needs room." : ""
                if disk.free < 10_000_000_000 {
                    DetailAnswer(level: .problem, title: "Almost full · \(free) free", reason: "Of \(total). Your Mac needs room to work." + extra)
                } else if disk.free < 20_000_000_000 {
                    DetailAnswer(level: .close, title: "Getting low · \(free) free", reason: "Of \(total)." + extra)
                } else {
                    DetailAnswer(level: .fine, title: "Plenty of space · \(free) free", reason: "Of \(total)." + extra)
                }
            }
            HStack(spacing: 8) {
                PanelButton(title: stats.scanningFolders ? "Looking…" : "What's using space?") { Task { await stats.scanFolders() } }
                PanelButton(title: "Clean up Downloads") { actions.cleanUpDownloads() }
                Spacer(minLength: 0)
            }
            if !stats.folderSizes.isEmpty {
                let biggest = Double(stats.folderSizes.first?.bytes ?? 1)
                ForEach(stats.folderSizes.prefix(4), id: \.name) { folder in
                    Button {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder.name))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Color.secondaryText).frame(width: 14)
                                Text(folder.name).font(.system(size: 12))
                                Spacer()
                                Text(Format.bytes(folder.bytes)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryText)
                            }
                            Bar(fraction: Double(folder.bytes) / biggest, tint: Color.primary.opacity(0.45), height: 3).padding(.leading, 22)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            // Other drives, with eject.
            ForEach(stats.volumes.filter { !$0.isInternal }) { volume in
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive").font(.system(size: 11)).foregroundStyle(Color.secondaryText).frame(width: 14)
                    Text(volume.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text("\(Format.bytes(UInt64(volume.free))) free").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    if volume.ejectable {
                        Button {
                            try? NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                            stats.volumes = Readers.volumes()
                        } label: { Image(systemName: "eject") }
                        .buttonStyle(.borderless)
                        .help("Eject")
                    }
                }
            }
            DetailFact(label: "Right now", value: "reading \(Format.rate(stats.diskRead)) · writing \(Format.rate(stats.diskWrite))")
        }
    }
}

// MARK: Battery

struct BatteryDetails: View {
    @ObservedObject var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            answer
            VStack(spacing: 4) {
                if let watts = stats.power?.systemWatts { DetailFact(label: "Using now", value: Format.watts(watts)) }
                let health = [stats.power?.health.map { "\($0)% of new" }, stats.power?.cycles.map { "\($0) cycles" }].compactMap { $0 }
                if !health.isEmpty { DetailFact(label: "Health", value: health.joined(separator: " · ")) }
                if let temp = stats.power?.batteryTemp { DetailFact(label: "Temperature", value: "\(Int(temp.rounded()))°C") }
            }
            let cpuUsers = CPUDetails.merged(stats.cpuUsers)
            if !cpuUsers.isEmpty {
                // macOS doesn't expose per-app watts, and the screen and other parts draw power too,
                // so this is each app's share of CPU work: a guide to what drains the battery fastest.
                Text("Most CPU work (a guide to battery use)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondaryText)
                let users = Array(cpuUsers.prefix(2))
                let biggest = max(users.first?.share ?? 1, 0.01)
                ForEach(users) { user in
                    AppUsageRow(name: user.name, pid: user.pid, value: "\(Int((user.share * 100).rounded()))%",
                                fraction: user.share / biggest)
                }
            }
        }
    }

    @ViewBuilder private var answer: some View {
        if let b = stats.battery {
            let using = stats.power?.systemWatts
            let charger = stats.power?.chargerWatts
            if b.charging, let using, let charger, using > Double(charger) - 2 {
                // A charger close to (or under) what the Mac is using can barely add charge.
                DetailAnswer(level: .close, title: "Charging slowly · \(b.percent)%",
                             reason: "Your Mac is using \(Format.watts(using)) and the charger gives \(charger) W, so it can barely gain. A higher-watt charger would fix it.")
            } else if b.charging {
                DetailAnswer(level: .fine, title: "Charging · \(b.percent)%",
                             reason: b.minutesLeft.map { "Full in about \(Stats.duration($0))." } ?? "Charging normally.", symbol: "bolt.circle.fill")
            } else if b.onPower {
                DetailAnswer(level: .fine, title: "Plugged in · \(b.percent)%",
                             reason: "Not charging right now. macOS sometimes holds the charge to protect the battery.", symbol: "powerplug.fill")
            } else {
                let level: VitalLevel = b.percent <= 20 ? .problem : b.percent < 30 ? .close : .fine
                let until = b.minutesLeft.map { Demo.now.addingTimeInterval(Double($0) * 60).formatted(date: .omitted, time: .shortened) }
                DetailAnswer(level: level, title: "On battery · \(b.percent)%",
                             reason: until.map { "Lasts until about \($0) at this rate." + (level == .fine ? "" : " Plug in soon.") }
                                 ?? (level == .fine ? "Working out how long it'll last." : "Plug in soon."))
            }
        } else {
            DetailAnswer(level: .fine, title: "On power", reason: "This Mac has no battery.", symbol: "powerplug.fill")
        }
    }
}
