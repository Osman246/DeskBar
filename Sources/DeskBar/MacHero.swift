import SceneKit
import SwiftUI

/// The top card: the living 3D Mac with your Mac's name and status.
struct MacHero: View {
    @ObservedObject var mac: MacScene
    @ObservedObject var stats: Stats
    let status: String
    let warning: Bool
    let open: String
    /// Snapshot mode renders a still image instead of a live 3D view.
    static var stillImage: NSImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06))
            if let still = Self.stillImage {
                Image(nsImage: still).resizable()
            } else {
                // Always present: its window-visibility watcher is what loads and starts the scene.
                MacSceneView(mac: mac)
                if mac.modelMissing {
                    FlatMac(mac: mac).padding(.top, 34)
                } else if !mac.loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if case .ports(let side) = mac.mode {
                PortsOverlay(mac: mac, ports: stats.ports.filter { $0.side == side }, side: side)
            } else {
                titleBlock.opacity(mac.mode == .rest || mac.modelMissing ? 1 : 0)
            }
            if !mac.mode.isPorts && Self.stillImage == nil && !mac.modelMissing {
                // Desk button: between the MacBook and your whole desk.
                Button { mac.toggleDesk() } label: {
                    Image(systemName: mac.mode == .desk ? "laptopcomputer" : "display.2")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.ultraThinMaterial))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(mac.mode == .desk ? "Back to your MacBook" : "Show your desk")
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .cascade(1, mac.revealed)
            }
            if !mac.pills.isEmpty && !mac.mode.isPorts {
                // Detail the 3D screen leaves out: camera, microphone, charging, clamshell.
                HStack(spacing: 6) {
                    ForEach(mac.pills) { pill in
                        HStack(spacing: 5) {
                            Circle().fill(pill.color).frame(width: 6, height: 6)
                            Text(pill.text).font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .lineLimit(1)
                .padding(.leading, 10).padding(.bottom, 10)
                .padding(.trailing, 46)    // never reaches the desk button
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .animation(.easeOut(duration: 0.25), value: mac.pills)
                .cascade(1, mac.revealed)
            }
        }
        .frame(width: MacScene.panelSize.width, height: MacScene.panelSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.35), value: mac.mode)
        .onAppear { push() }   // rendering starts and stops with the panel's real visibility
        .onDisappear { mac.stop() }
        .onChange(of: open) { _, tile in mac.follow(tile: tile); push() }
        .onChange(of: stats.cpuTemp) { _, _ in push() }
        .onChange(of: stats.battery?.percent) { _, _ in push() }
        .onChange(of: mac.mode) { _, _ in push() }
        .onChange(of: status) { _, _ in push() }
        .onChange(of: stats.cameraInUse) { _, _ in push() }
        .onChange(of: stats.micInUse) { _, _ in push() }
        .onChange(of: stats.battery?.charging) { _, _ in push() }
        .onChange(of: stats.ports) { _, _ in push() }
        .onChange(of: stats.camerasInUse) { _, _ in push() }
        .onChange(of: stats.bluetooth.map(\.id)) { _, _ in push() }
    }

    private func push() { mac.update(Self.state(stats: stats, warning: warning ? status : nil)) }

    /// What the 3D Mac should reflect right now.
    static func state(stats: Stats, warning: String?) -> MacState {
        let builtIn = NSScreen.screens.contains {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        // Which side each external display is on, from macOS's arrangement (relative to the built-in screen).
        let screens = NSScreen.screens.compactMap { s -> (CGFloat, Bool)? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (s.frame.midX, CGDisplayIsBuiltin(id) != 0)
        }
        let centre = screens.first { $0.1 }?.0 ?? (screens.map(\.0).reduce(0, +) / CGFloat(max(1, screens.count)))
        let externals = screens.filter { !$0.1 }
        let left = externals.contains { $0.0 < centre } || (externals.count == 2)
        let right = externals.contains { $0.0 >= centre } || (externals.count == 2)
        return MacState(temperature: stats.cpuTemp, batteryPercent: stats.battery?.percent,
                        charging: stats.battery?.charging ?? false, onPower: stats.battery?.onPower ?? false,
                        magSafeConnected: stats.ports.first { $0.id.hasPrefix("Port-MagSafe") }?.connected ?? false,
                        cameraInUse: stats.cameraInUse, micInUse: stats.micInUse, warning: warning,
                        externalDisplays: NSScreen.screens.count - (builtIn ? 1 : 0),
                        ports: stats.ports,
                        airPods: stats.bluetooth.first { $0.name.localizedCaseInsensitiveContains("AirPods") }
                            .map { $0.battery ?? "Connected" },
                        continuityCamera: stats.camerasInUse.contains { $0.hasPrefix("Continuity:") },
                        leftMonitor: left, rightMonitor: right)
    }

    private var titleBlock: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Demo.on ? "MacBook Pro" : Host.current().localizedName ?? "This Mac").font(.system(size: 13, weight: .semibold))
                    .cascade(0, mac.revealed)
                Text(MacInfo.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .cascade(0, mac.revealed)
                    .animation(mac.revealed ? .easeOut(duration: 0.32).delay(0.05) : nil, value: mac.revealed)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(warning ? Color.orange : Color.green).frame(width: 6, height: 6)
                Text(status)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .cascade(1, mac.revealed)
        }
        .padding(12)
    }
}

