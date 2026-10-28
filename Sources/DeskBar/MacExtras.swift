import AppKit
import IOKit
import IOKit.hid
import SceneKit
import SwiftUI

/// Everything the living Mac reflects about the real one, gathered by the panel.
struct MacState: Equatable {
    var temperature: Double?
    var batteryPercent: Int?
    var charging = false
    var onPower = false
    var magSafeConnected = false
    var cameraInUse = false
    var micInUse = false
    var warning: String?          // e.g. "Memory full"; nil when all is well
    var externalDisplays = 0
    var ports: [Ports.Port] = []
    var airPods: String?          // battery text when AirPods are connected, e.g. "L 80% · R 75%"
    var continuityCamera = false  // iPhone in use as the webcam
    var leftMonitor = false       // from macOS's display arrangement
    var rightMonitor = false
}

/// A small label on the hero card ("Camera in use", "Clamshell · 2 displays").
struct HeroPill: Identifiable, Equatable {
    var text: String
    var color: Color
    var id: String { text }
}

// MARK: Lid angle

/// The MacBook's hinge sensor (HID sensor page 0x20, usage 0x8A "hinge angle").
/// Not an official API: if it can't be read, `angle()` returns nil and the 3D lid stays open.
final class LidSensor {
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?

    init() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let first = devices.first,
              IOHIDDeviceOpen(first, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        self.manager = manager
        device = first
    }

    /// Degrees the lid is open (0 = closed), or nil if unavailable.
    func angle() -> Double? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        report[0] = 1
        var length = CFIndex(report.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess, length >= 3 else { return nil }
        let value = Double(Int(report[1]) | Int(report[2]) << 8)
        return (0...180).contains(value) ? value : nil
    }

    /// True when the lid is shut (clamshell mode with external displays).
    static func clamshellClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }
}

// MARK: Shared drawing helpers

enum SceneArt {
    static func glow(_ color: NSColor, inner: CGFloat = 0.8, outer: CGFloat = 0.2) -> NSImage {
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.lockFocus()
        let c = NSPoint(x: 64, y: 64)
        NSGradient(colors: [color.withAlphaComponent(inner), color.withAlphaComponent(outer), color.withAlphaComponent(0)])!
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: 63, options: [])
        image.unlockFocus()
        return image
    }

    static func constant(_ contents: Any, additive: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = contents
        if additive {
            m.blendMode = .add
            m.writesToDepthBuffer = false
        }
        return m
    }

    /// A small light with a billboard halo, e.g. the camera light or the MagSafe light.
    static func indicator(radius: CGFloat, halo: CGFloat) -> (node: SCNNode, dot: SCNMaterial, halo: SCNMaterial) {
        let dotMaterial = constant(NSColor.white)
        let node = SCNNode(geometry: SCNSphere(radius: radius))
        node.geometry!.materials = [dotMaterial]
        let haloMaterial = constant(NSColor.clear, additive: true)
        let haloNode = SCNNode(geometry: SCNPlane(width: halo, height: halo))
        haloNode.geometry!.materials = [haloMaterial]
        haloNode.constraints = [SCNBillboardConstraint()]
        node.addChildNode(haloNode)
        return (node, dotMaterial, haloMaterial)
    }

    static func setIndicator(_ dot: SCNMaterial, _ halo: SCNMaterial, color: NSColor) {
        dot.diffuse.contents = color
        halo.diffuse.contents = glow(color)
    }
}

// MARK: MagSafe 3 cable

/// Space Black braided MagSafe 3 cable in the left-rear port. Slides in and snaps the last
/// few millimetres when plugged in; pops away when unplugged. Light: amber charging, green full.
final class MagSafeCable {
    let node = SCNNode()
    private let indicator = SceneArt.indicator(radius: 0.075, halo: 0.7)
    private var plugged = 0.0          // 0 = out, 1 = seated
    private var target = 0.0
    private var lightLevel = 0.0
    private var charging = true
    private var shownCharging: Bool?

