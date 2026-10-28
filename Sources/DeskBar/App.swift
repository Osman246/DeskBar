import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshot.run(to: CommandLine.arguments[i + 1]) }
        } else {
            DeskBarApp.main()
        }
    }
}

/// Everything the panel shows or controls.
@MainActor
final class AppModel: ObservableObject {
    let stats = Stats()
    let actions = Actions()
    let display = DisplayControl()
    let sound = SoundOutput()
    let speedTest = SpeedTest()
    let alerts = SmartAlerts()
    let mac = MacScene()
    let recorder = HistoryRecorder()

    init(askForNotifications: Bool = true) {
        stats.onRefresh = { [alerts, recorder] stats in
            alerts.check(stats)
            let externals = NSScreen.screens.filter {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false
            }.count
            recorder.add(stats, displays: externals)
        }
        if askForNotifications {
            DispatchQueue.main.async { self.alerts.requestPermission() }
            // Load the 3D Mac a moment after launch so the first open is instant.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.mac.loadIfNeeded() }
        }
    }
}

/// `DESKBAR_DEMO=1` for screenshots you can share: a stand-in public IP and a generic Mac name.
enum Demo {
    static let on = ProcessInfo.processInfo.environment["DESKBAR_DEMO"] != nil
    /// 9:41, as in Apple's product shots, so no real time or date appears.
    static let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 41))!
    static var now: Date { on ? date : Date() }
}

/// Opening DeskBar again (Finder, Spotlight, Launchpad) shows its window, as Mac apps do.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openWindow = Notification.Name("DeskBarOpenWindow")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: Self.openWindow, object: nil)
        return false
    }
}

struct DeskBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            MenuBarLabel(stats: model.stats)
        }
        .menuBarExtraStyle(.window)

        Window("DeskBar", id: "dashboard") {
            DashboardWindow(model: model)
                .onAppear {
                    // A menu bar app gets a Dock icon and Cmd-Tab entry only while its window is open.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 1180, height: 820)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// CPU temperature, or CPU load if the sensor can't be read.
struct MenuBarLabel: View {
    @ObservedObject var stats: Stats
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            // The label is always alive, so it listens for requests to open the window.
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openWindow)) { _ in
                openWindow(id: "dashboard")
                NSApp.activate()
            }
    }

    @ViewBuilder private var label: some View {
        if let temp = stats.cpuTemp {
            Image(systemName: temp >= 85 ? "thermometer.high" : "thermometer.medium")
            Text("\(Int(temp.rounded()))°")
        } else {
            Image(systemName: "cpu")
            Text("\(Int(stats.cpuPercent.rounded()))%")
        }
    }
}

struct Panel: View {
    let model: AppModel
    @ObservedObject var stats: Stats
    @ObservedObject var actions: Actions
    @ObservedObject var mac: MacScene
    /// The one tile or section that's expanded ("cpu", "memory", "Network", …), or "".
    @AppStorage("open") var open = ""
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @Environment(\.openWindow) private var openWindow
    /// How many parts of the panel are showing below the Mac (all of them unless the opening plays).
    @State private var shown = Panel.allParts
    static let allParts = 6

    init(model: AppModel) {
        self.model = model
        stats = model.stats
        actions = model.actions
        mac = model.mac
    }

    @State private var contentHeight: CGFloat = 700

