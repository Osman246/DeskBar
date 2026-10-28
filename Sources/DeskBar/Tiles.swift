import SwiftUI

/// A rounded Control Center-style group.
struct Module<Content: View>: View {
    var selected = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

/// Small caption above a tile's value.
struct TileCaption: View {
    let text: String
    var trailing: String? = nil
    var expanded: Bool? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Spacer(minLength: 4)
            if let trailing { Text(trailing) }
            if let expanded {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct CPUTile: View {
    @ObservedObject var stats: Stats
    let selected: Bool

    var body: some View {
        Module(selected: selected) {
            TileCaption(text: "CPU · \(stats.coreUsage.count) cores", trailing: subtitle, expanded: selected)
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(stats.cpuPercent.rounded()))").font(.system(size: 26, weight: .semibold))
                    Text("%").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .frame(minWidth: 58, alignment: .leading)
                Sparkline(values: stats.cpuHistory.values, color: .accentColor, ceiling: 100)
                    .frame(height: 30)
            }
            .padding(.top, 4)
            // One bar per core: efficiency cores in teal, performance cores in blue.
            HStack(spacing: 3) {
                ForEach(Array(stats.coreUsage.enumerated()), id: \.offset) { index, usage in
                    let color: Color = index < Readers.efficiencyCores ? .teal : .accentColor
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1.5).fill(color.opacity(0.18))
                            RoundedRectangle(cornerRadius: 1.5).fill(color)
                                .frame(height: max(1.5, geo.size.height * usage / 100))
                        }
                    }
                }
            }
            .frame(height: 12)
            .padding(.top, 8)
            .animation(.easeOut(duration: 0.4), value: stats.coreUsage)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let temp = stats.cpuTemp { parts.append("\(Int(temp.rounded()))°C") }
        if let fan = stats.fans.first { parts.append(fan == 0 ? "fan off" : "\(fan.formatted()) rpm") }
        return parts.joined(separator: " · ")
    }
}

struct MiniTile: View {
    let title: String
    let value: String
    let fraction: Double
    let tint: Color
    let selected: Bool

    var body: some View {
        Module(selected: selected) {
            TileCaption(text: title, expanded: selected)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 3)
            Bar(fraction: fraction, tint: tint).padding(.top, 6)
        }
    }
}

struct Bar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// A filled line chart of the last hour; empty space on the left until an hour has passed.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var ceiling: Double = 0

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(ceiling, values.max() ?? 0, 1)
            let slots = Double(History.capacity - 1)
            let start = size.width - size.width * Double(values.count - 1) / slots
            var line = Path()
            for (i, value) in values.enumerated() {
                let point = CGPoint(x: start + size.width * Double(i) / slots,
                                    y: size.height - size.height * min(value / top, 1))
                i == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: start, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.22)))
            context.stroke(line, with: .color(color), lineWidth: 1.4)
        }
    }
}

/// Round Control Center-style button; fills with the accent colour while on.
struct RoundToggle: View {
    let title: String
    let icon: String
    var on = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, _ icon: String, on: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(on ? Color.white : .primary)
                    .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(hovering ? 0.16 : 0.1)))
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Wi-Fi.
struct ConnectionsModule: View {
    @ObservedObject var stats: Stats
    let showWiFiName: () -> Void

    var body: some View {
        Module {
            HStack(spacing: 8) {
                Image(systemName: stats.wifi.connected ? "wifi" : "wifi.slash").frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(wifiTitle).lineLimit(1).truncationMode(.middle)
                        if stats.wifi.connected && stats.wifi.name == nil {
                            Button("Show name", action: showWiFiName).buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                    if stats.wifi.connected {
                        Text("\(stats.wifi.linkMbps) Mbps link · " + (stats.pingMs.map { "\($0) ms" } ?? "no internet"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .font(.system(size: 12))
    }

    private var wifiTitle: String {
        if !stats.wifi.on { return "Wi-Fi off" }
        if !stats.wifi.connected { return "Not connected" }
        return stats.wifi.name ?? "Wi-Fi"
    }
}