    init() {
        let black = SCNMaterial()
        black.lightingModel = .physicallyBased
        black.diffuse.contents = NSColor(white: 0.07, alpha: 1)
        black.metalness.contents = 0.55
        black.roughness.contents = 0.32
        let braid = SCNMaterial()
        braid.lightingModel = .physicallyBased
        braid.diffuse.contents = NSColor(white: 0.06, alpha: 1)    // Space Black, not grey
        braid.metalness.contents = 0.15
        braid.roughness.contents = 0.6

        let connector = SCNNode(geometry: SCNBox(width: 1.25, height: 0.46, length: 1.7, chamferRadius: 0.22))
        connector.geometry!.materials = [black]
        connector.position = SCNVector3(-16.18, -0.33, -8.2)
        node.addChildNode(connector)
        indicator.node.position = SCNVector3(-16.45, -0.09, -8.2)
        node.addChildNode(indicator.node)
        node.addChildNode(Self.tube([-16.82, -0.33, -8.2], [-17.7, -0.33, -8.2], radius: 0.28, material: black))

        // One smooth braid: many short segments with rounded joints.
        // Like the other left-side cables it runs back towards the wall; as the rearmost port it
        // turns soonest, so the cables fan out without crossing.
        let p0 = SIMD3<Float>(-17.7, -0.33, -8.2), p1 = SIMD3<Float>(-19.5, -0.33, -8.2)
        let p2 = SIMD3<Float>(-20.5, -0.7, -12), p3 = SIMD3<Float>(-21, -0.7, -20)
        func bezier(_ t: Float) -> SIMD3<Float> {
            let u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        }
        let steps = 90
        for i in 0..<steps {
            let a = bezier(Float(i) / Float(steps)), b = bezier(Float(i + 1) / Float(steps))
            node.addChildNode(Self.tube(a, b, radius: 0.23, material: braid))
            let joint = SCNSphere(radius: 0.23)
            joint.segmentCount = 20
            joint.materials = [braid]
            let jointNode = SCNNode(geometry: joint)
            jointNode.simdPosition = b
            node.addChildNode(jointNode)
        }

        // A thin bright edge on the braid from a low light behind it, so it reads on the desk.
        let rim = SCNLight()
        rim.type = .spot
        rim.intensity = 900
        rim.spotInnerAngle = 20
        rim.spotOuterAngle = 55
        rim.categoryBitMask = 2          // only the cable picks up this light, not the Mac or the desk
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(-30, 3, -18)
        rimNode.look(at: SCNVector3(-21, -0.5, -2))
        node.addChildNode(rimNode)
        node.enumerateHierarchy { n, _ in if n.geometry != nil { n.categoryBitMask |= 2 } }
        node.isHidden = true
    }

    private static func tube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let d = b - a
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(simd_length(d)))
        cylinder.radialSegmentCount = 24
        cylinder.materials = [material]
        let n = SCNNode(geometry: cylinder)
        n.simdPosition = (a + b) / 2
        n.simdOrientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(d))
        return n
    }

    func set(connected: Bool, charging: Bool) {
        target = connected ? 1 : 0
        self.charging = charging
    }

    /// Jumps straight to the current state (stills, Reduce Motion).
    func settle() {
        plugged = target
        lightLevel = target
        render()
    }

    func tick(dt: Double, reduceMotion: Bool) {
        if reduceMotion { settle(); return }
        if target > plugged {
            // Slide in, then snap: slow for the first part, quick for the last few millimetres.
            plugged = min(1, plugged + dt * (plugged < 0.8 ? 2.2 : 9))
        } else if target < plugged {
            plugged = max(0, plugged - dt * 6)   // pops away
        }
        let lightGoal = plugged >= 1 ? 1.0 : 0
        lightLevel += (lightGoal - lightLevel) * min(1, dt * 5)
        render()
    }

    private func render() {
        node.isHidden = plugged <= 0.001
        let e = 1 - pow(1 - plugged, 3)
        node.position = SCNVector3(-3.2 * (1 - e), 0, 0)   // out to the left when unplugged
        node.opacity = CGFloat(min(1, plugged * 3))
        // Recolour only when charging starts or stops (building the glow image every frame is costly).
        if shownCharging != charging {
            shownCharging = charging
            let colour = charging ? NSColor(calibratedRed: 1, green: 0.62, blue: 0.12, alpha: 1)
                                  : NSColor(calibratedRed: 0.3, green: 1, blue: 0.42, alpha: 1)
            SceneArt.setIndicator(indicator.dot, indicator.halo, color: colour)
        }
        indicator.node.opacity = CGFloat(lightLevel)
    }
}

