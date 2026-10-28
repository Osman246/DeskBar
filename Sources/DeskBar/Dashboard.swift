import AppKit
import Charts
import SwiftUI

// MARK: Window

/// The DeskBar window: a sidebar of pages, each with live readings at the top and history below.
struct DashboardWindow: View {
    let model: AppModel
    @State private var page: Page
    @AppStorage("range") private var range: TimeRange = .day

    enum Page: String, CaseIterable, Identifiable {
        case overview = "Overview", performance = "Performance", memory = "Memory", storage = "Storage"
        case battery = "Battery", displays = "Displays", network = "Network", devices = "Devices", alerts = "Alerts"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: "macbook.and.iphone"
            case .performance: "gauge.with.dots.needle.67percent"
            case .memory: "memorychip"
            case .storage: "internaldrive"
            case .battery: "battery.75percent"
            case .displays: "display.2"
            case .network: "network"
            case .devices: "cable.connector"
            case .alerts: "bell.badge"
            }
        }

        /// Pages with history show the time-range control in the toolbar.
        var hasHistory: Bool { [.performance, .memory, .battery, .network].contains(self) }
    }

    init(model: AppModel, initialPage: Page? = nil) {
        self.model = model
        let saved = UserDefaults.standard.string(forKey: "dashboardPage").flatMap(Page.init(rawValue:))
        _page = State(initialValue: initialPage ?? saved ?? .overview)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { if let new = $0 { page = new } })) {
                Section {
                    row(.overview)
                }
                Section("Mac") {
                    ForEach([Page.performance, .memory, .storage, .battery]) { row($0) }
                }
                Section("Desk") {
                    ForEach([Page.displays, .network, .devices, .alerts]) { row($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ScrollView {
                content
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle(page.rawValue)
            .navigationSubtitle(subtitle)
            .toolbar {
                if page.hasHistory {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Range", selection: $range) {
                            ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .help("How far back to show")
                    }
                }
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .onChange(of: page) { _, new in UserDefaults.standard.set(new.rawValue, forKey: "dashboardPage") }
    }

    private func row(_ page: Page) -> some View {
        Label(page.rawValue, systemImage: page.symbol).tag(page)
    }

    private var subtitle: String {
        switch page {
        case .overview: Host.current().localizedName ?? "This Mac"
        case _ where page.hasHistory: range.subtitle
        default: ""
        }
    }

    @ViewBuilder private var content: some View { DashboardWindow.content(page, model: model, range: range) }

    @MainActor @ViewBuilder static func content(_ page: Page, model: AppModel, range: TimeRange) -> some View {
        switch page {
        case .overview: OverviewPage(model: model)
        case .performance: PerformancePage(stats: model.stats, range: range)
        case .memory: MemoryPage(stats: model.stats, range: range)
        case .storage: StoragePage(stats: model.stats, actions: model.actions)
        case .battery: BatteryPage(stats: model.stats, range: range)
        case .displays: DisplaysPage(stats: model.stats, display: model.display)
        case .network: NetworkPage(stats: model.stats, speedTest: model.speedTest, range: range)
        case .devices: DevicesPage(stats: model.stats)
        case .alerts: AlertsPage(alerts: model.alerts)
        }
    }
}

// MARK: Time range

enum TimeRange: String, CaseIterable, Identifiable {
    case hour, day, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: "Hour"
        case .day: "Today"
        case .week: "Week"
        case .month: "Month"
        }
    }

    var subtitle: String {
        switch self {
        case .hour: "Last hour"
        case .day: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }

    var start: Date {
        switch self {
        case .hour: Date().addingTimeInterval(-3600)
        case .day: Calendar.current.startOfDay(for: Date())
        case .week: Date().addingTimeInterval(-7 * 86_400)
        case .month: Date().addingTimeInterval(-30 * 86_400)
        }
    }

    /// Seconds per chart point, so long ranges stay light to draw.
    var bucket: Int {
        switch self {
        case .hour, .day: 60
        case .week: 900
        case .month: 3600
        }
    }

    var unit: Calendar.Component {
        switch self {
        case .hour, .day: .minute
        case .week: .hour
        case .month: .day
        }
    }
}

/// Loads history for a page and reloads it every minute while the page is open.
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var samples: [HistoryStore.Sample] = []
    @Published private(set) var apps: [HistoryStore.AppUsage] = []
    private var range: TimeRange?
    private var timer: Timer?

    func load(_ range: TimeRange) {
        self.range = range
        samples = HistoryStore.shared.samples(since: range.start, bucket: range.bucket)
        apps = HistoryStore.shared.busiestApps(from: range.start).filter { $0.cpuSeconds >= 60 }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if let range = self?.range { self?.load(range) } }
            }
        }
    }

    /// The busiest apps during one chart point.
    func apps(at date: Date, bucket: Int) -> [HistoryStore.AppUsage] {
        HistoryStore.shared.busiestApps(from: date, to: date.addingTimeInterval(TimeInterval(bucket)), limit: 3)
    }

    deinit { timer?.invalidate() }
}

// MARK: Building blocks

/// A titled group, matching the grouped sections in System Settings.
struct GroupSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                accessory.font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
    }
}

