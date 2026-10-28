import SwiftUI
import UserNotifications

/// The expandable rows: Network, Sound, Display, Speed test, Devices and Alerts.
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
        Module {
            row("Network", icon: "arrow.up.arrow.down", summary: "↓ \(Format.rate(stats.download))  ↑ \(Format.rate(stats.upload))") {
                network
            }
            Divider()
            row("Sound output", icon: "speaker.wave.2.fill", summary: sound.summary) { soundOutput }
            Divider()
            row("Display", icon: "sun.max.fill", summary: display.summary) { displays }
            Divider()
            row("Speed test", icon: "gauge.with.needle", summary: speedTest.summary) { speed }
            Divider()
            row("Devices", icon: "headphones", summary: deviceSummary) { devices }
            Divider()
            row("Smart alerts", icon: "bell.badge", summary: alerts.summary) { alertSettings }
        }
        .font(.system(size: 12))
    }

    private func row<Content: View>(_ title: String, icon: String, summary: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        let isOpen = open == title
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open = isOpen ? "" : title }
                if !isOpen && title == "Display" { display.refresh() }
                if !isOpen && title == "Sound output" { sound.refresh() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: icon).font(.system(size: 12)).frame(width: 18)
                    Text(title)
                    Spacer()
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 4) { content() }
                    .padding(.leading, 36).padding(.bottom, 8)
            }
        }
    }

    // MARK: Network

    @ViewBuilder private var network: some View {
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

    // MARK: Smart alerts

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
