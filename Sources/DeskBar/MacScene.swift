import AppKit
import SceneKit
import SwiftUI

/// The "living Mac": Apple's 3D MacBook Pro model, posed and lit, reacting to the panel.
///
/// Camera framing is automatic: every frame, the Mac's real outline is projected and the
/// camera is nudged so the Mac sits centred in the space for the current mode. Animation is
/// driven from a 60 Hz main-thread timer that only runs while the panel is open.
@MainActor
final class MacScene: ObservableObject {
    enum Mode: Equatable {
        case rest, heat, charging, ports(Ports.Side), desk
        var isPorts: Bool { if case .ports = self { true } else { false } }
    }

    /// The panel's hero card; the window uses a larger scene.
    nonisolated static let panelSize = CGSize(width: 320, height: 210)
    let size: CGSize
    /// The window's scene skips the panel's opening animation.
    var playsIntro = true
    /// Animation rate. The DeskBar window's big Mac only drifts slowly, so it runs at 30 to halve the cost.
    var frameRate: Double = 60

    @Published private(set) var loaded = false
    /// Apple's model isn't in the bundle or on this Mac yet; the panel shows a flat Mac until it is.
    @Published private(set) var modelMissing = false
    @Published private(set) var downloadingModel = false
    @Published private(set) var mode: Mode = .rest
    /// Port label anchors in view points (top-left origin), shown once the camera has settled.
    @Published private(set) var portAnchors: [String: CGPoint] = [:]
    @Published private(set) var settled = false
    /// False while the opening plays; the panel's title and tiles cascade in when it turns true.
    @Published private(set) var revealed = true
    /// Labels shown on the card, most important first (at most two).
    @Published private(set) var pills: [HeroPill] = []

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let camera = SCNCamera()
    private var hinge: SCNNode?
    private var screenMesh: SCNNode?
    private var outline: [SIMD3<Float>] = []        // whole Mac, lid open
    private var basePoints: [SIMD3<Float>] = []
    private var lidPoints: [SIMD3<Float>] = []
    private var lidNode: SCNNode?
    private let lidSensor = LidSensor()
    private var lidTarget = 110.0          // degrees from the sensor (the model's lid sits open at ~110°)
    private var lidShown = 110.0           // smoothed angle shown on the 3D lid
    private var lidFramed = 110.0          // angle the camera frames for; follows once the lid settles
    private var lidPoll = 0
    private var lidOverride: Double?       // snapshot testing only
    private let cable = MagSafeCable()
    private let cells = BatteryCells()
    private let plugs = PortPlugs()
    private let airPods = AirPodsCase()
    private var phone: ContinuityPhone?
    private let desk = DeskModel()
    private var deskLevel = 0.0
    private var deskAuto = false             // desk view chosen automatically by clamshell
    private var floorNode: SCNNode?
    private var zoomAccumulator = 0.0
    private var lastZoomStep = Date.distantPast
    private var cameraLight: (node: SCNNode, dot: SCNMaterial, halo: SCNMaterial)?
    private var state = MacState()
    private let heatGlow: SCNNode
    private let chargeGlow: SCNNode
    private var rimLight: SCNLight?
    private var lights: [(light: SCNLight, base: CGFloat)] = []
    private let glintLight = SCNLight()
    private let glintNode = SCNNode()
    private var keyLegends: [SCNMaterial] = []
    private var keyGaps: [SCNMaterial] = []

    // Opening.
    private enum Intro { case full, quick, none }
    private var intro = Intro.none
    private var introFrames = 0          // the opening's clock starts once frames are flowing
    private var wokeSinceLastFull = true
    private var warning = false
    private var batteryPercent: Int?
    private var statusImage: NSImage?
    private var statusIsClock = false
    private var wakeImage: NSImage?
    private var blankImage: NSImage?
    private var lean = SIMD2<Double>(0, 0)        // pointer position over the card, -1…1
    private var leanSmoothed = SIMD2<Double>(0, 0)
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Animation state.
    private var timer: Timer?
    private var last = Date()
    /// The demo video steps this clock one frame at a time, so a slow render can't skip animation.
    private var virtualNow: Date?
    private var clockNow: Date { virtualNow ?? Date() }
    private var introStart = Date.distantPast
    private var current: Pose
    private var yaw = 0.0                 // from dragging, degrees
    private var move: Move?               // a planned camera move between modes

    /// A timed camera move: eases from one framed pose to the next, pulling back and rising
    /// mid-way so the camera orbits around the Mac instead of cutting across it.
    private struct Move {
        var from: Pose, to: Pose
        var via: Pose?                    // waypoint the path curves through (side switches)
        var start: Date, duration: Double
        var pullBack: Double, rise: Double
    }
    private var heatLevel = 0.0           // 0…1, smoothed
    private var chargeLevel = 0.0
    private var clock = 0.0
    private var chargingNow = false
    private var temperature = 40.0
    private var screenKey = ""

    struct Pose {
        var angle: Double, height: Double, distance: Double, fov: Double
        var target: SIMD3<Double>
    }

