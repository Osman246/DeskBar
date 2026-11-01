import AppKit
import SwiftUI

/// Something that needs you, with the reason and, where there is one, the fix.
struct Problem: Equatable {
    enum Fix: Equatable { case quit(pid_t), cleanDownloads, wifiSettings }

    /// The headline: "Memory is full".
    let title: String
    /// Two words for the menu bar and the 3D Mac's screen: "Memory full".
    let word: String
    let reason: String
    var fixLabel: String? = nil
    var fix: Fix? = nil
    /// The tile or section that explains it, and its button.
    var detail: String? = nil
    var detailLabel: String? = nil
}

extension Stats {
    /// Everything that needs you right now, most urgent first.
    var problems: [Problem] {
        var list: [Problem] = []
        if let temp = cpuTemp, temp >= 85 {
            list.append(cpuProblem(title: "Your Mac is running hot", word: "Running hot"))
        }
        if let b = battery, b.percent <= 20, !b.onPower {
            let reason = b.minutesLeft.map { "About \(Self.duration($0)) left. Plug in soon." } ?? "\(b.percent)% left. Plug in soon."
            list.append(Problem(title: "Battery is low", word: "Low battery", reason: reason,
                                detail: "battery", detailLabel: "Battery details"))
        }
        if memory?.pressure == .high {
            var problem = Problem(title: "Memory is full", word: "Memory full", reason: "Too many apps are open",
                                  detail: "memory", detailLabel: "See all apps")
            if let top = memoryUsers.first {
                problem = Problem(title: problem.title, word: problem.word,
                                  reason: "\(top.name) is using the most: \(Format.bytes(top.bytes))",
                                  fixLabel: Self.canQuit(top.app) ? "Quit \(top.name)" : nil,
                                  fix: Self.canQuit(top.app) ? .quit(top.pid) : nil,
                                  detail: "memory", detailLabel: "See all apps")
            }
            list.append(problem)
        }
        if let disk = storage, disk.free < 10_000_000_000 {
            list.append(Problem(title: "Disk is almost full", word: "Disk almost full",
                                reason: "\(Format.bytes(UInt64(max(0, disk.free)))) left",
                                fixLabel: "Clean up Downloads", fix: .cleanDownloads,
                                detail: "disk", detailLabel: "See disk"))
        }
        if thermal == .serious || thermal == .critical {
            list.append(cpuProblem(title: "Slowing down to cool off", word: "Throttling"))
        }
        if !wifi.connected {
            list.append(Problem(title: "You're offline", word: "Offline",
                                reason: wifi.on ? "Not connected to a network" : "Wi-Fi is off",
                                fixLabel: "Wi-Fi settings", fix: .wifiSettings))
        } else if pingMs == nil {
            list.append(Problem(title: "No internet", word: "No internet",
                                reason: "Connected to \(wifi.name ?? "Wi-Fi"), but nothing is getting through",
                                fixLabel: "Wi-Fi settings", fix: .wifiSettings))
        }
        return list
    }

    private func cpuProblem(title: String, word: String) -> Problem {
        guard let top = cpuUsers.first else {
            return Problem(title: title, word: word, reason: "Give it a moment, or close what you aren't using",
                           detail: "cpu", detailLabel: "See CPU")
        }
        return Problem(title: title, word: word, reason: "\(top.name) is working it the hardest",
                       fixLabel: Self.canQuit(top.app) ? "Quit \(top.name)" : nil,
                       fix: Self.canQuit(top.app) ? .quit(top.pid) : nil,
                       detail: "cpu", detailLabel: "See CPU")
    }

    /// Only ordinary apps get a Quit button (never Finder or a background process).
    /// Demo mode shows the button on its made-up apps.
    private static func canQuit(_ app: NSRunningApplication?) -> Bool {
        if Demo.on { return true }
        guard let app else { return false }
        return app.activationPolicy == .regular && app.bundleIdentifier != "com.apple.finder"
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) min"
    }
}

extension Problem.Fix {
    @MainActor func run(actions: Actions) {
        switch self {
        case .quit(let pid): NSRunningApplication(processIdentifier: pid)?.terminate()
        case .cleanDownloads: actions.cleanUpDownloads()
        case .wifiSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
        }
    }
}

/// The top card: the answer first, with the living 3D Mac beside it.
/// The Mac is small until you click it or open CPU or Battery, which need it full size.
struct VerdictCard: View {
    let model: AppModel
    @ObservedObject var stats: Stats
    @ObservedObject var mac: MacScene
    @Binding var open: String
    @Binding var macExpanded: Bool

    static let compactSize = CGSize(width: 96, height: 63)