/// Labels for the ports close-up: a hairline straight down from each port, staggered rows.
struct PortsOverlay: View {
    @ObservedObject var mac: MacScene
    let ports: [Ports.Port]
    let side: Ports.Side

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Calm surface for the labels.
            LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.85)],
                           startPoint: UnitPoint(x: 0.5, y: 0.42), endPoint: UnitPoint(x: 0.5, y: 0.6))
                .allowsHitTesting(false)
            let plan = layout()
            ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                if let anchor = mac.portAnchors[port.id] {
                    PortCallout(port: port, anchor: anchor, index: index,
                                row: plan.rows[port.id] ?? index % 2, labelX: plan.centres[port.id] ?? anchor.x)
                }
            }
            HStack {
                Text("\(side.rawValue) side").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .id(side).transition(.opacity)
                Spacer()
                SideSwitch(side: side) { mac.setMode(.ports($0)) }
            }
            .padding(10)
        }
        .animation(.easeOut(duration: 0.3), value: mac.portAnchors.isEmpty)
    }
}

/// One port: a ring on the port, a hairline that draws downward, then the label rising into place.
/// Callouts arrive one after another; rows alternate so neighbours never touch.
struct PortCallout: View {
    let port: Ports.Port
    let anchor: CGPoint
    let index: Int
    let row: Int
    let labelX: CGFloat
    @State private var shown = false

    /// Width of the label block, matching the fonts used below.
    static func labelWidth(_ port: Ports.Port) -> CGFloat {
        let name = (port.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        let detail = (port.detail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width + 9
        return ceil(max(name, detail))
    }

    private var top: CGFloat { row == 0 ? 98 : 152 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.primary.opacity(0.35))
                .frame(width: 1, height: max(0, top - 6 - (anchor.y + 6)))
                .scaleEffect(x: 1, y: shown ? 1 : 0, anchor: .top)
                .position(x: anchor.x, y: (anchor.y + 6 + top - 6) / 2)
            Circle().stroke(Color.primary.opacity(0.85), lineWidth: 1.2).frame(width: 7, height: 7)
                .scaleEffect(shown ? 1 : 0.4).opacity(shown ? 1 : 0)
                .position(anchor)
            VStack(spacing: 4) {
                Text(port.name).font(.system(size: 11, weight: .semibold))
                HStack(spacing: 4) {
                    Circle().fill(port.connected ? Color.green : Color.primary.opacity(0.25)).frame(width: 5, height: 5)
                    Text(port.detail).font(.system(size: 10)).foregroundStyle(port.connected ? .primary : .secondary)
                }
                .opacity(port.connected ? 0.85 : 1)
            }
            .fixedSize()
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .position(x: labelX, y: top + 16)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.08 + Double(index) * 0.07)) { shown = true }
        }
    }
}

extension PortsOverlay {
    struct Layout { var rows: [String: Int] = [:]; var centres: [String: CGFloat] = [:] }

    /// Chooses which labels go in the top and bottom rows, and nudges top-row labels sideways so
    /// they keep a clear gap from the lines that pass through the top row. Both row patterns are
    /// tried; the one with the least crowding wins.
    func layout() -> Layout {
        let gap: CGFloat = 10
        let width = MacScene.panelSize.width
        let placed = ports.compactMap { port in mac.portAnchors[port.id].map { (port, $0.x, PortCallout.labelWidth(port)) } }
        var best = Layout(), bestScore = CGFloat.infinity
        for pattern in 0..<2 {
            var result = Layout()
            for (i, item) in placed.enumerated() { result.rows[item.0.id] = (i + pattern) % 2 }
            for item in placed {
                let half = item.2 / 2
                var x = item.1
                if result.rows[item.0.id] == 0 {
                    // Lines of bottom-row ports cross the top row.
                    for other in placed where result.rows[other.0.id] == 1 && abs(other.1 - x) < half + gap {
                        x = other.1 > item.1 ? other.1 - gap - half : other.1 + gap + half
                    }
                }
                result.centres[item.0.id] = min(max(x, half + 8), width - half - 8)
            }
            // Score: how much labels still overlap lines or each other.
            var score: CGFloat = 0
            for a in placed {
                let ax = result.centres[a.0.id]!, ah = a.2 / 2, row = result.rows[a.0.id]!
                for b in placed where b.0.id != a.0.id {
                    if row == 0, result.rows[b.0.id] == 1 { score += max(0, ah + gap - abs(b.1 - ax)) }
                    if result.rows[b.0.id] == row {
                        score += max(0, ah + b.2 / 2 + gap - abs(result.centres[b.0.id]! - ax))
                    }
                }
                score += abs(ax - a.1) * 0.05   // prefer labels under their ports
            }
            if score < bestScore { bestScore = score; best = result }
        }
        return best
    }
}