// MARK: Battery glow

/// Six cells glowing up through the palm rests and trackpad, filled in order as one battery.
/// Green while charging, white on battery, orange when low.
final class BatteryCells {
    let node = SCNNode()
    private var planes: [SCNNode] = []
    private var key = ""
    private var level = 0.0          // fade in/out

    /// Fill order: left palm rest, centre, right palm rest (front row then back row).
    private static let spots: [(x: Double, z: Double, w: Double, d: Double)] = [
        (-10.6, 8.2, 6.4, 3.2), (-10.6, 4.4, 6.4, 3.4), (0, 7.9, 9.0, 3.0),
        (0, 4.3, 9.0, 3.0), (10.6, 8.2, 6.4, 3.2), (10.6, 4.4, 6.4, 3.4),
    ]

    init() {
        for spot in Self.spots {
            let plane = SCNNode(geometry: SCNPlane(width: spot.w, height: spot.d))
            plane.eulerAngles.x = -.pi / 2
            plane.position = SCNVector3(spot.x, 0.45, spot.z)
            planes.append(plane)
            node.addChildNode(plane)
        }
        node.opacity = 0
    }

    func set(percent: Int, charging: Bool) {
        let tint: NSColor = percent <= 20 && !charging ? NSColor(calibratedRed: 1, green: 0.6, blue: 0.15, alpha: 1)
            : charging ? NSColor(calibratedRed: 0.3, green: 1, blue: 0.5, alpha: 1)
            : NSColor(white: 0.95, alpha: 1)
        let newKey = "\(percent)|\(charging)"
        guard newKey != key else { return }
        key = newKey
        // One battery: each cell holds a sixth of the charge.
        let total = Double(percent) / 100 * Double(planes.count)
        for (i, plane) in planes.enumerated() {
            let fill = min(1, max(0, total - Double(i)))
            let material = SceneArt.constant(Self.cellImage(fill: fill, tint: tint), additive: true)
            material.readsFromDepthBuffer = false
            plane.geometry!.materials = [material]
        }
    }

    func tick(dt: Double, visible: Bool) {
        level += ((visible ? 1 : 0) - level) * min(1, dt * 5)
        node.opacity = CGFloat(level)
        node.isHidden = level < 0.01
    }

    private static func cellImage(fill: Double, tint: NSColor) -> NSImage {
        let size = NSSize(width: 384, height: 192)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(x: 14, y: 14, width: size.width - 28, height: size.height - 28)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32)
        if fill > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSGradient(colors: [tint.withAlphaComponent(0.35), tint.withAlphaComponent(0.7)])!
                .draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width * fill, height: rect.height), angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
        shape.lineWidth = 4
        tint.withAlphaComponent(0.45).setStroke()
        shape.stroke()
        image.unlockFocus()
        return image
    }
}

// MARK: Plugs in every port

/// Builds a smooth cable along a cubic curve: short cylinders with rounded joints.
enum CableArt {
    static func tube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let d = b - a
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(simd_length(d)))
        cylinder.radialSegmentCount = 20
        cylinder.materials = [material]
        let n = SCNNode(geometry: cylinder)
        n.simdPosition = (a + b) / 2
        n.simdOrientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(d))
        return n
    }

    static func cable(_ p: [SIMD3<Float>], radius: CGFloat, material: SCNMaterial, steps: Int = 60) -> SCNNode {
        let node = SCNNode()
        func at(_ t: Float) -> SIMD3<Float> {
            let u = 1 - t
            return u * u * u * p[0] + 3 * u * u * t * p[1] + 3 * u * t * t * p[2] + t * t * t * p[3]
        }
        for i in 0..<steps {
            let a = at(Float(i) / Float(steps)), b = at(Float(i + 1) / Float(steps))
            node.addChildNode(tube(a, b, radius: radius, material: material))
            let joint = SCNSphere(radius: radius)
            joint.segmentCount = 16
            joint.materials = [material]
            let j = SCNNode(geometry: joint)
            j.simdPosition = b
            node.addChildNode(j)
        }
        return node
    }

    static func material(_ white: CGFloat, metal: CGFloat = 0.1, rough: CGFloat = 0.55) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: white, alpha: 1)
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }
}

