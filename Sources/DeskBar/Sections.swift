import ServiceManagement
import SwiftUI
import UserNotifications

/// The expandable rows: Wi-Fi (with the network and speed test), Sound, Display, and Devices
/// while something's connected or the camera or mic is on.
/// They share the panel's single `open` slot with the tiles, so only one thing is expanded.
struct Sections: View {
    let model: AppModel
    @ObservedObject var stats: Stats
    @ObservedObject var sound: SoundOutput
    @ObservedObject var display: DisplayControl
    @ObservedObject var speedTest: SpeedTest
    @ObservedObject var alerts: SmartAlerts
    @Binding var open: String

    init(model: AppModel, open: Binding<String>) {
        self.model = model
        stats = model.stats
        sound = model.sound
        display = model.display
        speedTest = model.speedTest
        alerts = model.alerts
        _open = open
    }

    var body: some View {
        Module(plain: true) {
            row("Wi-Fi", label: stats.wifi.connected ? stats.wifi.name ?? "Wi-Fi" : "Wi-Fi",
                icon: stats.wifi.connected ? "wifi" : "wifi.slash", summary: wifiSummary) {
                network
                Text("Speed test").font(.system(size: 10.5, weight: .semibold)).padding(.top, 6)
                speed
            }
            Divider()
            row("Sound", icon: "speaker.wave.2.fill", summary: sound.summary) { soundOutput }
            Divider()
            row("Display", icon: "sun.max.fill", summary: display.summary) { displays }
            if hasDevices {
                Divider()
                row("Devices", icon: "headphones", summary: deviceSummary) { devices }
            }
        }
        .font(.system(size: 12))
    }