/// A single reading: label, large value with unit, an optional capacity gauge and a detail line.
struct Metric: View {
    let title: String
    let value: String
    var unit = ""
    var detail = ""
    var fraction: Double?
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // Every metric reserves the gauge row so cards in a row line up.
            Gauge(value: min(max(fraction ?? 0, 0), 1)) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(tint)
                .opacity(fraction == nil ? 0 : 1)
                .accessibilityHidden(fraction == nil)
            // Always present (even if empty) so cards in a row keep the same height.
            Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

/// A row in a list: leading icon, name, trailing value.
struct ValueRow: View {
    let title: String
    let value: String
    var symbol: String?
    var icon: NSImage?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else if let symbol {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
    }
}

/// Shown on history pages until there's enough data.
/// A horizontal bar for lists (apps, folders): same look as the gauges, in any colour.
struct UsageBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        Gauge(value: min(max(fraction, 0), 1)) { EmptyView() }
            .gaugeStyle(.linearCapacity)
            .tint(tint)
    }
}

struct CollectingHistory: View {
    var body: some View {
        ContentUnavailableView {
            Label("Collecting history", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("DeskBar saves a reading every minute. Charts appear here after a few minutes.")
        }
        .frame(height: 220)
    }
}

/// Icons for apps named in history (their names are all that's stored).
enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(named name: String) -> NSImage {
        if let cached = cache[name] { return cached }
        var url = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL
        if url == nil {
            for folder in ["/Applications", "/Applications/\(name)", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities"] {
                let candidate = URL(fileURLWithPath: "\(folder)/\(name).app")
                if FileManager.default.fileExists(atPath: candidate.path) { url = candidate; break }
            }
        }
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        cache[name] = image
        return image
    }
}

enum Duration {
    /// "2 h 05 min", "36 min", "45 s"
    static func text(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d h %02d min", s / 3600, s % 3600 / 60) }
        if s >= 60 { return "\(s / 60) min" }
        return "\(s) s"
    }
}

// MARK: Charts

/// A history chart with hover: a vertical rule follows the pointer, showing the value and, when
/// `appsAt` is given, the apps that were busiest at that moment.
struct HistoryChart: View {
    let samples: [HistoryStore.Sample]
    let value: (HistoryStore.Sample) -> Double?
    let format: (Double) -> String
    var tint: Color = .accentColor
    var yMax: Double?
    var range: TimeRange
    var appsAt: ((Date) -> [HistoryStore.AppUsage])?
    var height: CGFloat = 180
    var yTicks: [Double]?
    /// Half-width charts get fewer time labels.
    var compact = false

    @State private var selected: Date?

    var body: some View {
        let points = samples.compactMap { s in value(s).map { (s.date, $0) } }
        Chart {
            ForEach(points, id: \.0) { point in
                AreaMark(x: .value("Time", point.0), y: .value("Value", point.1))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.0), y: .value("Value", point.1))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let selected, let nearest = points.min(by: { abs($0.0.timeIntervalSince(selected)) < abs($1.0.timeIntervalSince(selected)) }) {
                RuleMark(x: .value("Selected", nearest.0))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        callout(date: nearest.0, value: nearest.1)
                    }
                PointMark(x: .value("Time", nearest.0), y: .value("Value", nearest.1))
                    .foregroundStyle(tint)
                    .symbolSize(30)
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...(yMax ?? max(points.map(\.1).max() ?? 1, 1) * 1.15))
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks.map { .stride(by: $0.count > 1 ? $0[1] - $0[0] : 1) } ?? .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.3))
                if let date = value.as(Date.self), date < labelCutoff {
                // Narrow charts use shorter labels ("6 pm" rather than "6:00 pm").
                AxisValueLabel(format: range == .month || range == .week ? .dateTime.weekday(.abbreviated).day()
                               : compact && range == .day ? .dateTime.hour() : .dateTime.hour().minute())
                }
            }
        }
        .frame(height: height)
    }

    /// From the start of the range to a little past now, so the last time label isn't clipped.
    private var xDomain: ClosedRange<Date> {
        let start = range.start, end = Date()
        return start...end.addingTimeInterval(end.timeIntervalSince(start) * 0.05)
    }

    /// Labels this close to the right edge would be clipped, so they're left out.
    private var labelCutoff: Date {
        let d = xDomain
        return d.upperBound.addingTimeInterval(-d.upperBound.timeIntervalSince(d.lowerBound) * (compact ? 0.1 : 0.06))
    }

    private var xTicks: AxisMarkValues {
        switch range {
        case .hour: .stride(by: .minute, count: compact ? 30 : 15)
        case .day: .stride(by: .hour, count: compact ? 6 : 3)
        case .week: .stride(by: .day, count: compact ? 2 : 1)
        case .month: .stride(by: .day, count: compact ? 10 : 5)
        }
    }

    private func callout(date: Date, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(date.formatted(range == .month || range == .week ? .dateTime.weekday().day().hour().minute() : .dateTime.hour().minute()))  ·  \(format(value))")
                .font(.caption.weight(.semibold)).monospacedDigit()
            if let appsAt {
                ForEach(appsAt(date)) { app in
                    HStack(spacing: 5) {
                        Image(nsImage: AppIcons.icon(named: app.name)).resizable().frame(width: 12, height: 12)
                        Text(app.name).font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
