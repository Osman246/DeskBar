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
    /// `DESKBAR_DEMO_ALERT=1` as well: the same demo, with memory full (for the demo video's alert shots).
    static let alert = on && ProcessInfo.processInfo.environment["DESKBAR_DEMO_ALERT"] != nil
    /// `DESKBAR_DEMO_LOW=1` as well: disk and battery getting low (the amber "getting close" state).
    static let low = on && ProcessInfo.processInfo.environment["DESKBAR_DEMO_LOW"] != nil
    /// 9:41, as in Apple's product shots, so no real time or date appears.
    static let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 41))!
    static var now: Date { on ? date : Date() }
}

/// Owns the model and the menu bar item. Opening DeskBar again (Finder, Spotlight, Launchpad)
/// shows its window, as Mac apps do.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusPanel: StatusPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusPanel = StatusPanel(model: model)
    }

    /// DeskBar lives in the menu bar: closing its window must not quit it. (SwiftUI quits an app whose
    /// only scene is a single Window when that window closes; the menu bar item isn't a scene.)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusPanel?.openDashboard()
        return false
    }
}

struct DeskBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item and its panel are AppKit (StatusPanel); the window is SwiftUI.
        Window("DeskBar", id: "dashboard") {
            DashboardWindow(model: delegate.model)
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

/// What the menu bar item shows: a small MacBook when all's clear (a temperature isn't an answer),
/// and, only when something needs you, a warning symbol and what it is. Symbols are template
/// images, so the state reads by shape in any menu bar colour.
enum MenuBarLabel {
    @MainActor static func content(stats: Stats) -> (symbol: String, text: String, accessibility: String) {
        if let problem = stats.problems.first {
            return ("exclamationmark.triangle", problem.word, problem.word + ". " + problem.reason)
        }
        let detail = stats.cpuTemp.map { ", \(Int($0.rounded())) degrees" } ?? ", CPU \(Int(stats.cpuPercent.rounded())) percent"
        return ("macbook", "", "All good" + detail)
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
    /// How many parts of the panel are showing below the Mac (all of them unless the opening plays).
    @State private var shown = Panel.allParts
    static let allParts = 6
    /// The 3D Mac full size rather than a thumbnail, remembered between opens.
    @AppStorage("macExpanded") var macExpanded = false
    /// The second row of actions.
    @AppStorage("moreActions") var moreActions = false

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
        // One surface: groups are divided by hairlines, not boxed.
        VStack(alignment: .leading, spacing: 0) {
            Stage(model: model, stats: stats, mac: mac, open: $open, macExpanded: $macExpanded)
            // During the opening the panel is just the Mac; afterwards each part drops into place.
            VStack(alignment: .leading, spacing: 0) {
            if shown >= 1 {
                SectionRule()
                VitalsRow(stats: stats, open: $open).transition(.dropIn)
                tileDetail.padding(.horizontal, 10).padding(.bottom, 8)
            }
            if shown >= 2 {
                SectionRule()
                TodayLog(stats: stats).transition(.dropIn)
            }
            if shown >= 3 {
                SectionRule()
                Sections(model: model, open: $open).transition(.dropIn)
            }
            if shown >= 4 { actionRow.transition(.dropIn) }
            if shown >= 5 && open == "Settings" {
                SettingsModule(model: model, openAtLogin: $openAtLogin).padding(.horizontal, 10).padding(.bottom, 8).transition(.dropIn)
            }
            if shown >= 6 { footer.transition(.dropIn) }
            }
        }
        .frame(width: 340)
        .onChange(of: mac.revealed) { _, revealed in
            if revealed { dropIn() } else { shown = 0 }
        }
        .onChange(of: macExpanded) { _, expanded in mac.playsIntro = expanded }
        .onAppear {
            // The opening animation is for the full-size Mac; the thumbnail just appears.
            mac.playsIntro = macExpanded
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
        StatusPanel.shared?.openDashboard()   // opens the window and closes the panel
    }


    private func toggle(_ key: String) {
        withAnimation(.easeOut(duration: 0.2)) { open = open == key ? "" : key }
    }

    // MARK: Details

    @ViewBuilder private var tileDetail: some View {
        switch open {
        case "cpu": Module { CPUDetails(stats: stats) }
        case "memory": Module { MemoryDetails(stats: stats, actions: actions) }
        case "disk": Module { DiskDetails(stats: stats, actions: actions) }
        case "battery": Module { BatteryDetails(stats: stats) }
        default: EmptyView()
        }
    }

    // MARK: Actions and footer

    /// Four labelled actions (icons alone are ambiguous); the active one is tinted.
    private var actionRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                action("Focus", "moon", on: actions.focusOn) { Task { await actions.toggleFocus() } }
                action("Awake", "cup.and.saucer", on: actions.stayAwake) { actions.toggleStayAwake() }
                action("Mute", "mic.slash", on: actions.micMuted) { actions.toggleMic() }
                action("Lock", "lock") { actions.lockScreen() }
            }
            if moreActions {
                HStack(spacing: 6) {
                    action("Hide desk", "eye.slash", on: actions.desktopHidden) { Task { await actions.toggleDesktop() } }
                    action("Screen off", "display") { actions.sleepDisplays() }
                    action("Capture", "camera.viewfinder") { actions.screenshot() }
                    action("Clean up", "arrow.down.circle") { actions.cleanUpDownloads() }
                }
            }
            // What the last action did. It stays until the next one rather than vanishing on a timer.
            if !actions.message.isEmpty {
                Text(actions.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }

    private func action(_ title: String, _ icon: String, on: Bool = false, run: @escaping () -> Void) -> some View {
        PanelButton(title: title, icon: on ? icon + ".fill" : icon, prominent: on, fills: true, action: run)
            .accessibilityValue(on ? "On" : "Off")
    }

    /// One quiet line, like the bottom of a menu, with the standard Mac shortcuts.
    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("Open DeskBar", "⌘O") { openDashboard() }.keyboardShortcut("o", modifiers: .command)
            Spacer(minLength: 4)
            footerButton(moreActions ? "Fewer" : "More…", nil) {
                withAnimation(.easeOut(duration: 0.2)) { moreActions.toggle() }
            }
            Spacer(minLength: 4)
            footerButton("Settings", "⌘,") {
                withAnimation(.easeOut(duration: 0.2)) { open = open == "Settings" ? "" : "Settings" }
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer(minLength: 4)
            footerButton("Quit", "⌘Q") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 2)
    }

    private func footerButton(_ title: String, _ shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if let shortcut { Text(shortcut).foregroundStyle(Color.secondaryText) }
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The hairline between groups, inset to the 16-pt margins.
struct SectionRule: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, 16)
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