    init(size: CGSize = MacScene.panelSize) {
        self.size = size
        current = Pose(angle: -34, height: 30, distance: 84, fov: 24, target: [0, 5, -2])
        heatGlow = Self.glow(width: 18, height: 12, inner: NSColor(calibratedRed: 1, green: 0.5, blue: 0.15, alpha: 0.9),
                             outer: NSColor(calibratedRed: 1, green: 0.3, blue: 0.05, alpha: 0.35))
        chargeGlow = Self.glow(width: 5, height: 3, inner: NSColor(calibratedRed: 0.3, green: 1, blue: 0.45, alpha: 1),
                               outer: NSColor(calibratedRed: 0.1, green: 0.9, blue: 0.3, alpha: 0.4))
        camera.zNear = 1
        camera.zFar = 600
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scene.background.contents = NSColor.clear
        // The full opening plays again after the Mac wakes from sleep.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeSinceLastFull = true }
        }
    }

    // MARK: Loading

    /// Apple's 3D MacBook Pro (from the "View in AR" button on apple.com) isn't ours to redistribute,
    /// so it's never in the repository: a local build can bundle it, or DeskBar downloads it from
    /// apple.com onto this Mac when you ask.
    static let modelSource = URL(string: "https://www.apple.com/105/media/us/macbook-pro/2025/785e1bc4-d1bd-4cf4-b1b3-94b9411c9e74/ar/macbook-pro-14-in-space-black-variant.usdz")!
    static var downloadedModel: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskBar/macbook-pro-14-space-black.usdz")
    }
    static var modelURL: URL? {
        if ProcessInfo.processInfo.environment["DESKBAR_NO_MODEL"] != nil { return nil }   // snapshot tests
        return Bundle.main.url(forResource: "macbook-pro-14-space-black", withExtension: "usdz")
            ?? (FileManager.default.fileExists(atPath: downloadedModel.path) ? downloadedModel : nil)
    }

    /// Loads the model in the background the first time the panel opens.
    func loadIfNeeded() {
        guard !loaded, hinge == nil else { return }
        guard let url = Self.modelURL else { modelMissing = true; return }
        modelMissing = false
        DispatchQueue.global(qos: .userInitiated).async {
            guard let model = try? SCNScene(url: url) else { return }
            let nodes = model.rootNode.childNodes
            DispatchQueue.main.async { self.install(nodes) }
        }
    }

    /// Fetches Apple's model (about 10 MB) into Application Support, then loads it.
    func downloadModel() {
        guard !downloadingModel else { return }
        downloadingModel = true
        Task {
            defer { downloadingModel = false }
            guard let (file, response) = try? await URLSession.shared.download(from: Self.modelSource),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let destination = Self.downloadedModel
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            guard (try? FileManager.default.moveItem(at: file, to: destination)) != nil else { return }
            loadIfNeeded()
        }
    }

    static var installMilliseconds = 0.0

    private func install(_ nodes: [SCNNode]) {
        let installStart = DispatchTime.now().uptimeNanoseconds
        defer { Self.installMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - installStart) / 1e6 }
        let root = scene.rootNode
        nodes.forEach { root.addChildNode($0) }

        // Wrap the lid so it rotates about the back edge of the base.
        if let lid = root.childNode(withName: "RcexTyyhpuJYATQ", recursively: true), let parent = lid.parent {
            let hinge = SCNNode()
            hinge.position = SCNVector3(0, -0.2, -11.0)
            parent.addChildNode(hinge)
            lid.removeFromParentNode()
            lid.position = SCNVector3(0, 0.2, 11.0)
            hinge.addChildNode(lid)
            self.hinge = hinge
            lidNode = lid
        }
        screenMesh = root.childNode(withName: "tfTbkkzhxqpKRgC", recursively: true)
        // The screen glows on its own and shouldn't catch light; soften the glass over it so
        // the camera passing in front doesn't flash a hard highlight.
        screenMesh?.geometry?.materials.forEach { $0.lightingModel = .constant }
        // Satin finish on the aluminium so the camera passing over it doesn't flash silver.
        for top in nodes {
            top.enumerateHierarchy { node, _ in
                for material in node.geometry?.materials ?? [] {
                    if let r = material.roughness.contents as? NSNumber, r.doubleValue < 0.42 {
                        material.roughness.contents = NSNumber(value: 0.42)
                    }
                }
            }
        }
        root.childNode(withName: "nAIWMiVEtSYdjdZ", recursively: true)?.geometry?.materials.forEach {
            $0.roughness.contents = 0.45
            $0.specular.intensity = 0.3
        }
        outline = Self.surfacePoints(of: nodes)
        if let lidNode {
            lidPoints = Self.surfacePoints(of: [lidNode])
            let lidSet = Set(lidPoints.map { "\($0)" })
            basePoints = outline.filter { !lidSet.contains("\($0)") }
            // Camera light: tiny and exact, just right of the lens; moves with the lid.
            let light = SceneArt.indicator(radius: 0.055, halo: 0.55)
            SceneArt.setIndicator(light.dot, light.halo, color: NSColor(calibratedRed: 0.25, green: 1, blue: 0.4, alpha: 1))
            light.node.position = lidNode.convertPosition(SCNVector3(0.62, 19.55, -18.42), from: nil)
            light.node.isHidden = true
            lidNode.addChildNode(light.node)
            cameraLight = light
        } else {
            basePoints = outline
        }
        root.addChildNode(cable.node)
        root.addChildNode(cells.node)
        root.addChildNode(plugs.node)
        root.addChildNode(airPods.node)
        root.addChildNode(desk.node)
        if let lidNode {
            // The lid leans back about 21° from vertical when open; its top edge is at y 20.1, z -18.7.
            let lean = Float(20.8 * Double.pi / 180)
            let up = SCNVector3(0, CGFloat(cos(lean)), CGFloat(-sin(lean)))
            let back = SCNVector3(0, CGFloat(-sin(lean)), CGFloat(-cos(lean)))
            let top = lidNode.convertPosition(SCNVector3(0, 20.1, -18.7), from: nil)
            let localUp = lidNode.convertVector(up, from: nil), localBack = lidNode.convertVector(back, from: nil)
            let iPhone = ContinuityPhone(top: SIMD3(Float(top.x), Float(top.y), Float(top.z)),
                                         up: SIMD3(Float(localUp.x), Float(localUp.y), Float(localUp.z)),
                                         back: SIMD3(Float(localBack.x), Float(localBack.y), Float(localBack.z)))
            lidNode.addChildNode(iPhone.node)
            phone = iPhone
        }

        // Studio lighting with a shadow-catching floor.
        // Studio surroundings: bright overhead, dark towards the horizon, so the aluminium
        // doesn't mirror a bright wall when the camera swings low around it.
        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.5
        let key = addLight(.directional, 950, SCNVector3(10, 60, 30), shadow: true)
        let fill = addLight(.directional, 420, SCNVector3(-45, 18, 25))
        let rim = addLight(.directional, 500, SCNVector3(0, 25, -60))
        let ambient = addLight(.ambient, 240, SCNVector3(0, 0, 0))
        rimLight = rim
        lights = [key, fill, rim, ambient].map { ($0, $0.intensity) }
        // A narrow light that sweeps along the front edge as the Mac turns out of the opening.
        glintLight.type = .spot
        glintLight.spotInnerAngle = 4
        glintLight.spotOuterAngle = 18
        glintLight.intensity = 0
        glintNode.light = glintLight
        root.addChildNode(glintNode)
        // Keyboard backlight: the key legends glow and light spills from the gaps between keys.
        keyLegends = root.childNode(withName: "wyClPAIazRlKQnt", recursively: true)?.geometry?.materials ?? []
        keyGaps = root.childNode(withName: "dAVNlHAHYLbkxrB", recursively: true)?.geometry?.materials ?? []
        let warm = NSColor(calibratedRed: 1, green: 0.94, blue: 0.82, alpha: 1)
        (keyLegends + keyGaps).forEach { $0.emission.contents = warm; $0.emission.intensity = 0 }
        blankImage = Self.solidImage(white: 0.12)
        let floor = SCNFloor()
        floor.reflectivity = 0
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .shadowOnly
        floor.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -0.95, 0)
        root.addChildNode(floorNode)
        self.floorNode = floorNode

        heatGlow.eulerAngles.x = -.pi / 2
        heatGlow.position = SCNVector3(0, 0.45, -6.5)
        chargeGlow.eulerAngles.y = -.pi / 2
        chargeGlow.position = SCNVector3(-15.75, -0.3, -8.2)
        root.addChildNode(heatGlow)
        root.addChildNode(chargeGlow)

        loaded = true
        if timer != nil { beginIntro() } else { prewarm() }
    }

    /// Renders one frame offscreen so the graphics are prepared before the panel first opens
    /// (otherwise the first frame of the opening takes ~200 ms).
    private func prewarm() {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        apply(current)
        _ = renderer.snapshot(atTime: 0, with: CGSize(width: size.width * 2, height: size.height * 2),
                              antialiasingMode: .multisampling4X)
    }

    @discardableResult
    private func addLight(_ type: SCNLight.LightType, _ intensity: CGFloat, _ position: SCNVector3, shadow: Bool = false) -> SCNLight {
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        if shadow {
            light.castsShadow = true
            light.shadowMode = .deferred
            light.shadowRadius = 18
            light.shadowSampleCount = 8
            light.shadowColor = NSColor(white: 0, alpha: 0.5)
        }
        let node = SCNNode()
        node.light = light
        node.position = position
        node.look(at: SCNVector3(0, 4, 0))
        scene.rootNode.addChildNode(node)
        return light
    }

    /// An equirectangular studio: soft light from above fading to near-black below the horizon.
    private static func studioEnvironment() -> NSImage {
        let size = NSSize(width: 256, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(white: 0.85, alpha: 1), NSColor(white: 0.45, alpha: 1),
                            NSColor(white: 0.12, alpha: 1), NSColor(white: 0.05, alpha: 1)],
                   atLocations: [0, 0.3, 0.5, 1], colorSpace: .deviceGray)!
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }

    private static func glow(width: CGFloat, height: CGFloat, inner: NSColor, outer: NSColor) -> SCNNode {
        let image = NSImage(size: NSSize(width: 256, height: 256))
        image.lockFocus()
        let center = NSPoint(x: 128, y: 128)
        NSGradient(colors: [inner, outer, outer.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: 127, options: [])
        image.unlockFocus()
        let plane = SCNPlane(width: width, height: height)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.diffuse.contents = image
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.opacity = 0
        return node
    }

    /// Every 120th vertex of the Mac's meshes (~900 points), in world space with the lid open.
    private static func surfacePoints(of nodes: [SCNNode]) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for top in nodes {
            top.enumerateHierarchy { node, _ in
                guard let source = node.geometry?.sources(for: .vertex).first, source.usesFloatComponents,
                      source.bytesPerComponent == 4 else { return }
                source.data.withUnsafeBytes { raw in
                    for i in stride(from: 0, to: source.vectorCount, by: 120) {
                        let base = source.dataOffset + i * source.dataStride
                        let p = SCNVector3(raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                                           raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                                           raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
                        let w = node.convertPosition(p, to: nil)
                        points.append(SIMD3(Float(w.x), Float(w.y), Float(w.z)))
                    }
                }
            }
        }
        return points
    }

    // MARK: Control

    /// Starts animating while the panel is open.
    func start() {
        loadIfNeeded()
        guard timer == nil else { return }
        last = Date()
        let timer = Timer(timeInterval: 1.0 / frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if loaded { beginIntro() }
    }

    func stop() {
        guard timer != nil else { return }   // only when the panel was actually showing
        timer?.invalidate()
        timer = nil
        // Hide the panel's contents now if the next open will play the full opening,
        // so they don't flash before cascading in.
        if loaded && !reduceMotion && fullIntroDue && playsIntro { revealed = false }
    }

    /// The full opening plays on the first open of the day and after the Mac wakes;
    /// every other open gets a quick settle; Reduce Motion gets neither.
    private var fullIntroDue: Bool {
        let last = UserDefaults.standard.object(forKey: "lastFullIntro") as? Date ?? .distantPast
        return wokeSinceLastFull || !Calendar.current.isDateInToday(last)
    }

    private func beginIntro() {
        yaw = 0
        move = nil
        if mode.isPorts { mode = .rest; portAnchors = [:] }
        introStart = clockNow
        if reduceMotion {
            intro = .none
            finishIntro()
        } else if fullIntroDue && playsIntro {
            intro = .full
            introFrames = 0
            revealed = false
            wokeSinceLastFull = false
            UserDefaults.standard.set(Date(), forKey: "lastFullIntro")
            wakeImage = chargingNow && batteryPercent != nil ? Self.chargingImage(batteryPercent!) : Self.clockImage()
            setLights(0.04)
            hinge?.eulerAngles.x = 1.92
            applyScreen(blankImage, intensity: 0)
        } else {
            intro = .quick
            revealed = true
            hinge?.eulerAngles.x = 0
            setLights(1)
            applyScreen(statusImage, intensity: 1)
            // Start just off the resting pose and let it settle in.
            var start = basePose(for: .rest)
            start.angle -= 3
            frame(&start)
            start.distance *= 1.03
            current = start
        }
    }

    /// Jumps to the end of the opening (Reduce Motion, or a click or drag during it).
    private func finishIntro() {
        intro = .none
        introStart = .distantPast
        hinge?.eulerAngles.x = 0
        setLights(1)
        setBacklight(0)
        glintLight.intensity = 0
        applyScreen(statusImage, intensity: 1)
        var rest = basePose(for: mode)
        frame(&rest)
        current = rest
        revealed = true
    }

    private func setLights(_ level: Double, rim: Double = 1, overhead: Double = 1) {
        for (index, entry) in lights.enumerated() {
            entry.light.intensity = entry.base * CGFloat(level * (index == 2 ? rim : 1))
        }
        scene.lightingEnvironment.intensity = CGFloat(1.5 * (0.1 + 0.9 * level) * overhead)
    }

    private func setBacklight(_ level: Double) {
        keyLegends.forEach { $0.emission.intensity = CGFloat(level * 3.2) }
        keyGaps.forEach { $0.emission.intensity = CGFloat(level * 1.1) }
    }

    private func applyScreen(_ image: NSImage?, intensity: Double) {
        guard let screenMesh else { return }
        for material in screenMesh.geometry?.materials ?? [] {
            if let image, material.emission.contents as? NSImage !== image { material.emission.contents = image }
            material.diffuse.contents = NSColor.black
            material.emission.intensity = CGFloat(intensity)
        }
    }

    /// The desk button on the card: between the MacBook and the whole desk.
    func toggleDesk() {
        if intro == .full { finishIntro() }
        deskAuto = false
        setMode(mode == .desk ? .rest : .desk)
    }

    /// Pinch on the card: out to the desk, in to the MacBook.
    func zoom(by delta: Double) {
        guard intro != .full, !mode.isPorts else { return }
        zoomAccumulator += delta
        guard Date().timeIntervalSince(lastZoomStep) > 0.6 else { return }
        if zoomAccumulator > 5, mode != .desk {
            deskAuto = false; setMode(.desk)
        } else if zoomAccumulator < -5, mode == .desk {
            deskAuto = false; setMode(.rest)
        } else { return }
        zoomAccumulator = 0
        lastZoomStep = Date()
    }

    /// Scroll on the card: one swipe (or one burst of mouse-wheel clicks) switches between the
    /// MacBook and the desk exactly once. Momentum and the rest of the same swipe are ignored.
    private var swipeUsed = false
    private var lastScrollEvent = Date.distantPast

    func scrollSwitch(by delta: Double, phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        guard intro != .full, !mode.isPorts else { return }
        let now = Date()
        if !momentum.isEmpty { lastScrollEvent = now; return }            // momentum after the swipe: ignore
        let newGesture = phase.contains(.began) || (phase.isEmpty && now.timeIntervalSince(lastScrollEvent) > 0.5)
        lastScrollEvent = now
        if newGesture { swipeUsed = false; zoomAccumulator = 0 }
        guard !swipeUsed else { return }
        zoomAccumulator += abs(delta)
        guard zoomAccumulator > 5 else { return }
        swipeUsed = true
        zoomAccumulator = 0
        deskAuto = false
        setMode(mode == .desk ? .rest : .desk)
    }


    /// The pointer over the card (-1…1 each way), or nil when it leaves.
    func pointer(_ point: SIMD2<Double>?) { lean = point ?? .zero }

    /// Mode chosen by the panel's open tile; clicking the Mac toggles the ports view on top.
    func follow(tile: String) {
        switch tile {
        case "cpu": setMode(.heat)
        case "battery": setMode(.charging)
        default: if !mode.isPorts && mode != .desk { setMode(.rest) }
        }
    }

    func setMode(_ new: Mode) {
        guard new != mode else { return }
        let sideSwitch = mode.isPorts && new.isPorts
        mode = new
        settled = false
        portAnchors = [:]
        update(state)
        yaw = 0
        // Plan the move to the new framed pose (skipped during the opening animation).
        guard loaded, intro != .full, !reduceMotion else { return }
        var target = basePose(for: new)
        frame(&target)
        // Side switches curve out through a front-on view of the whole Mac.
        var via: Pose?
        if sideSwitch {
            var overview = Pose(angle: (current.angle + target.angle) / 2, height: 16, distance: 70, fov: 22, target: [0, 3, -3])
            frame(&overview, points: outline, region: CGRect(x: 30, y: 30, width: size.width - 60, height: size.height - 60), fill: 0.9)
            via = overview
        }
        apply(current)
        move = Move(from: current, to: target, via: via, start: clockNow,
                    duration: sideSwitch ? 1.25 : 0.9, pullBack: 0.25, rise: 4)
    }

    func click() {
        if intro == .full { finishIntro(); return }
        if mode == .desk { deskAuto = false; setMode(.rest); return }
        setMode(mode.isPorts ? .rest : .ports(.left))
    }
    func resetView() { yaw = 0; setMode(.rest) }
    func drag(by dx: Double) {
        if intro == .full { finishIntro() }
        move = nil
        if mode.isPorts { setMode(.rest); move = nil }
        yaw += dx * 0.45
    }

    /// Latest readings from the panel.
    func update(_ new: MacState) {
        state = new
        temperature = new.temperature ?? 40
        chargingNow = new.charging
        warning = new.warning != nil
        batteryPercent = new.batteryPercent
        cable.set(connected: new.magSafeConnected, charging: new.charging)
        if let percent = new.batteryPercent { cells.set(percent: percent, charging: new.charging) }
        plugs.set(new.ports)
        desk.setMonitors(left: new.leftMonitor, right: new.rightMonitor)
        airPods.set(visible: new.airPods != nil)
        phone?.set(visible: new.continuityCamera)
        // The built-in camera's light only when the built-in camera is the one in use.
        cameraLight?.node.isHidden = !(new.cameraInUse && !new.continuityCamera)

        // The screen shows one glanceable thing; the card's pills carry the detail.
        if let warning = new.warning {
            setScreen(big: warning, color: .orange, words: true)
        } else if mode == .charging, let percent = new.batteryPercent {
            setScreen(big: "\(percent)%", color: .white, bolt: new.charging)
        } else if mode == .heat, let t = new.temperature {
            setScreen(big: "\(Int(t.rounded()))°", color: t >= 85 ? .red : t >= 65 ? .orange : .white)
        } else {
            setClockScreen()   // like the Mac itself: the time
        }

        // Pills, in priority order: warning, camera, microphone, charging, clamshell.
        var list: [HeroPill] = []
        if let warning = new.warning { list.append(HeroPill(text: warning, color: .orange)) }
        if new.cameraInUse { list.append(HeroPill(text: new.continuityCamera ? "iPhone camera in use" : "Camera in use", color: .green)) }
        if new.micInUse { list.append(HeroPill(text: "Microphone in use", color: .orange)) }
        if new.charging, mode != .charging, let p = new.batteryPercent { list.append(HeroPill(text: "Charging · \(p)%", color: .green)) }
        if let buds = new.airPods { list.append(HeroPill(text: "AirPods · \(buds)", color: .white)) }
        if mode == .desk {
            let n = new.externalDisplays
            let names = Set(NSScreen.screens.filter { !$0.isBuiltIn }.map { DisplayNames.friendly($0.localizedName) })
            let name = names.count == 1 ? " · " + names.first! : ""
            list.append(HeroPill(text: n == 0 ? "Displays off" : "\(n) display\(n == 1 ? "" : "s")" + name, color: .white))
        }
        if lidShown < 15 {
            let displays = new.externalDisplays
            list.append(HeroPill(text: "Clamshell" + (displays > 0 ? " · \(displays) display\(displays == 1 ? "" : "s")" : ""), color: .white))
        }
        let top = Array(list.prefix(2))
        if top != pills { pills = top }
    }

    /// Neutral by default: one large item in white; colour only when it means something.
    /// A slim menu bar strip with an orange dot appears while the microphone is in use.
    private func setScreen(big: String, color: Color, bolt: Bool = false, words: Bool = false) {
        let mic = state.micInUse
        let key = "\(big)|\(color)|\(bolt)|\(words)|\(mic)"
        guard key != screenKey, screenMesh != nil else { return }
        screenKey = key
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                if bolt { Image(systemName: "bolt.fill").font(.system(size: 120)).foregroundStyle(Color.green) }
                Text(big)
                    .font(.system(size: words ? 150 : 260, weight: words ? .regular : .thin, design: .rounded))
                    .foregroundStyle(color.opacity(0.95))
                    .minimumScaleFactor(0.5).lineLimit(1)
            }
            .padding(.horizontal, 80)
            .frame(maxHeight: .infinity)
            if mic {
                HStack(spacing: 26) {
                    Spacer()
                    Circle().fill(Color.orange).frame(width: 22, height: 22)
                }
                .padding(.horizontal, 40).frame(height: 64)
                .background(Color.white.opacity(0.06))
            }
        }
        .frame(width: 1512, height: 982)
        guard let image = ImageRenderer(content: view).nsImage else { return }
        statusImage = image
        statusIsClock = false
        // During the opening the screen shows the wake sequence; the status takes over at the end.
        if intro != .full { applyScreen(image, intensity: 1) }
    }

    /// The lock-screen look: the date small on top, the time large below, on a dark gradient.
    /// Follows the system 12/24-hour setting; re-rendered only when the minute changes.
    private func setClockScreen() {
        let (time, date) = Self.clockText()
        let mic = state.micInUse
        let key = "clock|\(time)|\(date)|\(mic)"
        guard key != screenKey, screenMesh != nil else { return }
        screenKey = key
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.03, green: 0.03, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: -6) {
                Text(date).font(.system(size: 56, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text(time).font(.system(size: 300, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.92))
                    .tracking(-6)
            }
            .padding(.top, 120)
            if mic {
                HStack { Spacer(); Circle().fill(Color.orange).frame(width: 22, height: 22) }
                    .padding(.horizontal, 40).frame(height: 64)
                    .background(Color.white.opacity(0.06))
            }
        }
        .frame(width: 1512, height: 982)
        guard let image = ImageRenderer(content: view).nsImage else { return }
        statusImage = image
        statusIsClock = true
        if intro != .full { applyScreen(image, intensity: 1) }
    }

    private static func clockText() -> (String, String) {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let time = formatter.string(from: Demo.now)
            .replacingOccurrences(of: #"\s?[AaPp]\.?[Mm]\.?"#, with: "", options: .regularExpression)
        return (time, Demo.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }

    // MARK: Lid

    /// Polls the hinge sensor ten times a second, ignores wobbles under 2°, and eases the 3D lid
    /// to match. The camera only re-frames once the lid has settled, so the view doesn't breathe.
    private func updateLid(dt: Double) {
        lidPoll += 1
        if let lidOverride {
            lidTarget = lidOverride
        } else if lidPoll % 6 == 0 {
            if LidSensor.clamshellClosed() {
                lidTarget = 0
            } else if let live = lidSensor.angle() {
                if abs(live - lidTarget) >= 2 { lidTarget = live }
            } else {
                lidTarget = 110            // no sensor: keep the model's open pose
            }
        }
        let k = reduceMotion ? 1 : min(1, dt * 6)
        lidShown += (lidTarget - lidShown) * k
        if abs(lidTarget - lidShown) < 0.5 && abs(lidShown - lidFramed) > 2 {
            let crossedClamshell = (lidFramed < 15) != (lidShown < 15)
            lidFramed = lidShown
            if crossedClamshell {
                if lidShown < 15, mode == .rest, state.externalDisplays > 0 { deskAuto = true; setMode(.desk) }
                else if lidShown >= 15, deskAuto, mode == .desk { deskAuto = false; setMode(.rest) }
                update(state)   // refresh pills
            }
        }
        if intro != .full {
            hinge?.eulerAngles.x = CGFloat((110 - min(max(lidShown, 0), 135)) * .pi / 180)
        }
    }

    /// The Mac's outline with the lid at the settled angle (for framing).
    private func visibleOutline() -> [SIMD3<Float>] {
        guard !lidPoints.isEmpty, abs(lidFramed - 110) > 1 else { return outline }
        let theta = Float((110 - lidFramed) * .pi / 180)
        let pivot = SIMD3<Float>(0, -0.2, -11)
        let c = cos(theta), s = sin(theta)
        return basePoints + lidPoints.map { p in
            let y = p.y - pivot.y, z = p.z - pivot.z
            return SIMD3(p.x, pivot.y + y * c - z * s, pivot.z + y * s + z * c)
        }
    }

    // MARK: Animation

    private func tick() {
        let now = clockNow
        let dt = min(now.timeIntervalSince(last), 0.1)
        last = now
        clock += dt
        guard loaded else { return }
        updateLid(dt: dt)
        if lidPoll % 60 == 0 { update(state) }   // once a second: keeps the clock on the screen current
        cable.tick(dt: dt, reduceMotion: reduceMotion)
        cells.tick(dt: dt, visible: mode == .charging && state.batteryPercent != nil)
        plugs.tick(dt: dt, reduceMotion: reduceMotion)
        airPods.tick(dt: dt, reduceMotion: reduceMotion)
        phone?.tick(dt: dt, reduceMotion: reduceMotion)
        deskLevel += ((mode == .desk ? 1 : 0) - deskLevel) * (reduceMotion ? 1 : min(1, dt * 4))
        desk.tick(dt: dt, visible: deskLevel)
        floorNode?.isHidden = deskLevel > 0.02     // the desk surface catches shadows instead

        if intro == .full && introFrames < 3 {
            // Hold the first pose until frames arrive steadily, then start the clock, so a slow
            // first frame can't make the opening jump ahead.
            introFrames += 1
            introStart = now
        }
        let elapsed = now.timeIntervalSince(introStart)
        if intro == .full {
            playFullIntro(at: elapsed)
            if elapsed < 1.65 { return }            // the opening owns the camera until the turn ends
        } else if intro == .quick, elapsed > 0.35 {
            intro = .none
        }

        // Where the camera wants to be for this mode, framed around the Mac.
        var goal = basePose(for: mode)
        goal.angle += yaw
        if mode == .rest && move == nil && !reduceMotion {
            goal.angle += 5 * sin(clock * 0.35)                       // gentle drift
            leanSmoothed += (lean - leanSmoothed) * min(1, dt * 4)
            goal.angle += 5 * leanSmoothed.x                           // lean towards the pointer
            goal.height += 4 * leanSmoothed.y
        }
        frame(&goal)

        if let move {
            // Planned move: ease in and out, arcing out and up around the Mac.
            let raw = min(1, now.timeIntervalSince(move.start) / move.duration)
            let e = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
            let arc = sin(e * .pi)
            let lerp = { (a: Double, b: Double) in a + (b - a) * e }
            current.angle = lerp(move.from.angle, move.to.angle)
            if let via = move.via {
                // Quadratic curve from → via → to: out to the overview and back in.
                let a = (1 - e) * (1 - e), b = 2 * (1 - e) * e, c = e * e
                current.distance = a * move.from.distance + b * via.distance + c * move.to.distance
                current.height = a * move.from.height + b * via.height + c * move.to.height
                current.fov = a * move.from.fov + b * via.fov + c * move.to.fov
                current.target = move.from.target * a + via.target * b + move.to.target * c
            } else {
                current.distance = lerp(move.from.distance, move.to.distance) * (1 + move.pullBack * arc)
                current.height = lerp(move.from.height, move.to.height) + move.rise * arc
                current.fov = lerp(move.from.fov, move.to.fov)
                let centre = SIMD3<Double>(0, 3, -3)
                let straight = move.from.target + (move.to.target - move.from.target) * e
                current.target = straight + (centre - straight) * (0.4 * arc)
            }
            if raw >= 1 { current = move.to; self.move = nil }
        } else {
            // Follow the goal smoothly (drift, dragging, re-framing); snappier for the quick open,
            // instant with Reduce Motion.
            let k = reduceMotion ? 1 : 1 - exp(-dt * (intro == .quick ? 14 : 5))
            current.angle += (goal.angle - current.angle) * k
            current.height += (goal.height - current.height) * k
            current.distance += (goal.distance - current.distance) * k
            current.fov += (goal.fov - current.fov) * k
            current.target += (goal.target - current.target) * k
        }
        apply(current)
        // The rim light behind the Mac reflects straight at a head-on camera and turns Space Black
        // silver; fade it as the camera comes round to face the Mac.
        if intro != .full {
            let side = abs(sin(current.angle * .pi / 180))
            setLights(1, rim: min(1, max(0.08, side * 1.7)))
        }

        // Glows.
        let heatGoal = mode == .heat ? 0.15 + 0.85 * min(1, max(0, (temperature - 35) / 55)) : 0
        heatLevel += (heatGoal - heatLevel) * min(1, dt * 4)
        heatGlow.opacity = CGFloat(heatLevel)
        let warm = mode == .heat ? min(1, max(0, (temperature - 45) / 45)) : 0
        rimLight?.color = NSColor(calibratedRed: 1, green: CGFloat(1 - 0.5 * warm), blue: CGFloat(1 - 0.75 * warm), alpha: 1)
        // The MagSafe cable's own light now shows charging; the old port glow stays off.
        chargeGlow.opacity = 0

        // Ports view: publish where each port lands once the camera has arrived.
        let arrived = move == nil && abs(goal.angle - current.angle) < 1.5 && abs(goal.distance - current.distance) / goal.distance < 0.03
        if arrived != settled { settled = arrived }
        if case .ports(let side) = mode, arrived {
            var anchors: [String: CGPoint] = [:]
            for port in Ports.layoutPoints(side: side) {
                anchors[port.id] = project(port.point)
            }
            if anchors != portAnchors { portAnchors = anchors }
        }
    }

    /// The first-open-of-the-day sequence (about 2 s, camera done by 1.65 s):
    /// lights up face-on, lid rises, keyboard backlight, screen wakes to the clock (or the
    /// charging ring), hands over to the status, then one smooth turn out to three-quarters
    /// while a glint runs along the edge and the panel cascades in.
    private func playFullIntro(at t: Double) {
        func phase(_ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
        func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
        func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
        func mix(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }

        let turn = easeInOut(phase(1.0, 1.65))
        // The rim light behind the Mac would bounce off the deck at a face-on camera and turn
        // Space Black silver, so it stays low until the Mac turns.
        setLights(0.04 + 0.96 * easeOut(phase(0, 0.3)), rim: mix(0.06, 1, turn), overhead: mix(0.45, 1, turn))
        hinge?.eulerAngles.x = CGFloat(1.92 * (1 - easeOut(phase(0.15, 0.85))))
        setBacklight(t < 1.3 ? easeOut(phase(0.42, 0.58)) : 1 - easeOut(phase(1.3, 2.2)))

        // Screen: backlight glow, then the clock, then the status. Warnings skip the clock.
        if warning {
            if t < 0.72 { applyScreen(blankImage, intensity: easeOut(phase(0.6, 0.75))) }
            else { applyScreen(statusImage, intensity: mix(0.25, 1, easeOut(phase(0.72, 0.95)))) }
        } else if t < 0.72 {
            applyScreen(blankImage, intensity: easeOut(phase(0.6, 0.75)))
        } else if statusIsClock && !chargingNow {
            applyScreen(statusImage, intensity: mix(0.25, 1, easeOut(phase(0.72, 0.95))))
        } else if t < 1.15 {
            applyScreen(wakeImage, intensity: mix(0.25, 1, easeOut(phase(0.72, 0.95))))
        } else if t < 1.3 {
            applyScreen(wakeImage, intensity: 1 - 0.85 * phase(1.15, 1.3))
        } else {
            applyScreen(statusImage, intensity: mix(0.15, 1, easeOut(phase(1.3, 1.5))))
        }

        // Glint sweeping along the front edge during the turn.
        let sweep = phase(1.0, 1.65)
        glintLight.intensity = CGFloat(2600 * sin(.pi * sweep))
        glintNode.position = SCNVector3(-30 + 60 * sweep, 14, 40)
        glintNode.look(at: SCNVector3(-12 + 24 * sweep, 0, 10))

        if t >= 1.7 && !revealed { revealed = true }   // once the Mac has opened and settled, the panel drops in
        if t >= 2.2 {
            intro = .none
            setLights(1)
            setBacklight(0)
            glintLight.intensity = 0
            applyScreen(statusImage, intensity: 1)
        }

        // Camera: face-on, lifting with the lid, then out to the framed resting view.
        guard t < 1.65 else { return }
        let lift = easeOut(phase(0.15, 0.85))
        var face = Pose(angle: 0, height: mix(12, 20, lift), distance: 84, fov: 24, target: [0, 5, -2])
        frame(&face, points: outline, region: CGRect(x: 15, y: 12, width: size.width - 30, height: size.height - 22), fill: 0.97)
        var rest = basePose(for: .rest)
        frame(&rest)
        current = Pose(angle: mix(face.angle, rest.angle, turn), height: mix(face.height, rest.height, turn),
                       distance: mix(face.distance, rest.distance, turn), fov: mix(face.fov, rest.fov, turn),
                       target: face.target + (rest.target - face.target) * turn)
        apply(current)
    }

    // MARK: Wake screens

    /// Like the lock screen: the date small on top, a large rounded time, on a dark gradient.
    /// Follows the system 12/24-hour setting.
    private static func clockImage() -> NSImage? {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let time = formatter.string(from: Demo.now)
            .replacingOccurrences(of: #"\s?[AaPp]\.?[Mm]\.?"#, with: "", options: .regularExpression)
        let date = Demo.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let view = ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.03, green: 0.03, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: -6) {
                Text(date).font(.system(size: 56, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text(time).font(.system(size: 300, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.92))
                    .tracking(-6)
            }
            .offset(y: -150)
        }
        .frame(width: 1512, height: 982)
        return ImageRenderer(content: view).nsImage
    }

    /// While charging: a green ring filled to the battery level, like the iPhone's.
    private static func chargingImage(_ percent: Int) -> NSImage? {
        let view = ZStack {
            Color.black
            Circle().stroke(Color.green.opacity(0.18), lineWidth: 34).frame(width: 520, height: 520)
            Circle().trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 34, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 520, height: 520)
                .shadow(color: .green.opacity(0.6), radius: 30)
            VStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 60)).foregroundStyle(.green)
                Text("\(percent)%").font(.system(size: 150, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: 1512, height: 982)
        return ImageRenderer(content: view).nsImage
    }

    private static func solidImage(white: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 42))
        image.lockFocus()
        NSColor(white: white, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 64, height: 42).fill()
        image.unlockFocus()
        return image
    }

    private func basePose(for mode: Mode) -> Pose {
        switch mode {
        case .rest where lidFramed < 15: Pose(angle: -30, height: 50, distance: 84, fov: 24, target: [0, 1, 0])   // clamshell
        case .rest: Pose(angle: -34, height: 30, distance: 84, fov: 24, target: [0, 5, -2])
        case .heat: Pose(angle: -18, height: 44, distance: 62, fov: 24, target: [0, 3, -3])
        case .charging: Pose(angle: -62, height: 14, distance: 70, fov: 24, target: [-4, 3, -3])   // front-left: screen, port, cable
        case .ports(.left): Pose(angle: -90, height: 3.2, distance: 30, fov: 20, target: [-15.6, 0.4, -6])
        case .ports(.right): Pose(angle: 90, height: 3.2, distance: 30, fov: 20, target: [15.6, 0.4, -6])
        case .desk: Pose(angle: -22, height: 42, distance: 160, fov: 24, target: [0, 12, -8])   // three-quarter, slightly above
        }
    }

    /// Centres the relevant part of the Mac in the space this mode leaves for it.
    private func frame(_ pose: inout Pose) {
        let (points, region, widthOnly) = framing(for: mode)
        frame(&pose, points: points, region: region, fill: widthOnly ? 1 : 0.97, widthOnly: widthOnly)
    }

    private func framing(for mode: Mode) -> ([SIMD3<Float>], CGRect, Bool) {
        let w = size.width, h = size.height
        switch mode {
        case .rest:
            // The AirPods case joins the frame when it's on the desk.
            // Below the name, above the strip kept clear for the pills and the desk button.
            return (visibleOutline() + airPods.framingPoints, CGRect(x: 16, y: 42, width: w - 32, height: h - 42 - 40), false)
        case .heat, .charging:
            return (visibleOutline(), CGRect(x: 16, y: 12, width: w - 32, height: h - 12 - 40), false)
        case .desk:
            // Generous margins, and the bottom 40 pt kept clear for the pills and the desk button.
            return (visibleOutline() + desk.framingPoints, CGRect(x: 26, y: 20, width: w - 52, height: h - 20 - 44), false)
        case .ports(let side):
            let s: Float = side == .left ? -1 : 1
            let edge = outline.filter { $0.x * s > 13.5 && $0.z > -10.4 && $0.z < -1.6 && $0.y < 2.2 }
            return (edge, CGRect(x: 24, y: 32, width: w - 48, height: 46), true)          // labels go underneath
        }
    }

    /// Moves `pose` so `points` sit centred in `region`, filling it by `fill`
    /// (by width only for the ports close-up).
    private func frame(_ pose: inout Pose, points: [SIMD3<Float>], region: CGRect, fill: Double, widthOnly: Bool = false) {
        guard !points.isEmpty else { return }
        for _ in 0..<3 {
            apply(pose)
            let p = projectAll(points)
            let minX = p.map(\.x).min()!, maxX = p.map(\.x).max()!
            let minY = p.map(\.y).min()!, maxY = p.map(\.y).max()!
            let ratio = widthOnly ? (maxX - minX) / region.width
                                  : max((maxX - minX) / region.width, (maxY - minY) / region.height)
            pose.distance *= Double(ratio) / fill
            apply(pose)
            let q = projectAll(points)
            let cx = (q.map(\.x).min()! + q.map(\.x).max()!) / 2
            let cy = (q.map(\.y).min()! + q.map(\.y).max()!) / 2
            let perPixel = 2 * pose.distance * tan(pose.fov / 2 * .pi / 180) / Double(size.height)
            let right = cameraNode.worldRight, up = cameraNode.worldUp
            let dx = Double(cx - region.midX) * perPixel, dy = Double(cy - region.midY) * perPixel
            pose.target += SIMD3(Double(right.x) * dx - Double(up.x) * dy,
                                 Double(right.y) * dx - Double(up.y) * dy,
                                 Double(right.z) * dx - Double(up.z) * dy)
        }
    }

    private func apply(_ pose: Pose) {
        let a = pose.angle * .pi / 180
        let t = pose.target
        cameraNode.position = SCNVector3(t.x + sin(a) * pose.distance, t.y + pose.height, t.z + cos(a) * pose.distance)
        cameraNode.look(at: SCNVector3(t.x, t.y, t.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        camera.fieldOfView = pose.fov
    }

    /// Projects many points at once with one camera matrix (cheap enough to run every frame).
    private func projectAll(_ points: [SIMD3<Float>]) -> [CGPoint] {
        let view = cameraNode.simdWorldTransform.inverse
        let f = Float(1 / tan(Double(camera.fieldOfView) / 2 * .pi / 180))
        let aspect = Float(size.width / size.height)
        let w = Float(size.width), h = Float(size.height)
        return points.map { p in
            let v = view * SIMD4(p, 1)
            let depth = max(-v.z, 0.001)
            let x = v.x / depth * f / aspect, y = v.y / depth * f
            return CGPoint(x: CGFloat((x + 1) / 2 * w), y: CGFloat((1 - y) / 2 * h))
        }
    }

    /// Where a model point lands in the view (points, top-left origin).
    func project(_ p: SCNVector3) -> CGPoint {
        let v = cameraNode.convertPosition(p, from: nil)
        let depth = max(-Double(v.z), 0.001)
        let f = 1 / tan(Double(camera.fieldOfView) / 2 * .pi / 180)
        let aspect = Double(size.width / size.height)
        let x = Double(v.x) / depth * f / aspect, y = Double(v.y) / depth * f
        return CGPoint(x: (x + 1) / 2 * size.width, y: (1 - y) / 2 * size.height)
    }

    private static func spring(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return 1 - pow(1 - x, 3) * cos(x * 2.2) + 0.04 * sin(x * .pi) * (1 - x)
    }

    // MARK: Still rendering (snapshot mode)

    /// Renders the current state without a window, for `--snapshot`.
    func still(scale: CGFloat = 2) -> NSImage? {
        guard loaded else { return nil }
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        return renderer.snapshot(atTime: 0, with: CGSize(width: size.width * scale, height: size.height * scale),
                                 antialiasingMode: .multisampling4X)
    }

    /// Jumps straight to the settled pose (no intro), for stills.
    func settleForStill() {
        if intro != .none { finishIntro() }
        revealed = true
        cable.settle()
        plugs.settle()
        airPods.settle()
        phone?.settle()
        introStart = .distantPast
        if let move { current = move.to; self.move = nil }
        for _ in 0..<240 { last = Date().addingTimeInterval(-1.0 / 30); tick() }
    }

    /// Times the work done on the main thread during the opening (snapshot `--profile` only).
    func profileIntro() -> String {
        func ms(_ f: () -> Void) -> Double { let t = DispatchTime.now().uptimeNanoseconds; f(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
        var out: [String] = []
        wokeSinceLastFull = true
        out.append(String(format: "beginIntro  %.2f ms", ms { beginIntro() }))
        var ticks: [Double] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 2.3 {
            last = Date().addingTimeInterval(-1.0 / 60)
            ticks.append(ms { tick() })
        }
        ticks.sort()
        out.append(String(format: "tick (intro) median %.2f ms · p95 %.2f ms · max %.2f ms · %d ticks", ticks[ticks.count / 2], ticks[ticks.count * 95 / 100], ticks.last!, ticks.count))
        var rest: [Double] = []
        for _ in 0..<120 { last = Date().addingTimeInterval(-1.0 / 60); rest.append(ms { tick() }) }
        rest.sort()
        out.append(String(format: "tick (rest)  median %.2f ms · max %.2f ms", rest[rest.count / 2], rest.last!))
        out.append(String(format: "lid sensor read  %.2f ms", ms { _ = lidSensor.angle() }))
        out.append(String(format: "clamshell check  %.2f ms", ms { _ = LidSensor.clamshellClosed() }))
        var p = basePose(for: .rest)
        out.append(String(format: "frame()  %.2f ms", ms { frame(&p) }))
        out.append(String(format: "clock screen render  %.2f ms", ms { screenKey = ""; setClockScreen() }))
        return out.joined(separator: "\n")
    }

    /// Records the full opening as frames (snapshot mode only).
    func recordIntro() async -> [NSImage] {
        wokeSinceLastFull = true
        beginIntro()
        var frames: [NSImage] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 2.3 {
            tick()
            if let image = still(scale: 1) { frames.append(image) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return frames
    }

    /// One recorded frame for the demo video: the render plus what the card overlays on it.
    struct ClipFrame {
        var time: Double
        var image: NSImage
        var pills: [HeroPill]
        var anchors: [String: CGPoint]
    }

    /// Records `seconds` of animation for the demo video at exactly 30 fps on a virtual clock,
    /// calling `change` with the elapsed time before each frame. With `intro`, the full opening
    /// plays first. `speed` below 1 plays the scene in slow motion (snapshot mode only).
    func recordClip(seconds: Double, scale: CGFloat = 4, intro: Bool = false, speed: Double = 1,
                    change: (Double) -> Void = { _ in }) async -> [ClipFrame] {
        let start = Date()
        virtualNow = start
        last = start
        defer { virtualNow = nil }
        if intro { wokeSinceLastFull = true; beginIntro() }
        // One renderer for the whole clip; making one per frame halves the frame rate.
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        var frames: [ClipFrame] = []
        for index in 0...Int(seconds * 30) {
            let t = Double(index) / 30
            virtualNow = start.addingTimeInterval(t * speed)
            change(t)
            tick()
            let image = renderer.snapshot(atTime: t, with: pixels, antialiasingMode: .multisampling4X)
            frames.append(ClipFrame(time: t, image: image, pills: pills, anchors: portAnchors))
            await Task.yield()
        }
        return frames
    }

    /// Records a Left → Right ports move as frames (snapshot mode only).
    func recordSideSwitch() async -> [NSImage] {
        setMode(.ports(.left))
        settleForStill()
        var frames: [NSImage] = []
        setMode(.ports(.right))
        let start = Date()
        while Date().timeIntervalSince(start) < 1.6 {
            tick()
            if let image = still(scale: 1) { frames.append(image) }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return frames
    }

    /// Snapshot testing: pose the lid at a fixed angle (nil = follow the sensor again).
    func simulateLid(_ degrees: Double?) {
        lidOverride = degrees
        if let degrees { lidTarget = degrees; lidShown = degrees; lidFramed = degrees }
        update(state)
    }

    /// Waits for the background model load (snapshot mode only).
    func waitUntilLoaded() async {
        loadIfNeeded()
        for _ in 0..<100 where !loaded { try? await Task.sleep(for: .milliseconds(100)) }
    }
}

extension Ports {
    /// Port positions on the 3D model's side edge.
    static func layoutPoints(side: Side) -> [(id: String, point: SCNVector3)] {
        let x: CGFloat = side == .left ? -15.6 : 15.6
        return layout.filter { $0.side == side }.map { slot in
            let y: CGFloat = slot.id == "headphones" ? -0.1 : slot.id.hasPrefix("Port-SD") ? -0.35 : -0.3
            return (slot.id, SCNVector3(x, y, CGFloat(slot.z)))
        }
    }
}