/// What's plugged into each port, drawn on the 3D Mac: USB-C cables in the Thunderbolt ports
/// (running back towards your displays), an HDMI plug, an SD card, a headphone plug.
/// Each slides in and snaps the last few millimetres, like the MagSafe cable.
final class PortPlugs {
    let node = SCNNode()
    private var plugs: [String: (node: SCNNode, side: Float, plugged: Double, target: Double)] = [:]

    init() {
        let black = CableArt.material(0.06, rough: 0.6)
        let alu = CableArt.material(0.55, metal: 0.8, rough: 0.35)
        // Left side (x < 0): Thunderbolt @2 (back), Thunderbolt @1 (front), headphone jack.
        // Fanned so they never cross: the further forward the port, the further out the cable runs.
        add("Port-USB-C@2", side: -1, usbC(z: -6.4, side: -1, out: 4.5, to: [-24.5, -0.72, -20], body: black, cable: black))
        add("Port-USB-C@1", side: -1, usbC(z: -4.9, side: -1, out: 7.0, to: [-28, -0.72, -20], body: black, cable: black))
        add("headphones", side: -1, headphonePlug(z: -3.65, metal: alu, cable: CableArt.material(0.85)))
        // Right side (x > 0): HDMI (back), Thunderbolt @4, SD card (front).
        add("Port-HDMI@3", side: 1, hdmi(z: -8.25, body: black))
        add("Port-USB-C@4", side: 1, usbC(z: -6.4, side: 1, out: 6.5, to: [27.5, -0.72, -20], body: black, cable: black))
        add("Port-SD Card@1", side: 1, sdCard(z: -4.4))
    }

    private func add(_ id: String, side: Float, _ plug: SCNNode) {
        plug.isHidden = true
        node.addChildNode(plug)
        plugs[id] = (plug, side, 0, 0)
    }

    /// Port y is about -0.33 on the 3D model; x is ±15.6 at the surface.
    private func usbC(z: Float, side: Float, out: Float, to end: SIMD3<Float>, body: SCNMaterial, cable: SCNMaterial) -> SCNNode {
        let n = SCNNode()
        let plug = SCNNode(geometry: SCNBox(width: 1.25, height: 0.38, length: 0.85, chamferRadius: 0.17))
        plug.geometry!.materials = [body]
        plug.simdPosition = [side * 16.2, -0.33, z]
        n.addChildNode(plug)
        let start = SIMD3<Float>(side * 16.8, -0.33, z)
        n.addChildNode(CableArt.cable([start, start + [side * out * 0.6, 0, 0], [side * (16.8 + out), -0.7, z - 2], end], radius: 0.16, material: cable))
        return n
    }

    private func hdmi(z: Float, body: SCNMaterial) -> SCNNode {
        let n = SCNNode()
        let plug = SCNNode(geometry: SCNBox(width: 1.6, height: 0.62, length: 1.75, chamferRadius: 0.12))
        plug.geometry!.materials = [body]
        plug.simdPosition = [16.4, -0.33, z]
        n.addChildNode(plug)
        let start = SIMD3<Float>(17.2, -0.33, z)
        n.addChildNode(CableArt.cable([start, start + [2, 0, 0], [20.5, -0.65, z - 3], [21.5, -0.65, -20]], radius: 0.24, material: body))
        return n
    }

