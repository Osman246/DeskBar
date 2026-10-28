import AVFoundation
import SwiftUI

/// `DESKBAR_DEMO=1 DeskBar --snapshot <dir> --demo-video` renders a 42-second launch video
/// (1080 × 1350, 30 fps) from the real 3D Mac, recorded live, and the panel screenshot in
/// docs/images. Everything else (captions, menu bar, cursor) is drawn here.
@MainActor
enum DemoVideo {
    enum Part: CaseIterable { case hook, menuBar, open, panel, lid, plug, ports, desk, heat, actions, end }

    static let size = CGSize(width: 1080, height: 1350)
    static let fps = 30.0
    static let lengths: [Part: Double] = [.hook: 3.0, .menuBar: 1.8, .open: 3.8, .panel: 5.0, .lid: 3.8, .plug: 4.0,
                                          .ports: 5.4, .desk: 3.6, .heat: 3.4, .actions: 3.4, .end: 4.6]
    static var total: Double { lengths.values.reduce(0, +) }

    /// Where `t` falls: the part and the time into it.
    static func part(at t: Double) -> (Part, Double) {
        var start = 0.0
        for part in Part.allCases {
            let length = lengths[part]!
            if t < start + length { return (part, t - start) }
            start += length
        }
        return (.end, lengths[.end]!)
    }

    static func make(model: AppModel, to directory: String) async {
        let mac = model.mac
        await mac.waitUntilLoaded()
        let clips = await record(mac)
        let panel = NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/docs/images/panel-dark.png")

        let url = URL(fileURLWithPath: directory).appendingPathComponent("deskbar-demo.mp4")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = Int(total * fps)
        let stills = Set(stride(from: 0.6, to: total, by: 1.5).map { Int($0 * fps) })
        for index in 0..<frames {
            let t = Double(index) / fps
            let view = DemoFrame(t: t, clips: clips, panel: panel)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }
            if stills.contains(index) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(String(format: "frame-%05.1f.png", t)))
            }
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(image, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
            if index % 150 == 0 { print("frame \(index)/\(frames)") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        print(writer.status == .completed ? "Wrote \(url.path)" : "Video failed: \(writer.error?.localizedDescription ?? "?")")
    }

    // MARK: Recording the 3D Mac

    /// The ports as the video shows them; anything not listed is empty.
    static func ports(_ connected: [String: String]) -> [Ports.Port] {
        Ports.layout.map {
            Ports.Port(id: $0.id, name: $0.name, side: $0.side, z: $0.z,
                       connected: connected[$0.id] != nil, detail: connected[$0.id] ?? "Empty")
        }
    }

    private static func record(_ mac: MacScene) async -> [Part: [MacScene.ClipFrame]] {
        var clips: [Part: [MacScene.ClipFrame]] = [:]
        let base = MacState(temperature: 41, batteryPercent: 84, ports: ports([:]))
        var charging = base
        charging.charging = true
        charging.onPower = true
        charging.magSafeConnected = true
        charging.ports = ports(["Port-MagSafe 3@1": "Charging · 70 W"])
        var desk = charging
        desk.ports = ports(["Port-MagSafe 3@1": "Charging · 70 W", "Port-USB-C@2": "Display · 4K",
                            "Port-USB-C@1": "Display · 4K", "Port-USB-C@4": "SSD · 1 TB", "Port-SD Card@1": "SD card · 128 GB"])
        desk.externalDisplays = 2
        desk.leftMonitor = true
        desk.rightMonitor = true
        var hot = charging
        hot.temperature = 95
        hot.warning = "Running hot"

        func reset(_ state: MacState) {
            mac.simulateLid(112)
            mac.update(state)
            mac.setMode(.rest)
            mac.settleForStill()
        }

        reset(base)
        clips[.open] = await mac.recordClip(seconds: 3.8, intro: true)

        reset(base)
        clips[.lid] = await mac.recordClip(seconds: 3.8) { t in
            let angle = t < 0.5 ? 112 : t < 1.7 ? 112 - 77 * ease((t - 0.5) / 1.2) : t < 2.2 ? 35 : 35 + 77 * ease((t - 2.2) / 1.2)
            mac.simulateLid(angle)
        }

        reset(base)
        var plugged = false, cells = false
        clips[.plug] = await mac.recordClip(seconds: 4.0) { t in
            if t > 0.5 && !plugged { plugged = true; mac.update(charging) }
            if t > 2.0 && !cells { cells = true; mac.setMode(.charging) }
        }

        reset(desk)
        var leftSide = false, rightSide = false
        clips[.ports] = await mac.recordClip(seconds: 5.4) { t in
            if !leftSide { leftSide = true; mac.setMode(.ports(.left)) }
            if t > 2.4 && !rightSide { rightSide = true; mac.setMode(.ports(.right)) }
        }

        reset(desk)
        var atDesk = false
        clips[.desk] = await mac.recordClip(seconds: 3.6) { t in
            if t > 0.3 && !atDesk { atDesk = true; mac.setMode(.desk) }
        }

        reset(hot)
        var heated = false
        clips[.heat] = await mac.recordClip(seconds: 3.4) { _ in
            if !heated { heated = true; mac.setMode(.heat) }
        }
        reset(base)
        return clips
    }
}