struct SideSwitch: View {
    let side: Ports.Side
    let choose: (Ports.Side) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach([Ports.Side.left, .right], id: \.self) { option in
                Button { choose(option) } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10.5, weight: option == side ? .semibold : .regular))
                        .foregroundStyle(option == side ? Color(nsColor: .windowBackgroundColor) : .secondary)
                        .frame(width: 42, height: 20)
                        .background(Capsule().fill(option == side ? Color.primary : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
    }
}

/// The live SceneKit view, with drag to spin, click for ports, double-click to reset.
struct MacSceneView: NSViewRepresentable {
    let mac: MacScene

    func makeNSView(context: Context) -> InteractiveSCNView {
        let view = InteractiveSCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.scene = mac.scene
        view.pointOfView = mac.cameraNode
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.isPlaying = false
        view.preferredFramesPerSecond = 60
        view.onDrag = { mac.drag(by: $0) }
        view.onClick = { mac.click() }
        view.onDoubleClick = { mac.resetView() }
        view.onPointer = { mac.pointer($0) }
        view.onZoom = { mac.zoom(by: $0) }
        view.onScroll = { mac.scrollSwitch(by: $0, phase: $1, momentum: $2) }
        // Menu bar panels are hidden, not removed, so watch real visibility to pause rendering.
        view.onVisibilityChange = { visible in
            if visible { mac.start() } else { mac.stop() }
        }
        return view
    }

    func updateNSView(_ view: InteractiveSCNView, context: Context) {}
}

final class InteractiveSCNView: SCNView {
    var onDrag: ((Double) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    /// Pointer over the view, -1…1 each way (up is positive), or nil when it leaves.
    var onPointer: ((SIMD2<Double>?) -> Void)?
    /// Positive to zoom out (to the desk), negative to zoom back in.
    var onZoom: ((Double) -> Void)?

    var onScroll: ((Double, NSEvent.Phase, NSEvent.Phase) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.5 : 4), event.phase, event.momentumPhase)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(Double(-event.magnification) * 60)   // pinch in = zoom out to the desk
    }
    private var dragged = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        onPointer?(SIMD2(Double(p.x / bounds.width) * 2 - 1, Double(p.y / bounds.height) * 2 - 1))
    }

    override func mouseExited(with event: NSEvent) { onPointer?(nil) }
    private var wasVisible: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        visibilityChanged()
    }

    @objc private func visibilityChanged() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard visible != wasVisible else { return }
        wasVisible = visible
        isPlaying = visible
        // No continuous rendering: SceneKit redraws whenever the scene changes, and a still Mac
        // costs nothing.
        rendersContinuously = false
        onVisibilityChange?(visible)
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        onDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged && event.clickCount == 1 { onClick?() }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// "14-inch · M4 · Space Black" for this Mac.
enum MacInfo {
    static let subtitle: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        switch String(cString: buffer) {
        case "Mac16,1": return "14-inch · M4 · Space Black"   // model MW2U3, Space Black
        default: return "MacBook Pro"
        }
    }()
}

/// Stands in for the 3D Mac until Apple's model is on this Mac: a flat MacBook and a button that
/// fetches the model from apple.com (it's Apple's, so DeskBar can't ship it).
struct FlatMac: View {
    @ObservedObject var mac: MacScene

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macbook")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Button {
                mac.downloadModel()
            } label: {
                HStack(spacing: 6) {
                    if mac.downloadingModel { ProgressView().controlSize(.mini) } else { Image(systemName: "cube") }
                    Text(mac.downloadingModel ? "Downloading…" : "Show in 3D")
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .disabled(mac.downloadingModel)
            .help("Downloads Apple's 3D MacBook Pro (10 MB) from apple.com onto this Mac")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