    var body: some View {
        let problems = stats.problems
        let problem = problems.first
        let layout = expanded ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                              : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        VStack(alignment: .leading, spacing: 0) {
            layout {
                MacHero(mac: mac, stats: stats, status: problem?.word ?? "All good", warning: problem != nil,
                        open: open, compact: !expanded) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { macExpanded = true }
                } collapse: {
                    mac.resetView()
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                        macExpanded = false
                        if open == "cpu" || open == "battery" { open = "" }
                    }
                }
                headline(problem, more: problems.count - 1)
                    .padding(expanded ? 12 : 0)
                    .padding(.bottom, expanded && problem == nil ? 2 : 0)
            }
            .padding(expanded ? 0 : 10)
            if let problem, problem.fix != nil || problem.detail != nil {
                HStack(spacing: 6) {
                    if let label = problem.fixLabel, let fix = problem.fix {
                        PillButton(title: label, prominent: true) { fix.run(actions: model.actions) }
                    }
                    if let label = problem.detailLabel, let detail = problem.detail {
                        PillButton(title: label) {
                            withAnimation(.easeOut(duration: 0.2)) { open = open == detail ? "" : detail }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, expanded ? 12 : 10).padding(.bottom, 10)
                .padding(.top, expanded ? -2 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(problem == nil ? Color.primary.opacity(0.06) : Color.orange.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(problem == nil ? Color.clear : Color.orange.opacity(0.45), lineWidth: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: problem)
    }

    /// Full size while you've asked for it, or while it's showing heat, charging or a side's ports.
    private var expanded: Bool {
        macExpanded || open == "cpu" || open == "battery" || mac.mode.isPorts
    }

    private func headline(_ problem: Problem?, more: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(problem == nil ? Color.green : .orange).frame(width: 7, height: 7)
                Text(problem == nil ? "All good" : "Needs you")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(problem == nil ? Color.green : .orange)
                if more > 0 {
                    Text("· \(more) more").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(problem?.title ?? "Your Mac is fine")
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(problem?.reason ?? quietLine)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(Demo.on ? "MacBook Pro" : Host.current().localizedName ?? "This Mac") · \(MacInfo.subtitle)")
    }

    /// When nothing's wrong: what the 3D Mac would have said in its pills, or that all is quiet.
    private var quietLine: String {
        mac.pills.isEmpty ? "Nothing needs you right now" : mac.pills.map(\.text).joined(separator: " · ")
    }
}

/// A capsule button for the verdict card's fixes.
struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(prominent ? Color.white : .primary)
                .background(Capsule().fill(prominent ? Color.orange.opacity(hovering ? 0.85 : 1)
                                                     : Color.primary.opacity(hovering ? 0.16 : 0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// CPU, memory, disk and battery in one row, plus the last hour of CPU.
/// Bars stay grey while things are fine, so the one that's orange or red stands out.
struct VitalsCard: View {
    @ObservedObject var stats: Stats
    @Binding var open: String

    var body: some View {
        Module {
            HStack(alignment: .top, spacing: 4) {
                vital("cpu", "CPU", "\(Int(stats.cpuPercent.rounded()))%", cpuCaption,
                      fraction: stats.cpuPercent / 100, tint: (stats.cpuTemp ?? 0) >= 85 ? .red : nil)
                vital("memory", "Memory", stats.memory.map { Format.bytes($0.used) } ?? "–",
                      stats.memory.map { String(format: "of %.0f GB", Double($0.total) / 1_073_741_824) } ?? "",   // "of 16 GB", as Apple sells it
                      fraction: stats.memory.map { Double($0.used) / Double($0.total) } ?? 0, tint: memoryTint)
                vital("disk", "Disk", stats.storage.map { Format.bytes(UInt64(max(0, $0.free))) } ?? "–",
                      stats.storage.map { "free of " + Format.bytes(UInt64($0.total)) } ?? "",
                      fraction: stats.storage.map { 1 - Double($0.free) / Double($0.total) } ?? 0,
                      tint: (stats.storage?.free ?? .max) < 10_000_000_000 ? .red : nil)
                vital("battery", "Battery",   // "charging" goes in the caption; the title would truncate
                      stats.battery.map { "\($0.percent)%" } ?? "Mains", batteryCaption,
                      fraction: stats.battery.map { Double($0.percent) / 100 } ?? 1, tint: batteryTint)
            }
            .padding(.horizontal, -4)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(stats.cpuHistory.values.count >= History.capacity ? "CPU · last hour" : "CPU · since DeskBar opened")
                    Spacer()
                    Text("peak \(Int((stats.cpuHistory.values.max() ?? stats.cpuPercent).rounded()))%")
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                Sparkline(values: stats.cpuHistory.values, color: .secondary, ceiling: 50, fills: true)
                    .frame(height: 24)
            }
            .padding(.top, 10)
        }
    }

    private func vital(_ key: String, _ title: String, _ value: String, _ caption: String,
                       fraction: Double, tint: Color?) -> some View {
        let selected = open == key
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { open = selected ? "" : key }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                TileCaption(text: title, expanded: selected)
                Text(value)
                    .font(.system(size: 15.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.top, 1)
                Text(caption)
                    .font(.system(size: 10)).foregroundStyle(tint ?? Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Bar(fraction: fraction, tint: tint ?? Color.primary.opacity(0.4)).padding(.top, 5)
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cpuCaption: String {
        guard let temp = stats.cpuTemp else { return "\(stats.coreUsage.count) cores" }
        let feel = temp >= 85 ? "hot" : temp >= 65 ? "warm" : "cool"
        return "\(Int(temp.rounded()))°C · \(feel)"
    }

    private var memoryTint: Color? {
        switch stats.memory?.pressure {
        case .high: .red
        case .moderate: .orange
        default: nil
        }
    }

    private var batteryCaption: String {
        guard let b = stats.battery else { return "on power" }
        if b.charging { return "charging" }
        if b.onPower { return "on power" }
        return b.minutesLeft.map { Stats.duration($0) + " left" } ?? "on battery"
    }

    private var batteryTint: Color? {
        guard let b = stats.battery, !b.onPower else { return nil }
        return b.percent <= 20 ? .red : nil
    }
}

/// The menu bar's own dot: drawn as a coloured image, because the menu bar greys out SwiftUI colours.
enum MenuBarDot {
    static let warning: NSImage = {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}