// MARK: - Easing

private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
private func ease(_ x: Double) -> Double {
    let x = clamp(x)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
/// Overshoots a little and settles, like a spring.
private func springy(_ x: Double) -> Double {
    let x = clamp(x), c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
}

// MARK: - One frame

private struct DemoFrame: View {
    let t: Double
    let clips: [DemoVideo.Part: [MacScene.ClipFrame]]
    let panel: NSImage?

    private var current: (DemoVideo.Part, Double) { DemoVideo.part(at: t) }
    private var part: DemoVideo.Part { current.0 }
    private var local: Double { current.1 }
    private var length: Double { DemoVideo.lengths[part]! }

    static let card = CGRect(x: 60, y: 450, width: 960, height: 630)
    static let accent = LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.66, green: 0.45, blue: 1)],
                                       startPoint: .leading, endPoint: .trailing)

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            switch part {
            case .hook: hook
            case .panel: panelTour
            case .actions: actions
            case .end: endCard
            default: EmptyView()
            }
            if [.open, .lid, .plug, .ports, .desk, .heat].contains(part) { card }
            if part != .hook && part != .end { caption }
            if part == .heat { notification }
            if [.lid, .plug, .ports, .desk, .heat, .actions].contains(part) { chapters }
            menuBar
            cursor
            progress
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
        .clipped()
    }

    // MARK: Backdrop

    private var background: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.065)
            RadialGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.95).opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 520)
                .frame(width: 1100, height: 1100)
                .offset(x: -260 + 120 * sin(t * 0.35), y: -380 + 90 * cos(t * 0.3))
            RadialGradient(colors: [Color(red: 0.62, green: 0.3, blue: 0.95).opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 480)
                .frame(width: 1000, height: 1000)
                .offset(x: 300 - 100 * cos(t * 0.28), y: 420 + 110 * sin(t * 0.33))
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }

    private var progress: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.08))
            Rectangle().fill(Self.accent).frame(width: DemoVideo.size.width * t / DemoVideo.total)
        }
        .frame(width: DemoVideo.size.width, height: 6)
        .offset(y: DemoVideo.size.height - 6)
    }

    // MARK: Captions

    private var captionText: (String, String) {
        switch part {
        case .menuBar: ("Meet DeskBar.", "It lives in your menu bar.")
        case .open: ("One click. One answer.", "All good, or the one thing that isn't.")
        case .panel: ("Everything at a glance.", "Detail only when you ask.")
        case .lid: ("It mirrors your real Mac.", "Move the lid, and so does it.")
        case .plug: ("Plug in. It knows.", "MagSafe, charge level, charger speed.")
        case .ports: ("Every port, labelled.", "What's plugged in, and where.")
        case .desk: ("Your whole desk.", "Monitors appear as you connect them.")
        case .heat: ("Warns you early.", "Heat, memory, disk and battery.")
        case .actions: ("Quick actions, one tap.", "Focus, keep awake, lock and more.")
        default: ("", "")
        }
    }

    private var caption: some View {
        let (title, subtitle) = captionText
        let fadeOut = 1 - clamp((local - (length - 0.25)) / 0.25)
        let inTitle = easeOut((local - 0.05) / 0.5), inSubtitle = easeOut((local - 0.25) / 0.5)
        return VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 74, weight: .bold))
                .tracking(-1.5)
                .foregroundStyle(.white)
                .opacity(inTitle)
                .offset(y: 28 * (1 - inTitle))
            Text(subtitle)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(Color(white: 0.66))
                .opacity(inSubtitle)
                .offset(y: 22 * (1 - inSubtitle))
        }
        .opacity(fadeOut)
        .padding(.leading, 60)
        .padding(.top, 140)
    }

    // MARK: Hook

    private var hook: some View {
        let words = ["Is", "your", "Mac", "OK?"]
        let leave = ease((local - 2.45) / 0.5)
        let places: [(String, String, CGPoint)] = [("Activity Monitor", "waveform.path.ecg", CGPoint(x: 110, y: 830)),
                                                   ("System Settings", "gearshape", CGPoint(x: 560, y: 900)),
                                                   ("Control Centre", "switch.2", CGPoint(x: 170, y: 1010)),
                                                   ("Battery menu", "battery.75percent", CGPoint(x: 600, y: 1080))]
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 24) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                    let p = springy((local - 0.12 - Double(i) * 0.16) / 0.45)
                    Text(word)
                        .font(.system(size: 112, weight: .heavy))
                        .tracking(-3)
                        .foregroundStyle(i == 3 ? AnyShapeStyle(Self.accent) : AnyShapeStyle(Color.white))
                        .scaleEffect(0.6 + 0.4 * p)
                        .opacity(clamp(p * 1.4))
                }
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 470)
            Text("Today you'd check four places.")
                .font(.system(size: 40))
                .foregroundStyle(Color(white: 0.66))
                .frame(width: DemoVideo.size.width)
                .offset(y: 640)
                .opacity(easeOut((local - 0.9) / 0.4))
            ForEach(Array(places.enumerated()), id: \.offset) { i, place in
                let p = springy((local - 1.2 - Double(i) * 0.14) / 0.4)
                HStack(spacing: 12) {
                    Image(systemName: place.1).font(.system(size: 30, weight: .medium))
                    Text(place.0).font(.system(size: 32, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26).padding(.vertical, 16)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                .rotationEffect(.degrees(Double(i % 2 == 0 ? -3 : 3)))
                .scaleEffect(0.5 + 0.5 * p)
                .opacity(clamp(p * 1.5))
                .offset(x: place.2.x, y: place.2.y)
            }
        }
        .opacity(1 - leave)
        .scaleEffect(1 - 0.08 * leave)
    }

    // MARK: Menu bar and cursor

    private var menuBarShown: Double {
        switch part {
        case .hook: 0
        case .menuBar: easeOut(local / 0.4)
        case .end: 1 - ease(local / 0.4)
        default: 1
        }
    }

    /// The DeskBar item, in canvas points.
    static let itemCentre = CGPoint(x: 631, y: 22)

    private var panelOpen: Bool {
        switch part {
        case .hook, .end: false
        case .menuBar: local > 1.15
        default: true
        }
    }

    private var menuBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "apple.logo").font(.system(size: 24)).frame(width: 46)
            ForEach(["Finder", "File", "Edit", "View", "Go"], id: \.self) { item in
                Text(item).font(.system(size: 21, weight: item == "Finder" ? .bold : .regular)).padding(.horizontal, 11)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                Text("39°").monospacedDigit()
            }
            .font(.system(size: 21, weight: .medium))
            .frame(width: 110, height: 34)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(panelOpen ? 0.22 : 0)))
            Image(systemName: "wifi").font(.system(size: 20)).frame(width: 56)
            Image(systemName: "battery.75percent").font(.system(size: 22)).frame(width: 64)
            Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))   // matches the 3D Mac's screen
                .font(.system(size: 21)).frame(width: 250, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .frame(width: DemoVideo.size.width, height: 44)
        .background(Color(white: 0.12).opacity(0.92))
        .offset(y: -44 * (1 - menuBarShown))
        .opacity(menuBarShown)
    }

    private var cursorPoint: CGPoint? {
        let start = CGPoint(x: 540, y: 820), end = Self.itemCentre
        switch part {
        case .menuBar:
            let p = ease((local - 0.25) / 0.8)
            return CGPoint(x: start.x + (end.x - start.x) * p + 10, y: start.y + (end.y - start.y) * p + 6)
        case .open where local < 0.8:
            return CGPoint(x: end.x + 10, y: end.y + 6)
        default: return nil
        }
    }

    @ViewBuilder private var cursor: some View {
        if let point = cursorPoint {
            let click = part == .menuBar ? clamp((local - 1.1) / 0.45) : 1
            ZStack(alignment: .topLeading) {
                if click > 0 && click < 1 {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.7 * (1 - click)), lineWidth: 4)
                        .frame(width: 30 + 90 * click, height: 30 + 90 * click)
                        .offset(x: Self.itemCentre.x - (15 + 45 * click), y: Self.itemCentre.y - (15 + 45 * click))
                }
                Arrow()
                    .fill(Color.black)
                    .overlay(Arrow().stroke(Color.white, lineWidth: 2.5))
                    .frame(width: 30, height: 44)
                    .scaleEffect(click > 0 && click < 0.25 ? 0.85 : 1, anchor: .topLeading)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .offset(x: point.x, y: point.y)
                    .opacity(part == .open ? 1 - clamp((local - 0.5) / 0.3) : 1)
            }
        }
    }

    // MARK: The card

    private var clip: [MacScene.ClipFrame] { clips[part] ?? [] }

    private func frame(in clip: [MacScene.ClipFrame], at time: Double) -> MacScene.ClipFrame? {
        clip.last { $0.time <= time } ?? clip.first
    }

    private var previousClipFrame: MacScene.ClipFrame? {
        let order = DemoVideo.Part.allCases
        guard let i = order.firstIndex(of: part), i > 0 else { return nil }
        return clips[order[i - 1]]?.last
    }

    private var card: some View {
        let rect = Self.card
        let entrance = part == .open ? springy(local / 0.55) : 1
        let now = frame(in: clip, at: local)
        let blend = clamp(local / 0.2)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 42, style: .continuous).fill(Color(white: 0.13))
            if let previous = previousClipFrame, part != .open, blend < 1 {
                Image(nsImage: previous.image).resizable().opacity(1 - blend)
            }
            if let now { Image(nsImage: now.image).resizable().opacity(part == .open ? 1 : blend) }
            if part == .ports, let now { portLabels(now) }
            cardTitle
            if let now, part != .ports { pills(now.pills) }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 42, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 2))
        .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
        .scaleEffect(0.94 + 0.06 * entrance)
        .opacity(clamp(entrance * 1.6))
        .offset(x: rect.minX, y: rect.minY - 50 * (1 - entrance))
    }

    @ViewBuilder private var cardTitle: some View {
        let hot = part == .heat
        let shown = part == .open ? easeOut((local - 2.3) / 0.5) : 1
        if part != .ports && part != .desk {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacBook Pro").font(.system(size: 39, weight: .semibold)).foregroundStyle(.white)
                    Text(MacInfo.subtitle).font(.system(size: 30)).foregroundStyle(Color(white: 0.6))
                }
                Spacer()
                if !hot {   // the alert banner sits here; the pill below says it instead
                    HStack(spacing: 12) {
                        Circle().fill(Color.green).frame(width: 16, height: 16)
                        Text("All good").font(.system(size: 32, weight: .medium)).foregroundStyle(Color(white: 0.75))
                    }
                }
            }
            .padding(36)
            .opacity(shown)
        } else if part == .ports {
            let side = local < 2.4 ? "Left side" : "Right side"
            Text(side).font(.system(size: 33, weight: .medium)).foregroundStyle(Color(white: 0.7)).padding(32)
        }
    }

    private func pills(_ pills: [HeroPill]) -> some View {
        HStack(spacing: 16) {
            ForEach(pills) { pill in
                HStack(spacing: 12) {
                    Circle().fill(pill.color).frame(width: 16, height: 16)
                    Text(pill.text).font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .padding(30)
        .frame(width: Self.card.width, height: Self.card.height, alignment: .bottomLeading)
    }

    /// Rings on the ports and labels below, arriving one after another once the camera settles.
    private func portLabels(_ now: MacScene.ClipFrame) -> some View {
        let side: Ports.Side = local < 2.4 ? .left : .right
        let ports = DemoVideo.ports(["Port-MagSafe 3@1": "Charging · 70 W", "Port-USB-C@2": "Display · 4K",
                                     "Port-USB-C@1": "Display · 4K", "Port-USB-C@4": "SSD · 1 TB", "Port-SD Card@1": "SD card · 128 GB"])
            .filter { $0.side == side && now.anchors[$0.id] != nil }
        // How long the anchors have been showing.
        let since = clip.reversed().drop { $0.time > local }.prefix { !$0.anchors.isEmpty }.last.map { local - $0.time } ?? 0
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.clear, Color(white: 0.08).opacity(0.9)], startPoint: UnitPoint(x: 0.5, y: 0.4), endPoint: UnitPoint(x: 0.5, y: 0.62))
            ForEach(Array(ports.sorted { $0.z < $1.z }.enumerated()), id: \.element.id) { i, port in
                let anchor = now.anchors[port.id]!
                let x = anchor.x * 3, y = anchor.y * 3
                let p = easeOut((since - Double(i) * 0.12) / 0.35)
                let row = CGFloat(i % 2)
                let labelY = 470 + row * 72
                ZStack(alignment: .topLeading) {
                    Circle().strokeBorder(port.connected ? Color(red: 0.4, green: 0.85, blue: 0.5) : Color.white.opacity(0.6), lineWidth: 4)
                        .frame(width: 28, height: 28).offset(x: x - 14, y: y - 14)
                    Rectangle().fill(Color.white.opacity(0.35)).frame(width: 2, height: max(0, (labelY - y - 16) * p))
                        .offset(x: x - 1, y: y + 14)
                    VStack(alignment: .center, spacing: 2) {
                        Text(port.name).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                        Text(port.detail).font(.system(size: 22)).foregroundStyle(port.connected ? Color(red: 0.55, green: 0.9, blue: 0.62) : Color(white: 0.55))
                    }
                    .fixedSize()
                    .frame(width: 260)
                    .offset(x: x - 130, y: labelY + 14 * (1 - p))
                    .opacity(p)
                }
            }
        }
    }

    // MARK: Chapters

    /// What the video has shown and what's coming, under the card.
    private var chapters: some View {
        let steps: [(DemoVideo.Part, String, String)] = [(.lid, "Lid", "macbook"), (.plug, "Power", "bolt.fill"),
                                                          (.ports, "Ports", "cable.connector"), (.desk, "Desk", "display.2"),
                                                          (.heat, "Alerts", "bell.badge.fill"), (.actions, "Actions", "square.grid.2x2.fill")]
        let currentIndex = steps.firstIndex { $0.0 == part } ?? 0
        let appear = part == .lid ? easeOut(local / 0.5) : 1
        let fade = part == .actions ? 1 - clamp((local - (length - 0.25)) / 0.25) : 1
        return HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                chapterStep(title: step.1, symbol: step.2, state: i == currentIndex ? 0 : i < currentIndex ? -1 : 1)
            }
        }
        .frame(width: DemoVideo.size.width)
        .offset(y: 1150 + 30 * (1 - appear))
        .opacity(appear * fade)
    }

    /// One step: `state` is -1 done, 0 now, 1 still to come.
    private func chapterStep(title: String, symbol: String, state: Int) -> some View {
        let active = state == 0
        let iconOpacity: Double = active ? 1 : state < 0 ? 0.7 : 0.3
        let fill: AnyShapeStyle = active ? AnyShapeStyle(Self.accent) : AnyShapeStyle(Color.white.opacity(state < 0 ? 0.16 : 0.06))
        let scale: CGFloat = active ? 0.9 + 0.2 * springy(local / 0.4) : 0.9
        return VStack(spacing: 10) {
            Circle()
                .fill(fill)
                .frame(width: 76, height: 76)
                .overlay(Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(Color.white.opacity(iconOpacity)))
                .scaleEffect(scale)
            Text(title)
                .font(.system(size: 24, weight: active ? .semibold : .regular))
                .foregroundStyle(Color.white.opacity(active ? 1 : state < 0 ? 0.6 : 0.3))
        }
        .frame(width: 160)
    }

    // MARK: Heat alert

    private var notification: some View {
        let p = springy((local - 0.7) / 0.5)
        let x: CGFloat = Self.card.maxX - 544 + 60 * (1 - p)
        let y: CGFloat = Self.card.minY + 24
        return HStack(alignment: .top, spacing: 18) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "thermometer.high").font(.system(size: 32, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("DESKBAR").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(white: 0.6))
                    Spacer()
                    Text("now").font(.system(size: 18)).foregroundStyle(Color(white: 0.6))
                }
                Text("Mac running hot").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                Text("macOS is slowing the chip down to cool it (95°C).").font(.system(size: 22)).foregroundStyle(Color(white: 0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.2)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .offset(x: x, y: y)
        .opacity(clamp(p * 1.5) * (1 - clamp((local - (length - 0.25)) / 0.25)))
    }

    // MARK: Panel tour

    private var panelTour: some View {
        let height: CGFloat = 960, width: CGFloat = 680 * height / 1746
        let rise = springy(local / 0.6)
        let fadeOut = 1 - clamp((local - (length - 0.3)) / 0.3)
        // Section centres in the 680 × 1746 screenshot.
        let callouts: [(CGFloat, String, String)] = [
            (230, "Live 3D Mac", "and one health verdict"),
            (540, "CPU, heat and fans", "per core, with history"),
            (720, "Memory · Disk · Battery", "plus Wi-Fi and latency"),
            (1085, "Network · Sound · Display", "speed test, devices, alerts"),
            (1445, "Quick actions", "one tap, no digging"),
        ]
        let left: CGFloat = 90, top: CGFloat = 330
        return ZStack(alignment: .topLeading) {
            if let panel {
                Image(nsImage: panel).resizable()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    .offset(x: left, y: top + 160 * (1 - rise))
                    .opacity(clamp(rise * 1.4))
            }
            ForEach(Array(callouts.enumerated()), id: \.offset) { i, callout in
                let y = top + callout.0 * height / 1746
                let p = easeOut((local - 0.7 - Double(i) * 0.4) / 0.4)
                ZStack(alignment: .topLeading) {
                    Circle().fill(Self.accent).frame(width: 14, height: 14).offset(x: left + width + 14, y: y - 7)
                    Rectangle().fill(Color.white.opacity(0.3)).frame(width: 70 * p, height: 2).offset(x: left + width + 30, y: y - 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(callout.1).font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
                        Text(callout.2).font(.system(size: 26)).foregroundStyle(Color(white: 0.6))
                    }
                    .fixedSize()
                    .offset(x: left + width + 116 + 20 * (1 - p), y: y - 34)
                }
                .opacity(p)
            }
        }
        .opacity(fadeOut)
    }

    // MARK: Quick actions

    private var actions: some View {
        let items: [(String, String)] = [("Focus", "moon.fill"), ("Awake", "cup.and.saucer.fill"), ("Hide desk", "eye.slash.fill"),
                                         ("Mute mic", "mic.slash.fill"), ("Display off", "display"), ("Capture", "camera.viewfinder"),
                                         ("Clean up", "arrow.down.circle"), ("Lock", "lock.fill")]
        let focusOn = local > 1.7
        let tap = clamp((local - 1.55) / 0.35)
        let fadeOut = 1 - clamp((local - (length - 0.25)) / 0.25)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let p = springy((local - 0.2 - Double(i) * 0.07) / 0.45)
                let on = i == 0 && focusOn
                VStack(spacing: 18) {
                    Circle()
                        .fill(on ? AnyShapeStyle(Self.accent) : AnyShapeStyle(Color.white.opacity(0.12)))
                        .frame(width: 150, height: 150)
                        .overlay(Image(systemName: item.1).font(.system(size: 54, weight: .medium)).foregroundStyle(.white))
                        .scaleEffect(i == 0 && tap > 0 && tap < 1 ? 1 - 0.12 * sin(tap * .pi) : 1)
                    Text(item.0).font(.system(size: 30, weight: .medium)).foregroundStyle(Color(white: on ? 1 : 0.75))
                }
                .frame(width: 230)
                .scaleEffect(0.4 + 0.6 * p)
                .opacity(clamp(p * 1.5))
                .offset(x: 80 + CGFloat(i % 4) * 230, y: 480 + CGFloat(i / 4) * 280)
            }
            Text("Focus on")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color(white: 0.7))
                .frame(width: DemoVideo.size.width)
                .offset(y: 1060)
                .opacity(easeOut((local - 1.8) / 0.3))
        }
        .opacity(fadeOut)
    }

    // MARK: End card

    private var endCard: some View {
        let icon = springy((local - 0.15) / 0.55)
        let name = easeOut((local - 0.45) / 0.45)
        let chips = ["Free", "Open source", "Private by design"]
        let link = easeOut((local - 1.8) / 0.4)
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 56, style: .continuous)
                .fill(Self.accent)
                .frame(width: 240, height: 240)
                .overlay(Image(systemName: "macbook").font(.system(size: 130, weight: .light)).foregroundStyle(.white))
                .shadow(color: Color(red: 0.4, green: 0.4, blue: 1).opacity(0.5), radius: 40, y: 12)
                .scaleEffect(0.3 + 0.7 * icon)
                .opacity(clamp(icon * 1.5))
                .offset(y: 300)
            Text("DeskBar")
                .font(.system(size: 120, weight: .heavy)).tracking(-3)
                .foregroundStyle(.white)
                .opacity(name).offset(y: 590 + 30 * (1 - name))
            Text("Your Mac, at a glance.")
                .font(.system(size: 46))
                .foregroundStyle(Color(white: 0.7))
                .opacity(easeOut((local - 0.7) / 0.45)).offset(y: 750)
            HStack(spacing: 16) {
                ForEach(Array(chips.enumerated()), id: \.offset) { i, chip in
                    let p = springy((local - 1.1 - Double(i) * 0.12) / 0.4)
                    Text(chip)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26).padding(.vertical, 14)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16)))
                        .scaleEffect(0.6 + 0.4 * p)
                        .opacity(clamp(p * 1.5))
                }
            }
            .offset(y: 850)
            HStack(spacing: 12) {
                Text("Link in the comments")
                Image(systemName: "arrow.down")
                    .offset(y: 8 * sin(max(0, local - 1.8) * 6))
            }
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(Self.accent)
            .opacity(link).offset(y: 1030)
            Text("This video was rendered by DeskBar itself.")
                .font(.system(size: 24))
                .foregroundStyle(Color(white: 0.45))
                .opacity(easeOut((local - 2.4) / 0.5)).offset(y: 1220)
        }
        .frame(width: DemoVideo.size.width)
    }
}

/// The macOS arrow pointer.
private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width / 30, h = rect.height / 44
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 34 * h))
        path.addLine(to: CGPoint(x: 8 * w, y: 27 * h))
        path.addLine(to: CGPoint(x: 13 * w, y: 39 * h))
        path.addLine(to: CGPoint(x: 18 * w, y: 37 * h))
        path.addLine(to: CGPoint(x: 13 * w, y: 25 * h))
        path.addLine(to: CGPoint(x: 23 * w, y: 25 * h))
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