    private func sdCard(z: Float) -> SCNNode {
        let n = SCNNode()
        // About 1.5 cm of the card sticks out of the slot.
        let card = SCNNode(geometry: SCNBox(width: 1.5, height: 0.14, length: 2.3, chamferRadius: 0.05))
        let face = SCNMaterial()
        face.lightingModel = .physicallyBased
        face.diffuse.contents = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)
        face.roughness.contents = 0.4
        card.geometry!.materials = [face]
        card.simdPosition = [16.3, -0.38, z]
        n.addChildNode(card)
        let label = SCNNode(geometry: SCNBox(width: 0.9, height: 0.01, length: 1.6, chamferRadius: 0))
        label.geometry!.materials = [CableArt.material(0.85, rough: 0.7)]
        label.simdPosition = [16.5, -0.305, z]
        n.addChildNode(label)
        return n
    }

    private func headphonePlug(z: Float, metal: SCNMaterial, cable: SCNMaterial) -> SCNNode {
        let n = SCNNode()
        let collar = SCNNode(geometry: SCNCylinder(radius: 0.24, height: 1.1))
        collar.geometry!.materials = [cable]
        collar.eulerAngles.z = .pi / 2
        collar.simdPosition = [-16.15, -0.12, z]
        n.addChildNode(collar)
        let ring = SCNNode(geometry: SCNCylinder(radius: 0.2, height: 0.12))
        ring.geometry!.materials = [metal]
        ring.eulerAngles.z = .pi / 2
        ring.simdPosition = [-15.6, -0.12, z]
        n.addChildNode(ring)
        let start = SIMD3<Float>(-16.7, -0.12, z)
        n.addChildNode(CableArt.cable([start, start + [-2.5, 0, 0], [-21, -0.75, z + 3], [-22, -0.75, 9]], radius: 0.1, material: cable))
        return n
    }

    func set(_ ports: [Ports.Port]) {
        for port in ports {
            guard plugs[port.id] != nil else { continue }
            plugs[port.id]!.target = port.connected ? 1 : 0
        }
    }

    func settle() {
        for id in plugs.keys { plugs[id]!.plugged = plugs[id]!.target }
        render()
    }

    func tick(dt: Double, reduceMotion: Bool) {
        if reduceMotion { settle(); return }
        for id in plugs.keys {
            var p = plugs[id]!
            if p.target > p.plugged { p.plugged = min(1, p.plugged + dt * (p.plugged < 0.8 ? 2.2 : 9)) }
            else if p.target < p.plugged { p.plugged = max(0, p.plugged - dt * 6) }
            plugs[id] = p
        }
        render()
    }

    private func render() {
        for (_, p) in plugs {
            p.node.isHidden = p.plugged <= 0.001
            let e = 1 - pow(1 - p.plugged, 3)
            p.node.simdPosition = [p.side * Float(2.8 * (1 - e)), 0, 0]   // slides in from outside the port
            p.node.opacity = CGFloat(min(1, p.plugged * 3))
        }
    }
}

// MARK: Gear on the desk

/// AirPods Pro case standing beside the Mac with its lid open, when the AirPods are connected.
final class AirPodsCase {
    let node = SCNNode()
    private var shown = 0.0, target = 0.0

    init() {
        let white = SCNMaterial()
        white.lightingModel = .physicallyBased
        white.diffuse.contents = NSColor(white: 0.96, alpha: 1)
        white.roughness.contents = 0.22
        white.clearCoat.contents = 0.8
        // Closed case lying flat, as in Apple's product shots: 6.0 × 4.5, 2.2 tall, very rounded.
        let body = SCNNode(geometry: SCNBox(width: 6.0, height: 2.2, length: 4.5, chamferRadius: 1.05))
        body.geometry!.materials = [white]
        body.position = SCNVector3(0, 1.1, 0)
        node.addChildNode(body)
        // The lid seam: a fine dark line around the case, a third of the way from the back.
        let seam = SCNNode(geometry: SCNBox(width: 6.02, height: 2.0, length: 0.03, chamferRadius: 0.9))
        seam.geometry!.materials = [CableArt.material(0.55, rough: 0.5)]
        seam.position = SCNVector3(0, 1.1, -0.8)
        node.addChildNode(seam)
        // Status light on the front edge.
        let light = SCNNode(geometry: SCNSphere(radius: 0.07))
        light.geometry!.materials = [SceneArt.constant(NSColor(calibratedRed: 0.3, green: 1, blue: 0.4, alpha: 1))]
        light.position = SCNVector3(0, 1.45, 2.27)
        node.addChildNode(light)
        node.position = SCNVector3(21, -0.95, 4)
        node.eulerAngles.y = -0.35
        node.isHidden = true
    }

