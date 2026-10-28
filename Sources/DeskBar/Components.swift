import SwiftUI

struct InfoRow: View {
    let label: String
    let value: String
    var dot: Color? = nil
    var warn = false
    var selectable = false

    init(_ label: String, _ value: String, dot: Color? = nil, warn: Bool = false, selectable: Bool = false) {
        self.label = label
        self.value = value
        self.dot = dot
        self.warn = warn
        self.selectable = selectable
    }

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            if selectable {
                Text(value).textSelection(.enabled).lineLimit(1)
            } else {
                Text(value).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(warn ? Color.orange : .primary)
            }
        }
        .font(.system(size: 11.5))
    }
}

/// A small line graph of one or more series, scaled to the largest value
/// (or `floor`, so a quiet hour doesn't look like a busy one).
struct Graph: View {
    let series: [([Double], Color)]
    let caption: String
    let peak: String
    var floor: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(caption)
                Spacer()
                Text("peak \(peak)")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            Canvas { context, size in
                let top = max(floor, series.flatMap(\.0).max() ?? 0, 1)
                let slots = Double(History.capacity - 1)
                for (values, color) in series where values.count > 1 {
                    // Newest point on the right edge; an hour of space to the left.
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
                    context.fill(fill, with: .color(color.opacity(0.15)))
                    context.stroke(line, with: .color(color), lineWidth: 1.2)
                }
            }
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
            .overlay(alignment: .leading) {
                // The graph covers an hour, so it starts nearly empty after launch.
                if (series.first?.0.count ?? 0) < 30 {
                    Text("Building up…").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 8)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

enum Format {
    /// "12.8 GB", "134 GB", "1.2 TB": one decimal below 100, none above.
    static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1024) }
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", gb * 1024)
    }

    /// Network speed, never smaller than KB/s so the header doesn't jump around.
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1000
        if kb >= 1000 { return String(format: kb >= 10_000 ? "%.0f MB/s" : "%.1f MB/s", kb / 1000) }
        return String(format: kb >= 10 || kb == 0 ? "%.0f KB/s" : "%.1f KB/s", kb)
    }

    static func watts(_ value: Double) -> String {
        String(format: value < 10 ? "%.1f W" : "%.0f W", value)
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot · slowing down"
        case .critical: "Very hot · slowing down"
        @unknown default: "Unknown"
        }
    }

    static func uptime(since boot: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(boot) / 60)
        let days = minutes / 1440, hours = minutes % 1440 / 60
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s") \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
    }
}
