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

/// Text that sits on glass: the system's secondary grey is 50%, which measured under 4.5:1
/// over a bright wallpaper; 65% passes in both appearances.
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
                        GlassButton(title: label, prominent: true) { fix.run(actions: model.actions) }
                    }
                    if let label = problem.detailLabel, let detail = problem.detail {
                        GlassButton(title: label) {
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

/// A Liquid Glass button on macOS 26 (accent-tinted when prominent), a bordered one before that.
struct GlassButton: View {
    let title: String
    var icon: String? = nil
    var prominent = false
    var fills = false
    let action: () -> Void

    var body: some View {
        let label = HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
            // Shrinks slightly rather than truncating when four share a row.
            Text(title).font(.system(size: 12, weight: prominent ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: fills ? .infinity : nil)
        if MacHero.stillImage != nil {
            // Snapshot renders can't capture Liquid Glass (the window server draws it live),
            // so tests get a drawn stand-in with the same size, tint and label colours.
            Button(action: action) {
                label.foregroundStyle(prominent ? Color.white : .primary)
                    .padding(.horizontal, fills ? 4 : 12).frame(height: 28)
                    .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.03)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
        } else if #available(macOS 26, *) {
            if prominent {
                Button(action: action) { label }.buttonStyle(.glassProminent).controlSize(fills ? .regular : .large)
            } else {
                Button(action: action) { label }.buttonStyle(.glass).controlSize(fills ? .regular : .large)
            }
        } else {
            if prominent {
                Button(action: action) { label }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button(action: action) { label }.buttonStyle(.bordered).controlSize(.large)
            }
        }
    }
}

/// CPU, memory, disk and battery as four bars. A tick marks where a bar becomes a problem,
/// only where that line is a real fraction (disk under 10 GB, battery at 20%).
/// Bars stay grey until something's wrong; then only that bar turns orange.
struct VitalsRow: View {
    @ObservedObject var stats: Stats
    @Binding var open: String

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            vital("cpu", "CPU", "\(Int(stats.cpuPercent.rounded()))", "%", cpuNote,
                  fraction: stats.cpuPercent / 100, warn: (stats.cpuTemp ?? 0) >= 85)
            vital("memory", "Memory", stats.memory.map { Self.number($0.used) } ?? "–", "GB",
                  stats.memory.map { String(format: "of %.0f GB", Double($0.total) / 1_073_741_824) } ?? "",
                  fraction: stats.memory.map { Double($0.used) / Double($0.total) } ?? 0,
                  warn: stats.memory?.pressure == .high)
            vital("disk", "Disk", stats.storage.map { Self.number(UInt64(max(0, $0.free))) } ?? "–", "GB", "free",
                  fraction: stats.storage.map { 1 - Double($0.free) / Double($0.total) } ?? 0,
                  threshold: stats.storage.map { 1 - 10_000_000_000 / Double($0.total) },
                  warn: (stats.storage?.free ?? .max) < 10_000_000_000)
            vital("battery", "Battery", stats.battery.map { "\($0.percent)" } ?? "–", stats.battery == nil ? "" : "%", batteryNote,
                  fraction: stats.battery.map { Double($0.percent) / 100 } ?? 1,
                  threshold: stats.battery == nil ? nil : 0.2,
                  warn: (stats.battery?.percent ?? 100) <= 20 && stats.battery?.onPower == false)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// "9.1", "199": the number alone; the unit is drawn lighter beside it.
    static func number(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 100 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }

    private func vital(_ key: String, _ title: String, _ value: String, _ unit: String, _ note: String,
                       fraction: Double, threshold: Double? = nil, warn: Bool) -> some View {
        let selected = open == key
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { open = selected ? "" : key }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())   // Title 3
                    Text(unit).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    if warn {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                ThresholdBar(fraction: fraction, threshold: threshold, warn: warn)
                Text(note).font(.system(size: 11)).foregroundStyle(Color.secondaryText).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(value) \(unit), \(note)\(warn ? ", needs attention" : "")")
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

/// A meter with an optional tick where it becomes a problem (a bullet-graph threshold).
struct ThresholdBar: View {
    let fraction: Double
    var threshold: Double? = nil
    var warn = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(warn ? Color.orange : Color.primary.opacity(0.55))
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
    @State private var events: [Event] = []

    struct Event: Identifiable, Equatable {
        let date: Date
        let text: String
        var id: Date { date }
    }

    var body: some View {
        // What's wrong now is already the headline; Today is only what happened earlier.
        VStack(alignment: .leading, spacing: 8) {
            Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondaryText)
            ForEach(events.prefix(2)) { event in
                row(time: event.date.formatted(date: .omitted, time: .shortened), text: event.text, warn: false)
            }
            if events.isEmpty {
                row(time: "", text: "Quiet so far", warn: false)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // Refresh every five minutes while the panel is open; the query is small and off the main thread.
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { Self.events() }.value
                if found != events { events = found }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func row(time: String, text: String, warn: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.secondaryText)
                .fixedSize().frame(minWidth: 50, alignment: .leading)
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "circle.fill")
                .font(.system(size: warn ? 10 : 5)).foregroundStyle(warn ? Color.orange : Color.secondaryText)
                .frame(width: 12)
            Text(text).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
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
        return found.sorted { $0.date > $1.date }
    }
}