    /// Corners for framing, so the case stays in view when it's out.
    var framingPoints: [SIMD3<Float>] {
        guard shown > 0.5 else { return [] }
        let c = node.simdPosition
        return [[c.x - 3.5, c.y, c.z - 3], [c.x + 3.5, c.y, c.z + 3], [c.x - 3.5, c.y + 2.2, c.z], [c.x + 3.5, c.y + 2.2, c.z]]
    }

    func set(visible: Bool) { target = visible ? 1 : 0 }
    func settle() { shown = target; render() }

    func tick(dt: Double, reduceMotion: Bool) {
        if reduceMotion { settle(); return }
        shown += (target - shown) * min(1, dt * 5)
        render()
    }

    private func render() {
        node.isHidden = shown < 0.01
        node.opacity = CGFloat(shown)
        node.scale = SCNVector3(0.9 + 0.1 * shown, 0.9 + 0.1 * shown, 0.9 + 0.1 * shown)
    }
}

/// An iPhone clipped to the top of the lid, cameras facing you, while it's the webcam
/// (Continuity Camera). Parented to the lid so it follows the lid angle.
final class ContinuityPhone {
    let node = SCNNode()
    private var shown = 0.0, target = 0.0
    private var restPosition = SIMD3<Float>(0, 0, 0)

    /// `top` is the top-centre of the lid and `up`/`back` its directions, in the lid's own space.
    init(top: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>) {
        let frame = CableArt.material(0.18, metal: 0.85, rough: 0.3)       // titanium
        let glass = CableArt.material(0.05, metal: 0.1, rough: 0.25)
        // Landscape iPhone: 14.7 wide, 7.15 tall, 0.83 thick.
        let phone = SCNNode(geometry: SCNBox(width: 14.7, height: 7.15, length: 0.83, chamferRadius: 0.4))
        // Box faces: front (cameras, towards you), right, back (screen), left, top, bottom.
        phone.geometry!.materials = [glass, frame, glass, frame, frame, frame]
        node.addChildNode(phone)
        // Camera bump on the side facing you, top left.
        let bump = SCNNode(geometry: SCNBox(width: 3.4, height: 3.4, length: 0.25, chamferRadius: 0.6))
        bump.geometry!.materials = [glass]
        bump.position = SCNVector3(-5.2, 1.4, 0.52)
        node.addChildNode(bump)
        for (x, y) in [(-6.0, 2.2), (-6.0, 0.6), (-4.4, 1.4)] {
            let lens = SCNNode(geometry: SCNCylinder(radius: 0.55, height: 0.25))
            lens.geometry!.materials = [CableArt.material(0.02, metal: 0.4, rough: 0.1)]
            lens.eulerAngles.x = .pi / 2
            lens.position = SCNVector3(x, y, 0.72)
            node.addChildNode(lens)
        }
        // Mount clip over the top of the lid.
        let clip = SCNNode(geometry: SCNBox(width: 3.0, height: 1.6, length: 1.6, chamferRadius: 0.3))
        clip.geometry!.materials = [CableArt.material(0.08, rough: 0.6)]
        clip.position = SCNVector3(0, -3.4, -0.6)
        node.addChildNode(clip)

        // Stand the phone on the lid's top edge, leaning with the lid, just behind it.
        restPosition = top + up * 1.8 + back * 0.6
        node.simdPosition = restPosition
        node.simdOrientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(up))
        node.isHidden = true
    }

    func set(visible: Bool) { target = visible ? 1 : 0 }
    func settle() { shown = target; render() }

    func tick(dt: Double, reduceMotion: Bool) {
        if reduceMotion { settle(); return }
        shown += (target - shown) * min(1, dt * 5)
        render()
    }

    private func render() {
        node.isHidden = shown < 0.01
        node.opacity = CGFloat(shown)
        // Drops onto the clip from a little above.
        node.simdPosition = restPosition + SIMD3<Float>(0, Float(1.5 * (1 - shown)), 0)
    }
}

// MARK: Your desk