    /// Scrolls when everything open wouldn't fit on screen; otherwise sizes to fit.
    var body: some View {
        if MacHero.stillImage != nil {
            content   // snapshot mode renders the whole panel
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                content.background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeight.self, value: geo.size.height)
                })
            }
            .frame(width: 340, height: min(contentHeight, maxHeight))
            .onPreferenceChange(ContentHeight.self) { height in
                // Grow and shrink with the same spring the parts use, so the panel unrolls smoothly.
                withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) { contentHeight = height }
            }
        }
    }

    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 24
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacHero(mac: model.mac, stats: stats, status: problems.first ?? "All good",
                    warning: !problems.isEmpty, open: open)
            // During the opening the panel is just the Mac; afterwards each part drops into place.
            if shown >= 1 {
                Button { toggle("cpu") } label: { CPUTile(stats: stats, selected: open == "cpu") }
                    .buttonStyle(.plain)
                    .transition(.dropIn)
            }
            if shown >= 2 {
                HStack(spacing: 8) {
                    Button { toggle("memory") } label: { memoryTile }.buttonStyle(.plain)
                    Button { toggle("disk") } label: { diskTile }.buttonStyle(.plain)
                    Button { toggle("battery") } label: { batteryTile }.buttonStyle(.plain)
                }
                .transition(.dropIn)
                tileDetail
            }
            if shown >= 3 { ConnectionsModule(stats: stats) { model.stats.requestWiFiName() }.transition(.dropIn) }
            if shown >= 4 { Sections(model: model, open: $open).transition(.dropIn) }
            if shown >= 5 { actionGrid.transition(.dropIn) }
            if shown >= 6 {
                OpenWindowRow { openDashboard() }.transition(.dropIn)
                footer.transition(.dropIn)
            }
        }
        .padding(10)
        .frame(width: 340)
        .onChange(of: mac.revealed) { _, revealed in
            if revealed { dropIn() } else { shown = 0 }
        }
        .onAppear {
            if !mac.revealed && MacHero.stillImage == nil { shown = 0 }
            actions.refresh()
            model.display.refresh()
            model.sound.refresh()
        }
    }

    /// Adds the panel's parts one at a time, each settling with a soft spring.
    private func dropIn() {
        guard shown < Self.allParts else { return }
        Task { @MainActor in
            for part in (shown + 1)...Self.allParts {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { shown = part }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate()
        // Close the menu bar panel once the window is up.
        NSApp.windows.filter { $0.isVisible && $0.className.contains("MenuBarExtra") }.forEach { $0.orderOut(nil) }
    }

    private func toggle(_ key: String) {
        withAnimation(.easeOut(duration: 0.2)) { open = open == key ? "" : key }
    }

    // MARK: Tiles

    private var memoryTile: some View {
        let memory = stats.memory
        let tint: Color = switch memory?.pressure {
        case .high: .red
        case .moderate: .orange
        default: .purple
        }
        return MiniTile(title: "Memory", value: memory.map { Format.bytes($0.used) } ?? "–",
                        fraction: memory.map { Double($0.used) / Double($0.total) } ?? 0, tint: tint,
                        selected: open == "memory")
    }

    private var diskTile: some View {
        let disk = stats.storage
        return MiniTile(title: "Disk", value: disk.map { Format.bytes(UInt64($0.free)) + " free" } ?? "–",
                        fraction: disk.map { 1 - Double($0.free) / Double($0.total) } ?? 0,
                        tint: (disk?.free ?? .max) < 10_000_000_000 ? .red : .teal, selected: open == "disk")
    }

    private var batteryTile: some View {
        let battery = stats.battery
        return MiniTile(title: battery?.charging == true ? "Charging" : "Battery",
                        value: battery.map { "\($0.percent)%" } ?? "Mains",
                        fraction: battery.map { Double($0.percent) / 100 } ?? 1,
                        tint: (battery?.percent ?? 100) <= 20 && battery?.onPower == false ? .red : .green,
                        selected: open == "battery")
    }

    @ViewBuilder private var tileDetail: some View {
        switch open {
        case "cpu": Module { CPUDetails(stats: stats) }
        case "memory": Module { MemoryDetails(stats: stats) }
        case "disk": Module { DiskDetails(stats: stats, actions: actions) }
        case "battery": Module { BatteryDetails(stats: stats) }
        default: EmptyView()
        }
    }

    // MARK: Actions and footer

    private var actionGrid: some View {
        Module {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 10) {
                RoundToggle("Focus", "moon.fill", on: actions.focusOn) { Task { await actions.toggleFocus() } }
                RoundToggle("Awake", "cup.and.saucer.fill", on: actions.stayAwake) { actions.toggleStayAwake() }
                RoundToggle("Hide desk", "eye.slash.fill", on: actions.desktopHidden) { Task { await actions.toggleDesktop() } }
                RoundToggle("Mute mic", "mic.slash.fill", on: actions.micMuted) { actions.toggleMic() }
                RoundToggle("Display off", "display") { actions.sleepDisplays() }
                RoundToggle("Capture", "camera.viewfinder") { actions.screenshot() }
                RoundToggle("Clean up", "arrow.down.circle") { actions.cleanUpDownloads() }
                RoundToggle("Lock", "lock.fill") { actions.lockScreen() }
            }
            Text(actions.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: $openAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: openAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        actions.message = "Couldn't change the login setting"
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Quit DeskBar") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var problems: [String] {
        var list: [String] = []
        if let temp = stats.cpuTemp, temp >= 85 { list.append("Running hot") }
        if let b = stats.battery, b.percent <= 20, !b.onPower { list.append("Low battery") }
        if stats.memory?.pressure == .high { list.append("Memory full") }
        if let disk = stats.storage, disk.free < 10_000_000_000 { list.append("Disk almost full") }
        if stats.thermal == .serious || stats.thermal == .critical { list.append("Throttling") }
        if !stats.wifi.connected { list.append("Offline") }
        else if stats.pingMs == nil { list.append("No internet") }
        return list
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension AnyTransition {
    /// Drops in from just above its place while fading in.
    static var dropIn: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -18)), removal: .identity)
    }
}

extension View {
    /// Part of the panel's opening cascade: hidden until `revealed`, then rises a few points into
    /// place, one step after the previous part.
    func cascade(_ step: Int, _ revealed: Bool) -> some View {
        opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 8)
            .animation(revealed ? .easeOut(duration: 0.32).delay(0.07 * Double(step)) : nil, value: revealed)
    }
}

/// "Open DeskBar" — a quiet, full-width row, like a menu item.
struct OpenWindowRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow").frame(width: 18)
                Text("Open DeskBar")
                Spacer()
                Text("⌘O").foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.1 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("o", modifiers: .command)
        .onHover { hovering = $0 }
    }
}
