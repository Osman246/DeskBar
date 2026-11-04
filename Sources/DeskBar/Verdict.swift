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
            let reason = b.minutesLeft.map { "About \(Self.duration($0)) left" } ?? "\(b.percent)% left"
            list.append(Problem(title: "Battery is low", word: "Low battery", reason: reason,
                                detail: "battery", detailLabel: "Battery details"))
        }
        if memory?.pressure == .high {
            var problem = Problem(title: "Memory is full", word: "Memory full", reason: "Too many apps open",
                                  detail: "memory", detailLabel: "See all apps")
            if let top = memoryUsers.first {
                problem = Problem(title: problem.title, word: problem.word,
                                  reason: "\(top.name) is using \(Format.bytes(top.bytes))",
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
                                reason: "Wi-Fi up, internet down",
                                fixLabel: "Wi-Fi settings", fix: .wifiSettings))
        }
        return list
    }

    private func cpuProblem(title: String, word: String) -> Problem {
        guard let top = cpuUsers.first else {
            return Problem(title: title, word: word, reason: "Close what you aren't using",
                           detail: "cpu", detailLabel: "See CPU")
        }
        return Problem(title: title, word: word, reason: "\(top.name) is working hardest",
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

/// Secondary text at 65% rather than the system's 50%, which measured under 4.5:1 contrast
/// over a bright wallpaper showing through the panel's material.
extension Color {
    static let secondaryText = Color.primary.opacity(0.65)
}

/// The top of the panel: the answer where eyes land first (top left), the living 3D Mac beside it.
/// Click the Mac, or open CPU or Battery, and it fills the panel's width for ports, heat and charging.
struct Stage: View {
    let model: AppModel
    @ObservedObject var stats: Stats
    @ObservedObject var mac: MacScene
    @Binding var open: String
    @Binding var macExpanded: Bool

    /// The Mac beside the verdict: the full scene's aspect ratio, scaled down.
    static let macSize = CGSize(width: 184, height: 121)

    var body: some View {
        let problems = stats.problems
        let problem = problems.first
        let layout = expanded ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                              : AnyLayout(HStackLayout(alignment: .top, spacing: 4))
        VStack(alignment: .leading, spacing: 12) {
            layout {
                if !expanded { headline(problem, more: problems.count - 1) }
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
                if expanded { headline(problem, more: problems.count - 1).padding(.horizontal, 6) }
            }
            if let problem, problem.fix != nil || problem.detail != nil {
                HStack(spacing: 8) {
                    if let label = problem.fixLabel, let fix = problem.fix {
                        PanelButton(title: label, prominent: true) { fix.run(actions: model.actions) }
                    }
                    if let label = problem.detailLabel, let detail = problem.detail {
                        PanelButton(title: label) {
                            withAnimation(.easeOut(duration: 0.2)) { open = open == detail ? "" : detail }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, expanded ? 6 : 0)
            }
        }
        .padding(.horizontal, expanded ? 10 : 16)
        .padding(.top, expanded ? 10 : 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: problem)
    }

    /// Full size while you've asked for it, or while it's showing heat, charging or a side's ports.
    private var expanded: Bool {
        macExpanded || open == "cpu" || open == "battery" || mac.mode.isPorts
    }

    private func headline(_ problem: Problem?, more: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 17)).foregroundStyle(problem == nil ? Color.green : .orange)
                if more > 0 {
                    Text("+\(more) more").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
            }
            .padding(.bottom, 2)
            Text(problem?.word ?? "All clear")
                .font(.system(size: 17, weight: .bold))            // Title 2, emphasized
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(problem?.reason ?? quietLine)
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)   // Callout
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !expanded && !mac.pills.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mac.pills) { pill in
                        Text(pill.text)
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(width: expanded ? nil : 120, alignment: .leading)
        .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        .help("\(Demo.on ? "MacBook Pro" : Host.current().localizedName ?? "This Mac") · \(MacInfo.subtitle)")
    }

    /// When nothing's wrong, three or four words on how it feels.
    private var quietLine: String {
        let warm = (stats.cpuTemp ?? 0) >= 65
        let busy = stats.cpuPercent >= 60
        switch (warm, busy) {
        case (true, true): return "Warm and working hard"
        case (true, false): return "A little warm"
        case (false, true): return "Busy, but cool"
        default: return stats.battery?.charging == true ? "Cool, quiet, charging" : "Cool and quiet"
        }
    }
}

/// A capsule button: grey, or accent-filled when it's the main action or a toggle that's on.
/// Drawn in SwiftUI, so it looks the same in the panel and in snapshot tests.
struct PanelButton: View {
    let title: String
    var icon: String? = nil
    var prominent = false
    var fills = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
                // Shrinks slightly rather than truncating when four share a row.
                Text(title).font(.system(size: 12, weight: prominent ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(prominent ? Color.white : .primary)
            .padding(.horizontal, fills ? 4 : 12).frame(height: 28)
            .frame(maxWidth: fills ? .infinity : nil)
            .background(Capsule().fill(prominent ? Color.accentColor.opacity(hovering ? 0.85 : 1)
                                                 : Color.primary.opacity(hovering ? 0.15 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// How a stat is doing. Colour always means this and nothing else.
enum VitalLevel {
    /// Soft green: calm, and it doesn't compete with the verdict's green tick.
    case fine
    /// Soft amber, only when it's getting close to something you can act on (never CPU just being busy).
    case close
    /// Orange, with ⚠︎ and a word, so it never relies on colour alone.
    case problem
}

/// CPU, memory, disk and battery as four bars. Each bar is coloured by how it's doing;
/// a tick marks where it becomes a problem, where that's a real fraction (disk under 10 GB, battery 20%).
struct VitalsRow: View {
    @ObservedObject var stats: Stats
    @Binding var open: String

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            vital("cpu", "CPU", "cpu", "\(Int(stats.cpuPercent.rounded()))", "%", cpuNote,
                  fraction: stats.cpuPercent / 100, level: (stats.cpuTemp ?? 0) >= 85 ? .problem : .fine)
            vital("memory", "Memory", "memorychip", stats.memory.map { Self.number($0.used) } ?? "–", "GB", memoryNote,
                  fraction: stats.memory.map { Double($0.used) / Double($0.total) } ?? 0, level: memoryLevel)
            vital("disk", "Disk", "internaldrive", stats.storage.map { Self.number(UInt64(max(0, $0.free))) } ?? "–", "GB",
                  diskLevel == .fine ? "free" : diskLevel == .close ? "free · low" : "almost full",
                  fraction: stats.storage.map { 1 - Double($0.free) / Double($0.total) } ?? 0,
                  threshold: stats.storage.map { 1 - 10_000_000_000 / Double($0.total) }, level: diskLevel)
            vital("battery", stats.battery == nil ? "Power" : "Battery", batteryIcon,
                  stats.battery.map { "\($0.percent)" } ?? "Mains", stats.battery == nil ? "" : "%", batteryNote,
                  fraction: stats.battery.map { Double($0.percent) / 100 } ?? 1,
                  threshold: stats.battery == nil ? nil : 0.2, level: batteryLevel)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// "9.1", "199": the number alone; the unit is drawn lighter beside it.
    static func number(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 100 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }

    private func vital(_ key: String, _ title: String, _ icon: String, _ value: String, _ unit: String, _ note: String,
                       fraction: Double, threshold: Double? = nil, level: VitalLevel) -> some View {
        let selected = open == key
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { open = selected ? "" : key }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                    Text(title).font(.system(size: 11))
                }
                .foregroundStyle(Color.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())   // Title 3
                    Text(unit).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    if level == .problem {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                ThresholdBar(fraction: fraction, threshold: threshold, level: level)
                Text(note)
                    .font(.system(size: 11, weight: level == .fine ? .regular : .medium))
                    .foregroundStyle(level == .problem ? Color.orange : level == .close ? Color.primary.opacity(0.85) : Color.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(value) \(unit), \(note)" + (level == .problem ? ", needs attention" : level == .close ? ", getting low" : ""))
    }

    private var memoryLevel: VitalLevel {
        switch stats.memory?.pressure {
        case .high: .problem
        case .moderate: .close
        default: .fine
        }
    }

    private var memoryNote: String {
        switch memoryLevel {
        case .problem: return "full"
        case .close: return "filling up"
        case .fine: return stats.memory.map { String(format: "of %.0f GB", Double($0.total) / 1_073_741_824) } ?? ""
        }
    }

    private var diskLevel: VitalLevel {
        guard let free = stats.storage?.free else { return .fine }
        return free < 10_000_000_000 ? .problem : free < 20_000_000_000 ? .close : .fine
    }

    private var batteryLevel: VitalLevel {
        guard let b = stats.battery, !b.onPower else { return .fine }
        return b.percent <= 20 ? .problem : b.percent < 30 ? .close : .fine
    }

    private var batteryIcon: String {
        guard let b = stats.battery else { return "powerplug" }
        if b.charging { return "battery.100percent.bolt" }
        switch b.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var cpuNote: String {
        guard let temp = stats.cpuTemp else { return "\(stats.coreUsage.count) cores" }
        let feel = temp >= 85 ? "hot" : temp >= 65 ? "warm" : "cool"
        return "\(Int(temp.rounded()))°C · \(feel)"
    }

    private var batteryNote: String {
        guard let b = stats.battery else { return "on power" }
        if b.charging { return "charging" }
        if b.onPower { return "on power" }
        // A clock time is easier to plan around than a duration.
        guard let minutes = b.minutesLeft else { return "on battery" }
        return "till " + Demo.now.addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened)
    }
}

/// A meter coloured by its level, with an optional tick where it becomes a problem (a bullet-graph threshold).
struct ThresholdBar: View {
    let fraction: Double
    var threshold: Double? = nil
    var level: VitalLevel = .fine
    @Environment(\.colorScheme) private var scheme

    private var fill: Color {
        switch level {
        case .fine: Color.green.opacity(scheme == .dark ? 0.55 : 0.6)
        case .close: Color(nsColor: .systemYellow).opacity(scheme == .dark ? 0.7 : 0.85)   // quieter than a problem
        case .problem: Color.orange
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(fill)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
                if let threshold {
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1, height: 8)
                        .offset(x: geo.size.width * min(1, max(0, threshold)) - 0.5)
                }
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// "Today": what happened earlier, in words, from the minute-by-minute history.
struct TodayLog: View {
    @ObservedObject var stats: Stats
    @State private var report = Report.empty

    struct Event: Identifiable, Equatable {
        let date: Date
        let text: String
        var id: Date { date }
    }

    /// Today in a few facts, all from the minute-by-minute history.
    struct Report: Equatable, Sendable {
        var minutesOn = 0
        var busiest: (name: String, minutes: Int)? = nil
        var hottest: (degrees: Int, at: Date)? = nil
        var downloaded: Double = 0
        /// How today compares with the same hours on the past week's days.
        var verdict: (symbol: String, text: String)? = nil
        var events: [Event] = []

        static let empty = Report()
        static func == (a: Report, b: Report) -> Bool {
            a.minutesOn == b.minutesOn && a.busiest?.name == b.busiest?.name && a.busiest?.minutes == b.busiest?.minutes
                && a.hottest?.degrees == b.hottest?.degrees && a.downloaded == b.downloaded
                && a.verdict?.text == b.verdict?.text && a.events == b.events
        }
    }

    var body: some View {
        // What's wrong now is already the headline; Today is what happened earlier.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondaryText)
                Spacer()
                if report.minutesOn > 0 {
                    Text("on for " + Self.duration(report.minutesOn)).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
            }
            if report.minutesOn < 15 {
                Text("Just getting started. Today's story builds up as you work.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    fact("Busiest", report.busiest?.name ?? "Nothing much",
                         report.busiest.map { Self.duration($0.minutes) + " of CPU" } ?? "")
                    fact("Hottest", report.hottest.map { "\($0.degrees)°C" } ?? "–",
                         report.hottest.map { "at " + $0.at.formatted(date: .omitted, time: .shortened) } ?? "")
                    fact("Downloaded", Format.bytes(UInt64(report.downloaded)), "since midnight")
                }
                if let verdict = report.verdict {
                    Label {
                        Text(verdict.text).font(.system(size: 12))
                    } icon: {
                        Image(systemName: verdict.symbol).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    }
                    .labelStyle(.titleAndIcon)
                }
                ForEach(report.events.prefix(2)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.secondaryText)
                            .fixedSize().frame(minWidth: 50, alignment: .leading)
                        Text(event.text).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // Refresh every five minutes while the panel is open; the queries are small and off the main thread.
            while !Task.isCancelled {
                let fresh = await Task.detached(priority: .utility) { Self.makeReport() }.value
                if fresh != report { report = fresh }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func fact(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(note).font(.system(size: 11)).foregroundStyle(Color.secondaryText).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    nonisolated static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) min"
    }

    nonisolated static func makeReport() -> Report {
        if Demo.on {
            let day = Calendar.current.startOfDay(for: Demo.date)
            return Report(minutesOn: 372, busiest: ("Final Cut Pro", 64), hottest: (78, day.addingTimeInterval(14 * 3600 + 9 * 60)),
                          downloaded: 3.4e9, verdict: ("leaf", "Quieter than your usual day"), events: events())
        }
        let store = HistoryStore.shared
        let calendar = Calendar.current
        let now = Date()
        let midnight = calendar.startOfDay(for: now)
        let today = store.samples(since: midnight)
        var report = Report(events: events())
        report.minutesOn = today.count
        report.downloaded = today.reduce(0) { $0 + $1.download * 60 }   // each sample is a minute's average rate
        if let top = store.busiestApps(from: midnight, limit: 1).first, top.cpuSeconds >= 60 {
            report.busiest = (top.name, Int(top.cpuSeconds / 60))
        }
        if let hot = today.filter({ $0.temperature != nil }).max(by: { $0.temperature! < $1.temperature! }) {
            report.hottest = (Int(hot.temperature!.rounded()), hot.date)
        }
        guard today.count >= 15 else { return report }
        // Without enough past days to compare, a fact about today alone, so the line is never empty.
        if let hot = report.hottest, hot.degrees < 60 {
            report.verdict = ("snowflake", "Cool all day: never above \(hot.degrees)°C")
        } else if let busy = report.busiest, busy.minutes >= 60 {
            report.verdict = ("bolt", "\(busy.name) kept it busy")
        } else {
            report.verdict = ("checkmark.seal", "A steady day so far")
        }
        // Compare with up to 14 past days over the same hours (midnight to now), so a half-day isn't
        // judged against whole days. Needs at least three of those days to have data.
        let todayCPU = today.map(\.cpu).reduce(0, +) / Double(today.count)
        let todayPeak = today.compactMap(\.temperature).max() ?? 0
        let past = store.samples(since: calendar.date(byAdding: .day, value: -14, to: midnight)!)
        let elapsed = now.timeIntervalSince(midnight)
        var pastCPU: [Double] = [], pastPeaks: [Double] = []
        for back in 1...14 {
            let dayStart = calendar.date(byAdding: .day, value: -back, to: midnight)!
            let sameHours = past.filter { $0.date >= dayStart && $0.date < dayStart.addingTimeInterval(elapsed) }
            guard sameHours.count >= 15 else { continue }
            pastCPU.append(sameHours.map(\.cpu).reduce(0, +) / Double(sameHours.count))
            pastPeaks.append(sameHours.compactMap(\.temperature).max() ?? 0)
        }
        guard pastCPU.count >= 3 else { return report }
        let usual = pastCPU.reduce(0, +) / Double(pastCPU.count)
        if todayPeak > (pastPeaks.max() ?? .infinity) + 2 {
            report.verdict = ("flame", "Hottest it's run in two weeks")
        } else if todayCPU > usual * 1.3 {
            report.verdict = ("bolt", "Busier than your usual day")
        } else if todayCPU < usual * 0.7 {
            report.verdict = ("leaf", "Quieter than your usual day")
        } else {
            report.verdict = ("equal.circle", "About as busy as usual")
        }
        return report
    }

    /// Notable stretches since midnight, newest first: warm or busy for 5+ minutes, memory full, charged, battery low.
    nonisolated static func events() -> [Event] {
        if Demo.on {
            let day = Calendar.current.startOfDay(for: Demo.date)
            return [Event(date: day.addingTimeInterval(14 * 3600 + 2 * 60), text: "Ran warm · Final Cut Pro"),
                    Event(date: day.addingTimeInterval(9 * 3600 + 12 * 60), text: "Charged to 100%")]
        }
        let store = HistoryStore.shared
        let samples = store.samples(since: Calendar.current.startOfDay(for: Date()))
        var found: [Event] = []
        /// Start and end of each run of at least `minutes` consecutive samples matching `test`.
        func runs(_ minutes: Int, _ test: (HistoryStore.Sample) -> Bool) -> [(Date, Date)] {
            var result: [(Date, Date)] = []
            var start: Int?
            for (i, sample) in samples.enumerated() {
                if test(sample) { start = start ?? i } else if let s = start {
                    if i - s >= minutes { result.append((samples[s].date, samples[i - 1].date)) }
                    start = nil
                }
            }
            if let s = start, samples.count - s >= minutes { result.append((samples[s].date, samples[samples.count - 1].date)) }
            return result
        }
        func busiest(_ run: (Date, Date)) -> String {
            store.busiestApps(from: run.0, to: run.1.addingTimeInterval(60), limit: 1).first.map { " · " + $0.name } ?? ""
        }
        let warm = runs(5) { ($0.temperature ?? 0) >= 80 }
        for run in warm { found.append(Event(date: run.0, text: "Ran warm" + busiest(run))) }
        for run in runs(5, { $0.cpu >= 70 }) where !warm.contains(where: { $0.0 <= run.1 && run.0 <= $0.1 }) {
            found.append(Event(date: run.0, text: "Busy" + busiest(run)))
        }
        for run in runs(1, { $0.pressure >= 2 }) { found.append(Event(date: run.0, text: "Memory filled up")) }
        for (previous, sample) in zip(samples, samples.dropFirst()) {
            if let b = sample.battery, b >= 99.5, (previous.battery ?? 100) < 99.5, sample.charging {
                found.append(Event(date: sample.date, text: "Charged to 100%"))
            }
            if let b = sample.battery, b <= 20, (previous.battery ?? 0) > 20, !sample.charging {
                found.append(Event(date: sample.date, text: "Battery dropped to 20%"))
            }
        }
        // The same thing twice reads as one line with a count, newest time first, so two lines show two things.
        var merged: [Event] = []
        var seen: Set<String> = []
        for event in found.sorted(by: { $0.date > $1.date }) where seen.insert(event.text).inserted {
            let count = found.filter { $0.text == event.text }.count
            merged.append(Event(date: event.date, text: count > 1 ? "\(event.text) · \(count) times" : event.text))
        }
        return merged
    }
}