/// The user's desk, to scale (cm; desk surface at y = -0.95 under the Mac):
/// A black 110 × 54 cm standing desk, lowered (~71 cm), with a dual monitor arm clamped at the back
/// centre and two 28" monitors side by side, angled in.
/// Shown only in the desk view; monitors go dark when they're not connected.
@MainActor
final class DeskModel {
    let node = SCNNode()
    private(set) var framingPoints: [SIMD3<Float>] = []
    private var screens: [(material: SCNMaterial, on: Double, target: Double)] = []
    private let onImage: [NSImage]
    private let offImage: NSImage
    /// What's really on each monitor (left, right), when DeskBar may capture the screens.
    private var liveImages: [NSImage?] = [nil, nil]

    func setScreenImage(_ image: NSImage?, index: Int) {
        guard index < 2 else { return }
        liveImages[index] = image
        if screens[index].on > 0.02 { screens[index].material.diffuse.contents = image ?? onImage[index] }
    }

    init() {
        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ chamfer: CGFloat, _ m: SCNMaterial) -> SCNNode {
            let n = SCNNode(geometry: SCNBox(width: w, height: h, length: l, chamferRadius: chamfer))
            n.geometry!.materials = [m]
            return n
        }
        let deskBlack = CableArt.material(0.05, metal: 0.05, rough: 0.75)
        let frameBlack = CableArt.material(0.07, metal: 0.5, rough: 0.45)
        let plastic = CableArt.material(0.06, metal: 0.1, rough: 0.5)
        // Desk at its lowest height (about 71 cm from the floor to the top surface).
        let top: Float = -0.95, deskZ: Float = -6, floorY: Float = -0.95 - 71

        let tabletop = box(110, 2.5, 54, 0.5, deskBlack)
        tabletop.simdPosition = [0, top - 1.25, deskZ]
        node.addChildNode(tabletop)
        // Lowered all the way: the inner stage has slid into the outer one, so each leg reads as
        // one column with only a sliver of the inner stage showing under the top.
        for x: Float in [-44, 44] {
            let columnTop = top - 2.5 - 2.5, columnBottom = floorY + 3
            let lower = box(7.2, CGFloat(columnTop - columnBottom), 6.2, 0.4, frameBlack)
            lower.simdPosition = [x, (columnTop + columnBottom) / 2, deskZ]
            node.addChildNode(lower)
            let upper = box(6, 2.5, 5, 0.3, frameBlack); upper.simdPosition = [x, top - 2.5 - 1.25, deskZ]; node.addChildNode(upper)
            let foot = box(7, 3, 52, 1.2, frameBlack); foot.simdPosition = [x, floorY + 1.5, deskZ]; node.addChildNode(foot)
            let bracket = box(6, 2, 46, 0.3, frameBlack); bracket.simdPosition = [x, top - 3.5, deskZ]; node.addChildNode(bracket)
        }
        let crossbar = box(82, 4, 4, 0.4, frameBlack); crossbar.simdPosition = [0, top - 5.5, deskZ - 4]; node.addChildNode(crossbar)
        // Memory panel under the front-right edge (display off: the desk can't tell the Mac its height).
        let panel = box(15, 2.6, 4.5, 0.6, plastic); panel.simdPosition = [38, top - 3.6, 19.5]; node.addChildNode(panel)
        for x: Float in [36.5, 38.5, 40.5, 42.5, 44.5] {
            let button = SCNNode(geometry: SCNCylinder(radius: 0.45, height: 0.3))
            button.geometry!.materials = [CableArt.material(0.15, rough: 0.4)]
            button.eulerAngles.x = .pi / 2
            button.simdPosition = [x, top - 3.6, 21.85]
            node.addChildNode(button)
        }
        // Monitor arm: clamp, pole.
        let clamp = box(8, 10, 6, 0.8, frameBlack); clamp.simdPosition = [0, top - 3, -32]; node.addChildNode(clamp)
        let pole = SCNNode(geometry: SCNCylinder(radius: 1.6, height: 44)); pole.geometry!.materials = [frameBlack]
        pole.simdPosition = [0, top + 22, -31]; node.addChildNode(pole)
        let cap = SCNNode(geometry: SCNCylinder(radius: 1.9, height: 2)); cap.geometry!.materials = [frameBlack]
        cap.simdPosition = [0, top + 44, -31]; node.addChildNode(cap)