    /// `title` is the row's key in the panel's one open slot; `label` is what it shows (the network name for Wi-Fi).
    private func row<Content: View>(_ title: String, label: String? = nil, icon: String, summary: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        let isOpen = open == title
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open = isOpen ? "" : title }
                if !isOpen && title == "Display" { display.refresh() }
                if !isOpen && title == "Sound" { sound.refresh() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 13)).frame(width: 18).foregroundStyle(Color.secondaryText)
                    Text(label ?? title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(summary).font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(1).truncationMode(.middle)
                    // Disclosure on the right, like the tiles' chevrons.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 4) { content() }
                    .padding(.leading, 26).padding(.bottom, 8)
            }
        }
    }

    // MARK: Network

    /// Ping, then the last speed test (or the link speed): what "is my internet OK?" needs.
    private var wifiSummary: String {
        if !stats.wifi.on { return "Off" }
        if !stats.wifi.connected { return "Not connected" }
        let ping = stats.pingMs.map { "\($0) ms" } ?? "no internet"
        let speed = speedTest.latest.map { "\(Int($0.downMbps.rounded())) Mbps" } ?? "\(stats.wifi.linkMbps) Mbps link"
        return ping + " · " + speed
    }

    @ViewBuilder private var network: some View {
        if stats.wifi.connected {
            HStack {
                InfoRow("Network", stats.wifi.name ?? "Hidden")
                if stats.wifi.name == nil {
                    Button("Show name") { model.stats.requestWiFiName() }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            InfoRow("Link", "\(stats.wifi.linkMbps) Mbps · " + (stats.pingMs.map { "\($0) ms ping" } ?? "no internet"))
        }
        Graph(series: [(stats.downHistory.values, .blue), (stats.upHistory.values, .orange)],
              caption: "Download and upload · last hour",
              peak: Format.rate((stats.downHistory.values + stats.upHistory.values).max() ?? 0))
        InfoRow("Download", Format.rate(stats.download), dot: .blue)
        InfoRow("Upload", Format.rate(stats.upload), dot: .orange)
        InfoRow("Public IP", stats.publicIP ?? "Checking…", selectable: true)
        InfoRow("VPN", stats.vpn ? "Connected" : "Off")
    }

    // MARK: Sound output

    @ViewBuilder private var soundOutput: some View {
        ForEach(sound.devices) { device in
            Button { sound.select(device.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: device.icon)
                        .font(.system(size: 11))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(device.id == sound.current ? Color.white : .primary)
                        .background(Circle().fill(device.id == sound.current ? Color.accentColor : Color.primary.opacity(0.1)))
                    Text(device.name).lineLimit(1)
                    Spacer()
                    if device.id == sound.current {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if sound.hasVolume {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { sound.volume }, set: { sound.setVolume($0) }), in: 0...1)
                    .controlSize(.small)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        Text("AirPlay speakers like Sonos appear here once picked in Control Center.")
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
            .fixedSize(horizontal: false, vertical: true)  // wrap instead of truncating in the menu bar window
    }

    // MARK: Display

    @ViewBuilder private var displays: some View {
        ForEach(display.screens) { screen in
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "sun.min").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { screen.brightness }, set: { display.setBrightness($0, for: screen.id) }), in: 0...1)
                        .controlSize(.small)
                    Image(systemName: "sun.max").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(screen.known ? "\(Int((screen.brightness * 100).rounded()))%" : "–")
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                }
            }
        }
        if display.screens.isEmpty {
            Text("No adjustable screens found").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if display.screens.contains(where: { !$0.known }) {
            Text("This monitor doesn't report its brightness. The slider still sets it.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)  // wrap instead of truncating in the menu bar window
        }
        HStack {
            Text("Night Shift")
            Spacer()
            Toggle("", isOn: Binding(get: { display.nightShift }, set: { display.setNightShift($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.top, 4)
    }

    // MARK: Speed test

    @ViewBuilder private var speed: some View {
        if let latest = speedTest.latest {
            HStack(spacing: 0) {
                SpeedFigure(label: "Download", value: "\(Int(latest.downMbps.rounded()))", unit: "Mbps", color: .blue)
                SpeedFigure(label: "Upload", value: "\(Int(latest.upMbps.rounded()))", unit: "Mbps", color: .orange)
                SpeedFigure(label: "Ping", value: "\(Int(latest.pingMs.rounded()))", unit: "ms", color: .secondary)
            }
            .opacity(speedTest.running ? 0.4 : 1)
        }
        HStack {
            Button {
                Task { await speedTest.run(network: stats.wifi.name) }
            } label: {
                HStack(spacing: 5) {
                    if speedTest.running { ProgressView().controlSize(.mini) }
                    Text(speedTest.running ? "Testing… about 15 s" : speedTest.latest == nil ? "Run speed test" : "Test again")
                }
            }
            .disabled(speedTest.running)
            Spacer()
        }
        .font(.system(size: 11))
        if let error = speedTest.error {
            Text(error).font(.system(size: 10.5)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)  // wrap instead of truncating in the menu bar window
        }
        if speedTest.results.count > 1 {
            Text("Earlier").font(.system(size: 10.5, weight: .semibold)).padding(.top, 4)
            ForEach(speedTest.results.dropFirst().prefix(4)) { result in
                InfoRow(result.date.formatted(date: .abbreviated, time: .shortened),
                        "↓ \(Int(result.downMbps.rounded()))  ↑ \(Int(result.upMbps.rounded())) Mbps")
            }
        }
        Text("Uses Apple's own test servers, the same as networkQuality in Terminal.")
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
            .fixedSize(horizontal: false, vertical: true)  // wrap instead of truncating in the menu bar window
    }

    // MARK: Devices

    private var hasDevices: Bool {
        !stats.bluetooth.isEmpty || stats.cameraInUse || stats.micInUse || open == "Devices"
    }

    private var deviceSummary: String {
        if stats.cameraInUse { return "Camera in use" }
        if stats.micInUse { return "Mic in use" }
        if let first = stats.bluetooth.first(where: { $0.battery != nil }) { return "\(first.name) \(first.battery!)" }
        return stats.bluetooth.isEmpty ? "None" : "\(stats.bluetooth.count) connected"
    }

    @ViewBuilder private var devices: some View {
        if stats.bluetooth.isEmpty { InfoRow("Bluetooth", "Nothing connected") }
        ForEach(stats.bluetooth) { device in InfoRow(device.name, device.battery ?? "Connected") }
        InfoRow("Camera", stats.cameraInUse ? "In use" : "Not in use", warn: stats.cameraInUse)
        InfoRow("Microphone", stats.micInUse ? "In use" : "Not in use", warn: stats.micInUse)
    }
}

struct SpeedFigure: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 18, weight: .semibold)).foregroundStyle(color == .secondary ? .primary : color)
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings, behind the gear: open at login and the smart alerts.
struct SettingsModule: View {
    let model: AppModel
    @ObservedObject var alerts: SmartAlerts
    @ObservedObject var actions: Actions
    @Binding var openAtLogin: Bool

    init(model: AppModel, openAtLogin: Binding<Bool>) {
        self.model = model
        alerts = model.alerts
        actions = model.actions
        _openAtLogin = openAtLogin
    }

    var body: some View {
        Module {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Open at login").font(.system(size: 11.5))
                    Spacer()
                    Toggle("", isOn: $openAtLogin)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .onChange(of: openAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                actions.message = "Couldn't change the login setting"
                                openAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                Divider()
                HStack {
                    Text("Smart alerts").font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text(alerts.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                alertSettings
            }
        }
    }

    @ViewBuilder private var alertSettings: some View {
        if alerts.permissionDenied {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Notifications are off for DeskBar.")
                Button("Turn on") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 11))
        }
        ForEach(SmartAlerts.Kind.allCases) { kind in
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title).font(.system(size: 11.5))
                    Text(kind.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { alerts.isOn(kind) }, set: { alerts.set(kind, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }
}