        // Screen images: a dark desktop with a menu bar; black when off.
        onImage = [-1, 1].map { side in
            ImageRenderer(content: ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.20), Color(red: 0.03, green: 0.03, blue: 0.07)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 0.35, green: 0.25, blue: 0.7).opacity(0.35), .clear],
                               center: .init(x: side < 0 ? 0.7 : 0.3, y: 0.7), startRadius: 0, endRadius: 900)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 36)
            }.frame(width: 1512, height: 850)).nsImage ?? NSImage()
        }
        offImage = NSImage(size: NSSize(width: 8, height: 8))
        offImage.lockFocus(); NSColor(white: 0.015, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); offImage.unlockFocus()

        // Two 28" monitors: 63.8 × 37.5 cm, bottom edge ~20 cm above the desk, angled in 12°.
        let monitorY: Float = top + 38.75, monitorZ: Float = -25
        for (index, side) in [Float(-1), 1].enumerated() {
            let m = SCNNode()
            m.addChildNode(box(63.8, 37.5, 2.2, 0.4, plastic))
            let back = box(42, 24, 3.2, 3, plastic); back.simdPosition = [0, -1, -2.4]; m.addChildNode(back)
            let screenMaterial = SceneArt.constant(offImage)
            let screen = SCNNode(geometry: SCNPlane(width: 62.1, height: 34.9))
            screen.geometry!.materials = [screenMaterial]
            screen.simdPosition = [0, 0.6, 1.12]
            m.addChildNode(screen)
            screens.append((screenMaterial, 0, 0))
            m.simdPosition = [side * 32.6, monitorY, monitorZ]
            m.eulerAngles.y = CGFloat(-side * 12 * .pi / 180)
            node.addChildNode(m)
            // Arm from the pole to the monitor's VESA plate.
            let shoulder = SIMD3<Float>(0, monitorY, -31), vesa = m.simdConvertPosition([0, 0, -4], to: nil)
            let elbow = SIMD3<Float>(side * 16, monitorY, -34)
            for (a, b) in [(shoulder, elbow), (elbow, vesa)] {
                node.addChildNode(CableArt.tube(a, b, radius: 1.3, material: frameBlack))
                let joint = SCNNode(geometry: SCNSphere(radius: 1.6)); joint.geometry!.materials = [frameBlack]
                joint.simdPosition = b
                node.addChildNode(joint)
            }
            for corner: SIMD3<Float> in [[-32, -19, 0], [32, -19, 0], [-32, 19, 0], [32, 19, 0]] {
                framingPoints.append(m.simdConvertPosition(corner, to: nil))
            }
            _ = index
        }
        // Frame the surface you use: the monitors and the tabletop. The legs fall off the bottom of the card.
        framingPoints += [[-55, top, 21], [55, top, 21], [-55, top, -33], [55, top, -33]]
        node.opacity = 0
        node.isHidden = true
    }

    /// Which monitors are connected (left, right).
    func setMonitors(left: Bool, right: Bool) {
        screens[0].target = left ? 1 : 0
        screens[1].target = right ? 1 : 0
    }

    /// Fades the whole desk in or out, and each screen on or off.
    func tick(dt: Double, visible: Double) {
        node.opacity = CGFloat(visible)
        node.isHidden = visible < 0.01
        for i in screens.indices {
            guard abs(screens[i].target - screens[i].on) > 0.001 || screens[i].material.diffuse.contents == nil else { continue }
            screens[i].on += (screens[i].target - screens[i].on) * min(1, dt * 4)
            if abs(screens[i].target - screens[i].on) < 0.002 { screens[i].on = screens[i].target }
            let material = screens[i].material
            let wanted: NSImage = screens[i].on > 0.02 ? (liveImages[i] ?? onImage[i]) : offImage
            if material.diffuse.contents as? NSImage !== wanted { material.diffuse.contents = wanted }
            material.multiply.contents = NSColor(white: CGFloat(max(0.05, screens[i].on)), alpha: 1)
        }
    }
}
