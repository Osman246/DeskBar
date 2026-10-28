import AVFoundation
import CoreText
import SwiftUI

/// `DESKBAR_DEMO=1 DeskBar --snapshot <dir> --demo-video [--fonts <dir>] [--url <download page>]` renders a one-minute
/// launch video (1080 × 1350, 30 fps, with a quiet sound track) from the real 3D Mac, recorded
/// live, and the real panel screenshots in docs/images. Captions, menu bar and pointer are drawn
/// here, cut like a short cinematic edit: black, serif headlines. The first frame already reads,
/// since feeds autoplay muted.
///
/// `--credit "Built by …"` adds a credit line to the end card, and `--credit-note "…"` a small line
/// under it.
///
/// The headlines use EB Garamond (SIL Open Font License) when its .ttf files are in the `--fonts`
/// directory, and macOS's Hoefler Text otherwise.
@MainActor
enum DemoVideo {
    /// `open` is only a recording (the 3D Mac's opening, shown under the brand card).
    enum Part: CaseIterable { case hook, dashboard, lid, plug, ports, news, heat, outcome, thesis, brand, cta, open }

    static let sequence: [Part] = [.hook, .dashboard, .lid, .plug, .ports, .news, .heat, .outcome, .thesis, .brand, .cta]
    static let size = CGSize(width: 1080, height: 1350)
    static let fps = 30.0
    static let lengths: [Part: Double] = [.hook: 1.85, .dashboard: 13.15, .lid: 2.8, .plug: 3.0, .ports: 4.0, .news: 4.2,
                                          .heat: 6.0, .outcome: 6.0, .thesis: 7.0, .brand: 5.0, .cta: 7.0, .open: 0]
    static var total: Double { sequence.reduce(0) { $0 + lengths[$1]! } }
    /// When each part starts, for the sound track.
    static func start(of part: Part) -> Double { sequence.prefix { $0 != part }.reduce(0) { $0 + lengths[$1]! } }
    nonisolated(unsafe) static var serif = "Hoefler Text"   // set once before rendering
    nonisolated(unsafe) static var credit: String?
    nonisolated(unsafe) static var creditNote: String?
    /// The verified download page for the end card (`--url`); without it the card points to the comments.
    nonisolated(unsafe) static var url: String?

    /// Where `t` falls: the part and the time into it.
    static func part(at t: Double) -> (Part, Double) {
        var start = 0.0
        for part in sequence {
            let length = lengths[part]!
            if t < start + length { return (part, t - start) }
            start += length
        }
        return (.cta, lengths[.cta]!)
    }

    static func make(model: AppModel, to directory: String) async {
        if let i = CommandLine.arguments.firstIndex(of: "--fonts"), i + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "ttf" || file.pathExtension == "otf" {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
            if NSFontManager.shared.availableFontFamilies.contains("EB Garamond") { serif = "EB Garamond" }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--credit"), i + 1 < CommandLine.arguments.count {
            credit = CommandLine.arguments[i + 1]
        }
        if let i = CommandLine.arguments.firstIndex(of: "--credit-note"), i + 1 < CommandLine.arguments.count {
            creditNote = CommandLine.arguments[i + 1]
        }
        if let i = CommandLine.arguments.firstIndex(of: "--url"), i + 1 < CommandLine.arguments.count {
            url = CommandLine.arguments[i + 1]
        }
        print("Headlines in \(serif)")
        let mac = model.mac
        await mac.waitUntilLoaded()
        let clips = await record(mac)
        let images = FileManager.default.currentDirectoryPath + "/docs/images/"
        let shots = Shots(panel: NSImage(contentsOfFile: images + "panel-dark.png"),
                          memory: NSImage(contentsOfFile: images + "memory.png"),
                          disk: NSImage(contentsOfFile: images + "disk.png"),
                          battery: NSImage(contentsOfFile: images + "battery.png"),
                          alertPanel: NSImage(contentsOfFile: images + "alert-panel.png"),
                          alertMemory: NSImage(contentsOfFile: images + "alert-memory.png"))

        let url = URL(fileURLWithPath: directory).appendingPathComponent("deskbar-demo.mp4")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000,
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
        let stills = Set(stride(from: 0.0, to: total, by: 1.2).map { Int($0 * fps) })
        for index in 0..<frames {
            let t = Double(index) / fps
            let view = DemoFrame(t: t, clips: clips, shots: shots)
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
        guard writer.status == .completed else { print("Video failed: \(writer.error?.localizedDescription ?? "?")"); return }
        await DemoSound.add(to: url)
        print("Wrote \(url.path)")
    }

    /// The real panel, as the screenshots in docs/images show it: closed, Memory open, Battery open, and
    /// the same demo with memory full (`DESKBAR_DEMO_ALERT=1`), closed and with Memory open.
    struct Shots {
        var panel: NSImage?
        var memory: NSImage?
        var disk: NSImage?
        var battery: NSImage?
        var alertPanel: NSImage?
        var alertMemory: NSImage?
    }

    // MARK: Recording the 3D Mac

    /// The ports the video shows connected; anything not listed is empty.
    static let shownPorts = ["Port-MagSafe 3@1": "Charging · 70 W", "Port-USB-C@2": "Display · 4K",
                             "Port-USB-C@1": "Display · 4K", "Port-USB-C@4": "SSD · 1 TB", "Port-SD Card@1": "SD card · 128 GB"]

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
        desk.ports = ports(shownPorts)
        desk.externalDisplays = 2
        desk.leftMonitor = true
        desk.rightMonitor = true
        var hot = base
        hot.temperature = 95
        hot.warning = "Running hot"

        func reset(_ state: MacState) {
            mac.simulateLid(112)
            mac.update(state)
            mac.setMode(.rest)
            mac.settleForStill()
        }

        reset(base)
        // The opening's turn is quick enough for the menu bar but reads as a jump full-screen.
        clips[.open] = await mac.recordClip(seconds: 3.6, intro: true, speed: 0.65)

        reset(base)
        clips[.lid] = await mac.recordClip(seconds: 2.8) { t in
            let angle = t < 0.2 ? 112 : t < 1.0 ? 112 - 77 * ease((t - 0.2) / 0.8) : t < 1.25 ? 35 : 35 + 77 * ease((t - 1.25) / 0.9)
            mac.simulateLid(angle)
        }

        // MagSafe goes in, then the monitors rise around it: power and desk in one beat.
        reset(base)
        var plugged = false, atDesk = false
        clips[.plug] = await mac.recordClip(seconds: 3.0) { t in
            if t > 0.3 && !plugged { plugged = true; mac.update(charging) }
            if t > 1.2 && !atDesk { atDesk = true; mac.update(desk); mac.setMode(.desk) }
        }

        reset(desk)
        var leftSide = false, rightSide = false
        clips[.ports] = await mac.recordClip(seconds: 4.0) { t in
            if !leftSide { leftSide = true; mac.setMode(.ports(.left)) }
            if t > 1.9 && !rightSide { rightSide = true; mac.setMode(.ports(.right)) }
        }

        // The screen and the status follow each alert as it arrives (times match `alerts`).
        reset(hot)
        var heated = false, shown = 0
        clips[.heat] = await mac.recordClip(seconds: 6.0) { t in
            if !heated { heated = true; mac.setMode(.heat) }
            let next = [1.9, 3.2, 4.5].filter { t >= $0 }.count
            guard next != shown else { return }
            shown = next
            var state = hot
            state.warning = ["Running hot", "Disk almost full", "Low battery", "Memory full"][next]
            if next >= 2 { state.batteryPercent = 18 }
            mac.update(state)
        }
        reset(base)
        for (part, clip) in clips { print(part, String(format: "%.0f fps recorded", Double(clip.count) / max(0.1, clip.last?.time ?? 1))) }
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

private func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .custom(DemoVideo.serif, size: size).weight(weight)
}

// MARK: - Headlines

/// A headline that arrives word by word, each word sharpening out of a blur. Words wrapped in
/// `*` are set in italic; `|` breaks the line.
private struct Headline: View {
    let text: String
    let size: CGFloat
    let time: Double         // seconds since it started
    var leave: Double = 0    // 0…1 as it blurs away
    var alignment: HorizontalAlignment = .center

    var body: some View {
        // Words with their italic flag; an italic span runs from a word starting with * to one ending with *.
        // Each word with its italic flag and its place in the whole headline, worked out up front
        // (a counter inside the view builder can run more than once and delay the later words).
        var inItalic = false, count = 0
        let lines: [[(word: String, italic: Bool, index: Int)]] = text.split(separator: "|").map { line in
            line.split(separator: " ").map { raw in
                let word = String(raw)
                if word.hasPrefix("*") { inItalic = true }
                let entry = (word: word.replacingOccurrences(of: "*", with: ""), italic: inItalic, index: count)
                if word.hasSuffix("*") { inItalic = false }
                count += 1
                return entry
            }
        }
        return VStack(alignment: alignment, spacing: size * 0.06) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, words in
                HStack(alignment: .firstTextBaseline, spacing: size * 0.24) {
                    ForEach(Array(words.enumerated()), id: \.offset) { _, entry in
                        let p = easeOut((time - Double(entry.index) * 0.08) / 0.45)
                        Text(entry.word)
                            .font(serif(size, .regular))
                            .italic(entry.italic)
                            .fixedSize()
                            .foregroundStyle(Color.white)
                            .blur(radius: 14 * (1 - p) + 18 * leave)
                            .opacity(p * (1 - leave))
                            .scaleEffect(1.12 - 0.12 * p)
                            .offset(y: 18 * (1 - p))
                    }
                }
            }
        }
        .tracking(-size * 0.015)
    }
}

/// Small, widely spaced capitals above a headline, in SF Pro like all the supporting text.
private struct Kicker: View {
    let text: String
    let time: Double
    var size: CGFloat = 21
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(size / 3)
            .foregroundStyle(Color(white: size > 21 ? 0.7 : 0.55))
            .opacity(easeOut(time / 0.4))
    }
}

// MARK: - One frame

struct DemoFrame: View {
    let t: Double
    let clips: [DemoVideo.Part: [MacScene.ClipFrame]]
    let shots: DemoVideo.Shots

    private var current: (DemoVideo.Part, Double) { DemoVideo.part(at: t) }
    private var part: DemoVideo.Part { current.0 }
    private var local: Double { current.1 }
    private var length: Double { DemoVideo.lengths[part]! }
    private var leaving: Double { clamp((local - (length - 0.22)) / 0.22) }

    /// Where the 3D Mac sits.
    static let stage = CGRect(x: 60, y: 430, width: 960, height: 630)
    static let productParts: [DemoVideo.Part] = [.lid, .plug, .ports, .heat]
    /// A flash and punch-in only where a new section starts. Within the product sequences the camera
    /// moves instead, and the hardware shots cut straight to each other.
    static let flashes: [DemoVideo.Part] = [.lid, .news, .heat, .thesis, .brand]
    static let punches: [DemoVideo.Part] = flashes + [.plug, .ports]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Group {
                switch part {
                case .hook: hook
                case .dashboard: dashboard
                case .news: news
                case .outcome: outcome
                case .thesis: thesis
                case .brand: brand
                case .cta: callToAction
                default: EmptyView()
                }
                if Self.productParts.contains(part) { product }
                if Self.productParts.contains(part) { caption }
                if part == .heat { notifications(at: local).opacity(1) }
            }
            .scaleEffect(punch, anchor: .center)
            menuBar
            cursor
            finish
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
        .clipped()
    }

    private var punch: CGFloat {
        Self.punches.contains(part) ? 1 + 0.05 * (1 - easeOut(local / 0.35)) : 1
    }

    /// Flash, vignette and the progress line, over everything.
    private var finish: some View {
        ZStack(alignment: .topLeading) {
            if Self.flashes.contains(part) {
                Color.white.opacity(0.1 * (1 - clamp(local / 0.15)))
            }
            RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 420, endRadius: 920)
            Rectangle().fill(Color.white.opacity(0.85))
                .frame(width: DemoVideo.size.width * t / DemoVideo.total, height: 3)
                .offset(y: DemoVideo.size.height - 3)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
        .allowsHitTesting(false)
    }

    // MARK: Hook

    /// The question and the first window from frame one, under a menu bar that's already there. The
    /// four places you'd check today pile up, then fly into the one menu bar item.
    private var hook: some View {
        ZStack(alignment: .topLeading) {
            Text("Is your Mac OK?")
                .font(serif(104))
                .tracking(-1.5)
                .foregroundStyle(.white)
                .frame(width: DemoVideo.size.width)
                .offset(y: 120)
                .opacity(1 - clamp((local - 1.45) / 0.3))
            clutter(local + 0.35)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    private static let places: [(name: String, symbol: String, centre: CGPoint, angle: Double)] = [
        ("Activity Monitor", "waveform.path.ecg", CGPoint(x: 330, y: 560), -5),
        ("System Settings", "gearshape.fill", CGPoint(x: 740, y: 660), 4),
        ("Control Centre", "switch.2", CGPoint(x: 360, y: 860), 3),
        ("Battery menu", "battery.75percent", CGPoint(x: 720, y: 960), -4),
    ]

    private func clutter(_ t: Double) -> some View {
        let collapse = ease((t - 1.8) / 0.4)
        return ZStack(alignment: .topLeading) {
            Text("TODAY YOU'D CHECK")
                .font(.system(size: 30, weight: .semibold)).tracking(10)
                .foregroundStyle(Color(white: 0.7))
                .frame(width: DemoVideo.size.width)
                .offset(y: 300)
                .opacity(1 - collapse)
            ForEach(Array(Self.places.enumerated()), id: \.offset) { i, place in
                placeWindow(place.name, place.symbol, pop: springy((t - 0.1 - Double(i) * 0.22) / 0.35))
                    .rotationEffect(.degrees(place.angle * (1 - collapse)))
                    .scaleEffect(1 - 0.94 * collapse)
                    .position(x: place.centre.x + (Self.itemCentre.x - place.centre.x) * collapse,
                              y: place.centre.y + (Self.itemCentre.y - place.centre.y) * collapse)
                    .opacity(1 - clamp((collapse - 0.85) / 0.15))
            }
            let land = clamp((t - 2.15) / 0.3)
            if land > 0 && land < 1 {
                Circle()
                    .strokeBorder(Color.white.opacity(0.8 * (1 - land)), lineWidth: 3)
                    .frame(width: 40 + 160 * land, height: 40 + 160 * land)
                    .position(Self.itemCentre)
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    /// A small macOS-style window: traffic lights, an icon and the app's name.
    private func placeWindow(_ name: String, _ symbol: String, pop: Double) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 14, height: 14)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 14, height: 14)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 14, height: 14)
            }
            HStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: 40, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 56)
                Text(name).font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .padding(28)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.15)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
        .scaleEffect(0.6 + 0.4 * pop)
        .opacity(clamp(pop * 1.8))
    }

    // MARK: Menu bar and pointer

    private var menuBarShown: Double {
        switch part {
        case .brand: 1 - ease(local / 0.4)
        case .cta: 0
        default: 1
        }
    }

    /// The DeskBar item, in canvas points.
    static let itemCentre = CGPoint(x: 626, y: 28)

    private var panelOpen: Bool {
        switch part {
        case .hook, .brand, .cta: false
        case .dashboard: local > 0.04
        default: true
        }
    }

    /// Drawn larger than a real menu bar so it stays crisp at phone size.
    private var menuBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "apple.logo").font(.system(size: 29)).frame(width: 52)
            ForEach(["Finder", "File", "Edit", "View"], id: \.self) { item in
                Text(item).font(.system(size: 26, weight: item == "Finder" ? .bold : .regular)).padding(.horizontal, 12)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "thermometer.medium")
                Text("39°").monospacedDigit()
            }
            .font(.system(size: 26, weight: .medium))
            .frame(width: 128, height: 42)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(panelOpen ? 0.22 : 0)))
            Image(systemName: "wifi").font(.system(size: 24)).frame(width: 64)
            Image(systemName: "battery.75percent").font(.system(size: 27)).frame(width: 72)
            Text(Demo.now.formatted(.dateTime.weekday(.abbreviated).hour().minute()))   // matches the 3D Mac's screen
                .font(.system(size: 26))
                .frame(width: 230, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .frame(width: DemoVideo.size.width, height: 56)
        .background(Color(white: 0.1).opacity(0.95))
        .offset(y: -56 * (1 - menuBarShown))
        .opacity(menuBarShown)
    }

    /// Where the pointer is, and how far through a click it is (nil when no click is playing).
    private var pointer: (at: CGPoint, click: Double?, clickAt: CGPoint)? {
        func glide(_ from: CGPoint, _ to: CGPoint, _ p: Double) -> CGPoint {
            CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
        }
        func clicking(_ t: Double) -> Double? { t > 0 && t < 0.45 ? t / 0.45 : nil }
        switch part {
        case .dashboard where local < 1.4:
            return (glide(CGPoint(x: 700, y: 160), Self.itemCentre, ease(local / 0.06)), clicking(local - 0.04), Self.itemCentre)
        case .dashboard where local > 8.3:
            let tiles = [Self.memoryTile, Self.diskTile, Self.batteryTile], clicks = Self.tileClicks
            let i = clicks.lastIndex { local >= $0 - 0.55 } ?? 0
            let start = i == 0 ? CGPoint(x: 540, y: 1150) : tiles[i - 1]
            return (glide(start, tiles[i], ease((local - (clicks[i] - 0.55)) / 0.45)), clicking(local - clicks[i]), tiles[i])
        case .outcome where local < 1.2:
            return (glide(CGPoint(x: 560, y: 1150), Self.topBanner, ease(local / 0.5)), clicking(local - 0.55), Self.topBanner)
        default: return nil
        }
    }

    @ViewBuilder private var cursor: some View {
        if let pointer {
            ZStack(alignment: .topLeading) {
                if let click = pointer.click {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.7 * (1 - click)), lineWidth: 4)
                        .frame(width: 30 + 90 * click, height: 30 + 90 * click)
                        .position(pointer.clickAt)
                }
                Arrow()
                    .fill(Color.black)
                    .overlay(Arrow().stroke(Color.white, lineWidth: 2.5))
                    .frame(width: 36, height: 53)
                    .scaleEffect((pointer.click ?? 1) < 0.25 ? 0.85 : 1, anchor: .topLeading)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .offset(x: pointer.at.x + 4, y: pointer.at.y + 4)
            }
            .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
            .opacity(part == .dashboard && local < 1.4 ? 1 - clamp((local - 1.0) / 0.3) : part == .outcome ? 1 - clamp((local - 0.9) / 0.3) : 1)
        }
    }

    // MARK: Captions

    private var captionText: (headline: String, line: String) {
        switch part {
        case .lid: ("It mirrors *your* Mac.", "The panel's 3D Mac follows your real lid.")
        case .plug: ("Plug in. *It knows.*", "Charger and monitors appear as you connect them.")
        case .ports: ("Every port, *labelled.*", "The same labels you get in DeskBar's ports view.")
        case .heat: ("Warns you *early.*", "Before heat, memory, disk or battery become a problem.")
        default: ("", "")
        }
    }

    private var caption: some View {
        topCaption(captionText.headline, captionText.line, time: local, leave: part == .heat ? 0 : leaving)
    }

    /// The Mac sits lower in the alert shots, so the banners have room above it.
    static func stageDrop(_ part: DemoVideo.Part) -> CGFloat { part == .heat || part == .outcome ? 90 : 0 }

    private func topCaption(_ headline: String, _ line: String, time: Double, leave: Double) -> some View {
        VStack(spacing: 14) {
            Headline(text: headline, size: 82, time: time - 0.08, leave: leave)
            Text(line)
                .font(.system(size: 32))
                .foregroundStyle(Color(white: 0.66))
                .opacity(easeOut((time - 0.4) / 0.35) * (1 - leave))
        }
        .frame(width: DemoVideo.size.width)
        .offset(y: 140)
    }

    // MARK: The 3D Mac

    private var clip: [MacScene.ClipFrame] { clips[part] ?? [] }

    private func frame(at time: Double) -> MacScene.ClipFrame? {
        clip.last { $0.time <= time } ?? clip.first
    }

    private var product: some View {
        let stage = Self.stage
        let now = frame(at: local)
        let push = 1 + 0.045 * local / length   // slow push-in through the shot
        return ZStack(alignment: .topLeading) {
            if let now {
                Image(nsImage: now.image).resizable()
                    .frame(width: stage.width, height: stage.height)
                if part == .ports { portLabels(now) }
            }
        }
        .frame(width: stage.width, height: stage.height, alignment: .topLeading)
        .scaleEffect(push)
        .offset(x: stage.minX, y: stage.minY + Self.stageDrop(part))
        .overlay(alignment: .topLeading) { status(now) }
    }

    /// What the card would say, set as a quiet line under the Mac.
    @ViewBuilder private func status(_ now: MacScene.ClipFrame?) -> some View {
        let pills = now?.pills ?? []
        let shownPills = pills
        if part != .ports && !shownPills.isEmpty {
            HStack(spacing: 34) {
                ForEach(shownPills) { pill in
                    HStack(spacing: 12) {
                        Circle().fill(pill.color).frame(width: 12, height: 12)
                        Text(pill.text.uppercased()).font(.system(size: 21, weight: .semibold)).tracking(4).foregroundStyle(Color(white: 0.8))
                    }
                }
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: Self.stage.maxY + 22 + Self.stageDrop(part))
            .opacity(easeOut(local / 0.3) * (1 - leaving))
        }
    }

    /// Rings on the ports and labels below, arriving one after another once the camera settles.
    private func portLabels(_ now: MacScene.ClipFrame) -> some View {
        let side: Ports.Side = local < 1.9 ? .left : .right
        let ports = DemoVideo.ports(DemoVideo.shownPorts).filter { $0.side == side && now.anchors[$0.id] != nil }
        // How long the anchors have been showing.
        let since = clip.reversed().drop { $0.time > local }.prefix { !$0.anchors.isEmpty }.last.map { local - $0.time } ?? 0
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: UnitPoint(x: 0.5, y: 0.42), endPoint: UnitPoint(x: 0.5, y: 0.64))
            ForEach(Array(ports.sorted { $0.z < $1.z }.enumerated()), id: \.element.id) { i, port in
                portLabel(port, anchor: now.anchors[port.id]!, index: i, since: since)
            }
        }
    }

    private func portLabel(_ port: Ports.Port, anchor: CGPoint, index: Int, since: Double) -> some View {
        let x: CGFloat = anchor.x * 3, y: CGFloat = anchor.y * 3
        let p = easeOut((since - Double(index) * 0.12) / 0.35)
        let labelY: CGFloat = 470 + CGFloat(index % 2) * 74
        let line: CGFloat = max(0, (labelY - y - 16) * p)
        return ZStack(alignment: .topLeading) {
            Circle().strokeBorder(port.connected ? Color.white : Color.white.opacity(0.45), lineWidth: 3)
                .frame(width: 26, height: 26).offset(x: x - 13, y: y - 13)
            Rectangle().fill(Color.white.opacity(0.4)).frame(width: 1.5, height: line)
                .offset(x: x - 0.75, y: y + 13)
            VStack(spacing: 0) {
                Text(port.name).font(.system(size: 27, weight: .semibold)).foregroundStyle(.white)
                Text(port.detail).font(.system(size: 22)).foregroundStyle(Color(white: port.connected ? 0.75 : 0.45))
            }
            .fixedSize()
            .frame(width: 260)
            .offset(x: x - 130, y: labelY + 14 * (1 - p))
            .opacity(p)
        }
    }

    // MARK: Heat alert

    /// DeskBar's real alerts, in its own wording (Alerts.swift), arriving one after another and stacking
    /// like Notification Centre. Memory lands last, on top: that's the one the pointer opens next.
    private static let alerts: [(at: Double, symbol: String, tint: Color, title: String, body: String)] = [
        (0.6, "thermometer.high", .orange, "Mac running hot", "macOS is slowing the chip down to cool it (95°C). Safari is the busiest app."),
        (1.9, "internaldrive", Color(red: 0.95, green: 0.36, blue: 0.24), "Disk almost full", "Only 8.6 GB free. Try Clean up in DeskBar."),
        (3.2, "battery.25percent", Color(red: 0.98, green: 0.42, blue: 0.4), "Battery low", "18% left, about 1h 5m."),
        (4.5, "memorychip", Color(red: 1, green: 0.72, blue: 0.2), "Memory full", "Apps may slow down. Safari is using 6.0 GB."),
    ]
    /// Where the newest banner sits, for the pointer.
    static let topBanner = CGPoint(x: 540, y: 400)

    private func notifications(at time: Double) -> some View {
        let alerts = Self.alerts
        return ZStack(alignment: .topLeading) {
            ForEach(Array(alerts.enumerated()), id: \.offset) { i, alert in
                // How far newer alerts have pushed this one back into the stack.
                let depth = alerts[(i + 1)...].reduce(0.0) { $0 + easeOut((time - $1.at) / 0.35) }
                notification(alert.symbol, alert.tint, alert.title, alert.body, arrival: springy((time - alert.at) / 0.5), depth: depth)
                    .zIndex(Double(i))
            }
        }
    }

    private func notification(_ symbol: String, _ tint: Color, _ title: String, _ body: String, arrival p: Double, depth: Double) -> some View {
        let x: CGFloat = 200
        let y: CGFloat = 330 + 22 * depth - 40 * (1 - p)
        let scale: CGFloat = 1 - 0.05 * depth
        return HStack(alignment: .top, spacing: 18) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint)
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("DESKBAR").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(white: 0.6))
                    Spacer()
                    Text("now").font(.system(size: 18)).foregroundStyle(Color(white: 0.6))
                }
                Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                Text(body).font(.system(size: 23)).foregroundStyle(Color(white: 0.82))
                    .lineLimit(2)
            }
            .opacity(1 - clamp(depth * 2))   // only the newest one's text shows
        }
        .padding(22)
        .frame(width: 680, height: 148, alignment: .topLeading)   // one height, so the stack lines up
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.17 - 0.03 * min(depth, 2))))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
        .scaleEffect(scale * (0.96 + 0.04 * p), anchor: .top)
        .offset(x: x, y: y)
        .opacity(clamp(p * 5) * (1 - clamp((depth - 2) / 0.6)))   // solid almost at once, so nothing shows through
    }

    // MARK: The dashboard: one continuous shot of the real panel

    /// The tiles while the tour frames them, in canvas points.
    static let memoryTile = CGPoint(x: 225, y: 484)
    static let diskTile = CGPoint(x: 540, y: 484)
    static let batteryTile = CGPoint(x: 855, y: 484)
    static let tourView = CGRect(x: 60, y: 360, width: 960, height: 700)
    static let tourScale: CGFloat = 960 / 680
    /// Clicks on the tiles, in seconds into the dashboard.
    static let tileClicks: [Double] = [8.85, 10.25, 11.65]
    /// The tour's stops: when it gets there, which part of the screenshot it centres, and what it says.
    private static let stops: [(at: Double, centre: CGFloat, title: String, detail: String)] = [
        (3.3, 230, "A living 3D Mac", "One verdict on top: “All good”, or what isn't."),
        (4.5, 542, "CPU, heat and fans", "Every core at a glance, with a short history."),
        (5.7, 1085, "Network, sound, display", "Speed test, devices and smart alerts, one line each."),
        (6.9, 1445, "Quick actions", "Focus, keep awake, lock and more, one tap each."),
        (8.1, 860, "Memory, disk, battery", "Click any tile for what's behind it."),
    ]

    /// Click, the real panel drops under the menu bar item, then the camera flies into it and reads it
    /// top to bottom; back at the tiles, the pointer opens Memory, Disk and Battery in place.
    private var dashboard: some View {
        let k = Self.tourScale, view = Self.tourView, stops = Self.stops
        let index = stops.lastIndex { local >= $0.at } ?? 0
        let from = stops[max(index - 1, 0)].centre, to = stops[index].centre
        // The last move goes back up the panel, so it takes longer.
        let moveTime = index == stops.count - 1 ? 0.75 : 0.45
        let centre = local < stops[0].at ? stops[0].centre : from + (to - from) * ease((local - stops[index].at) / moveTime)
        let scroll = min(0, max(view.height - 2316 * k, view.height / 2 - centre * k))
        // One move from the dropped panel (under the menu bar item) to the tour's framing.
        let fly = ease((local - 2.4) / 0.8)
        let s0: CGFloat = 428 / 680
        let drop = springy((local - 0.08) / 0.45)
        let scale = s0 + (k - s0) * fly
        let px = 612 + (view.minX - 612) * fly
        let py = (64 - 24 * (1 - drop)) + (view.minY + scroll - 64) * fly
        let clip = CGRect(x: 612 + (view.minX - 612) * fly, y: 64 + (view.minY - 64) * fly,
                          width: 428 + (view.width - 428) * fly, height: 1099 + (view.height - 1099) * fly)
        // Each tile click expands its detail below the tiles, like the real panel.
        let wipes = Self.tileClicks.map { ease((local - $0 - 0.08) / 0.4) }
        let label = local < stops[0].at ? 0 : easeOut((local - stops[index].at - 0.15) / 0.35)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                panelImage(shots.panel, 1746, scale: scale)
                expanding(shots.memory, 2144, scale: scale, wipe: wipes[0])
                expanding(shots.disk, 2070, scale: scale, wipe: wipes[1])
                expanding(shots.battery, 2316, scale: scale, wipe: wipes[2])
            }
            .offset(x: px, y: py)
            .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
            .mask {
                RoundedRectangle(cornerRadius: 14 + 8 * fly, style: .continuous)
                    .frame(width: clip.width, height: clip.height)
                    .offset(x: clip.minX, y: clip.minY)
                    .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
            }
            .opacity(clamp(drop * 2))
            // Before the fly-in: what it is.
            VStack(alignment: .leading, spacing: 16) {
                Kicker(text: "Introducing DeskBar", time: local - 0.3, size: 28)
                Headline(text: "One click.|*One answer.*", size: 84, time: local - 0.4, alignment: .leading)
                Text("“All good”, or the one\nthing that isn't.")
                    .font(.system(size: 34))
                    .foregroundStyle(Color(white: 0.66))
                    .opacity(easeOut((local - 0.95) / 0.35))
            }
            .offset(x: 60, y: 430)
            .opacity(1 - clamp((local - 2.2) / 0.3))
            if local > 2.7 && local < 8.1 {
                topCaption("Everything, *at a glance.*", "One panel, read top to bottom.", time: local - 2.7,
                           leave: clamp((local - 7.85) / 0.22))
            } else if local >= 8.1 {
                topCaption("Detail *on request.*", "Click any tile to see what's behind it.", time: local - 8.1, leave: leaving)
            }
            if local >= stops[0].at {
                let stop = stops[index]
                VStack(spacing: 6) {
                    HStack(spacing: 14) {
                        Text(String(format: "%02d / %02d", index + 1, stops.count)).monospacedDigit().foregroundStyle(Color(white: 0.5))
                        Text(stop.title).font(serif(44)).foregroundStyle(.white)
                    }
                    .font(.system(size: 24, weight: .semibold))
                    Text(stop.detail).font(.system(size: 30)).foregroundStyle(Color(white: 0.68))
                }
                .frame(width: DemoVideo.size.width)
                .offset(y: view.maxY + 34)
                .blur(radius: 8 * (1 - label))
                .opacity(label * (1 - leaving))
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    /// A tile's expanded view, revealed downward from the bottom of the tiles as `wipe` goes 0 → 1.
    @ViewBuilder private func expanding(_ image: NSImage?, _ height: CGFloat, scale: CGFloat, wipe: Double) -> some View {
        if wipe > 0 {
            let edge = (780 + (height - 780) * wipe) * scale
            panelImage(image, height, scale: scale)
                .mask(alignment: .top) {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: edge + 40)
                }
        }
    }

    @ViewBuilder private func panelImage(_ image: NSImage?, _ height: CGFloat, scale: CGFloat) -> some View {
        if let image {
            Image(nsImage: image).resizable().frame(width: 680 * scale, height: height * scale)
        }
    }

    // MARK: News

    /// A short news card in the video's own dark style, then straight into the alerts.
    /// Reported by PBS NewsHour, 26 June 2026 (Apple announced it on the 25th): Apple raised Mac and
    /// iPad prices, blaming a memory chip shortage driven by AI; the 1 TB 14-inch MacBook Pro went
    /// from $1,699 to $1,999.
    private var news: some View {
        let card = easeOut(local / 0.4)
        let strike = easeOut((local - 1.0) / 0.35), price = easeOut((local - 1.25) / 0.3)
        return VStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("IN THE NEWS").tracking(6)
                    Spacer()
                    Text("JUNE 2026").tracking(4)
                }
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(white: 0.55))
                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1.5)
                Text("Apple raised Mac prices, blaming an *AI-driven memory shortage.*")
                    .font(serif(60))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Text("14-inch MacBook Pro, 1 TB").font(.system(size: 30)).foregroundStyle(Color(white: 0.66))
                    Text("$1,699").font(.system(size: 32, weight: .medium)).foregroundStyle(Color(white: 0.5))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.8)).frame(height: 2.5).scaleEffect(x: strike, anchor: .leading)
                        }
                    Text("→ $1,999").font(.system(size: 36, weight: .bold)).foregroundStyle(.white)
                        .opacity(price).offset(x: 12 * (1 - price))
                }
                Text("Reported by PBS NewsHour").font(.system(size: 24)).foregroundStyle(Color(white: 0.5))
            }
            .padding(48)
            .frame(width: 920, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .scaleEffect(0.96 + 0.04 * card)
            .opacity(card)
            Text("Memory is now the expensive part.")
                .font(serif(52)).italic()
                .foregroundStyle(.white)
                .blur(radius: 10 * (1 - easeOut((local - 2.3) / 0.45)))
                .opacity(easeOut((local - 2.3) / 0.45))
        }
        .opacity(1 - leaving)
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }

    // MARK: The alert's outcome

    /// The pointer opens the Memory alert; the alerts zoom away, then the real panel shows what's behind it.
    private var outcome: some View {
        let away = ease((local - 0.55) / 0.3)
        let open = easeOut((local - 0.85) / 0.45)
        let k = Self.tourScale, view = Self.tourView
        let scroll = min(0, max(view.height - 2144 * k, view.height / 2 - 860 * k))
        let push = 1 + 0.03 * local / length
        return ZStack(alignment: .topLeading) {
            if away < 1 {
                ZStack(alignment: .topLeading) {
                    if let mac = clips[.heat]?.last {
                        Image(nsImage: mac.image).resizable()
                            .frame(width: Self.stage.width, height: Self.stage.height)
                            .offset(x: Self.stage.minX, y: Self.stage.minY + Self.stageDrop(.outcome))
                    }
                    notifications(at: 10)
                    topCaption("Warns you *early.*", "Before heat, memory, disk or battery become a problem.", time: 10, leave: 0)
                }
                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
                .scaleEffect(1 + 0.08 * away)
                .opacity(1 - away)
            }
            if open > 0 {
                ZStack(alignment: .topLeading) {
                    panelImage(shots.alertMemory, 2144, scale: k).offset(y: scroll)
                }
                .frame(width: view.width, height: view.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                .scaleEffect((0.94 + 0.06 * open) * push)
                .offset(x: view.minX, y: view.minY + 40 * (1 - open))
                .opacity(open * (1 - leaving))
                topCaption("See exactly *what's using it.*", "Memory full: Safari is using 6.0 GB.", time: local - 0.9, leave: leaving)
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    // MARK: The point of it

    /// The idea, then the real panel's own one sentence: "Memory full", fixed, "All good".
    private var thesis: some View {
        let second = local > 3.0
        let into = second ? local - 3.0 : local
        let k = Self.tourScale
        let view = CGRect(x: 60, y: 300, width: 960, height: 600)
        let scroll = min(0, max(view.height - 1746 * k, view.height / 2 - 230 * k))
        let fixed = into >= 1.5
        let glow = into >= 1.5 ? 1 - clamp((into - 1.5) / 0.6) : 0
        return ZStack {
            if !second {
                VStack(spacing: 34) {
                    Kicker(text: "What building it taught me", time: local - 0.1, size: 30)
                    Headline(text: "Nobody wants a dashboard.|*They want one sentence.*", size: 76, time: local - 0.15,
                             leave: clamp((local - 2.8) / 0.2))
                        .frame(height: 200)
                }
                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
            } else {
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        panelImage(fixed ? shots.panel : shots.alertPanel, 1746, scale: k).offset(y: scroll)
                    }
                    .frame(width: view.width, height: view.height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1 + 0.6 * glow), lineWidth: 2 + 3 * glow))
                    .shadow(color: Color.green.opacity(0.35 * glow), radius: 40 * glow)
                    .scaleEffect(1 + 0.03 * into / 4 + 0.015 * glow)
                    .offset(x: view.minX, y: view.minY)
                    .opacity(easeOut(into / 0.3) * (1 - leaving))
                    VStack(spacing: 12) {
                        Headline(text: "This is *the sentence.*", size: 72, time: into - 0.3, leave: leaving)
                        Text("“All good”, or the one thing that isn't.")
                            .font(.system(size: 34))
                            .foregroundStyle(Color(white: 0.66))
                            .opacity(easeOut((into - 0.8) / 0.4) * (1 - leaving))
                    }
                    .frame(width: DemoVideo.size.width)
                    .offset(y: view.maxY + 50)
                }
                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
                Color.white.opacity(0.25 * (1 - clamp(into / 0.1)))
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }

    // MARK: Brand and download

    /// DeskBar's real menu bar item, used as its mark (the app has no other logo).
    private func mark(_ size: CGFloat) -> some View {
        HStack(spacing: size * 0.28) {
            Image(systemName: "thermometer.medium")
            Text("39°").monospacedDigit()
        }
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, size * 0.7).padding(.vertical, size * 0.32)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
    }

    /// The brand moment: the mark and wordmark over the 3D Mac opening, and what it does well.
    private var brand: some View {
        let mac = clips[.open].flatMap { clip in clip.last { $0.time <= local } ?? clip.first }
        let appear = springy((local - 0.15) / 0.5)
        return ZStack(alignment: .topLeading) {
            if let mac {
                Image(nsImage: mac.image).resizable()
                    .frame(width: Self.stage.width, height: Self.stage.height)
                    .scaleEffect(1.05 + 0.04 * local / length)
                    .offset(x: Self.stage.minX, y: 480)
            }
            VStack(spacing: 18) {
                mark(40).scaleEffect(0.7 + 0.3 * appear).opacity(clamp(appear * 1.6))
                Headline(text: "DeskBar.", size: 170, time: local - 0.3)
                Text("Your Mac, at a glance.")
                    .font(serif(48)).italic()
                    .foregroundStyle(Color(white: 0.72))
                    .opacity(easeOut((local - 0.8) / 0.45))
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 90)
            VStack(spacing: 14) {
                Text("ONE VERDICT  ·  A LIVE 3D MAC")
                Text("EVERY PORT LABELLED  ·  PRIVATE BY DESIGN")
            }
            .font(.system(size: 24, weight: .semibold)).tracking(5)
            .foregroundStyle(Color(white: 0.66))
            .frame(width: DemoVideo.size.width)
            .offset(y: 1150)
            .opacity(easeOut((local - 1.4) / 0.5))
        }
        .opacity(1 - leaving)
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    /// Where to get it, and who made it.
    private var callToAction: some View {
        let button = springy((local - 0.8) / 0.45)
        return VStack(spacing: 0) {
            mark(36)
                .opacity(easeOut(local / 0.35))
            Headline(text: "DeskBar.", size: 150, time: local - 0.1)
                .padding(.top, 14)
            Text("Free and open source for macOS.")
                .font(.system(size: 38))
                .foregroundStyle(Color(white: 0.75))
                .opacity(easeOut((local - 0.45) / 0.4))
                .padding(.top, 6)
            HStack(spacing: 18) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 46))
                Text("Download free on GitHub").font(.system(size: 42, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 54).padding(.vertical, 30)
            .background(Capsule().fill(Color.white))
            .scaleEffect(0.8 + 0.2 * button)
            .opacity(clamp(button * 1.6))
            .padding(.top, 64)
            Group {
                if let url = DemoVideo.url {
                    Text(url).font(.system(size: 36, weight: .medium)).foregroundStyle(.white)
                } else {
                    HStack(spacing: 10) {
                        Text("Link in the comments")
                        Image(systemName: "arrow.down").font(.system(size: 28, weight: .light))
                            .offset(y: 6 * sin(max(0, local - 1.5) * 6))
                    }
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
                }
            }
            .opacity(easeOut((local - 1.4) / 0.4))
            .padding(.top, 30)
            Text("macOS 15 or later  ·  Apple silicon")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color(white: 0.55))
                .opacity(easeOut((local - 1.7) / 0.4))
                .padding(.top, 18)
            if let credit = DemoVideo.credit {
                Text(credit)
                    .font(serif(38)).italic()
                    .foregroundStyle(.white)
                    .opacity(easeOut((local - 2.4) / 0.5))
                    .padding(.top, 90)
            }
            if let note = DemoVideo.creditNote {
                Text(note)
                    .font(.system(size: 26))
                    .foregroundStyle(Color(white: 0.62))
                    .opacity(easeOut((local - 2.7) / 0.5))
                    .padding(.top, 10)
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
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

// MARK: - Sound

/// A quiet sound track made from simple tones, so there's nothing to license: soft pops as the
/// windows arrive, a click when the pointer clicks, an air whoosh on cuts and zooms, a chime per
/// alert. Muted viewers lose nothing; people who unmute get feedback on what they see.
@MainActor
enum DemoSound {
    static let rate = 48_000.0

    static func add(to video: URL) async {
        var samples = [Float](repeating: 0, count: Int(DemoVideo.total * rate) + Int(rate))
        var seed: UInt32 = 1
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        func add(at t: Double, seconds: Double, _ sample: (Double) -> Double) {
            let start = Int(t * rate)
            for i in 0..<Int(seconds * rate) where start + i >= 0 && start + i < samples.count {
                samples[start + i] += Float(sample(Double(i) / rate))
            }
        }
        func click(_ t: Double) {
            add(at: t, seconds: 0.03) { x in Double(noise()) * exp(-x / 0.0015) * 0.35 + sin(2 * .pi * 2400 * x) * exp(-x / 0.004) * 0.12 }
        }
        func pop(_ t: Double) {
            add(at: t, seconds: 0.12) { x in sin(2 * .pi * (520 * x + 1500 * x * x)) * exp(-x / 0.035) * 0.16 }
        }
        func whoosh(_ t: Double, _ seconds: Double, _ gain: Double) {
            var low = 0.0
            add(at: t, seconds: seconds) { x in
                let p = x / seconds
                let cutoff = 0.02 + 0.18 * sin(.pi * p)
                low += (Double(noise()) - low) * cutoff
                return low * pow(sin(.pi * p), 2) * gain
            }
        }
        func chime(_ t: Double) {
            for (offset, frequency) in [(0.0, 1046.5), (0.07, 1568.0)] {
                add(at: t + offset, seconds: 0.9) { x in sin(2 * .pi * frequency * x) * min(1, x / 0.005) * exp(-x / 0.3) * 0.08 }
            }
        }
        func thud(_ t: Double) {
            add(at: t, seconds: 0.3) { x in sin(2 * .pi * 90 * x) * exp(-x / 0.07) * 0.3 }
        }
        func swell(_ t: Double, _ seconds: Double) {
            add(at: t, seconds: seconds) { x in
                [110.0, 165.0, 220.0].reduce(0) { $0 + sin(2 * .pi * $1 * x) } * pow(sin(.pi * x / seconds), 2) * 0.03
            }
        }

        let at = DemoVideo.start(of:)
        for offset in [0.0, 0.19, 0.41] { pop(at(.hook) + offset) }
        whoosh(at(.hook) + 1.45, 0.45, 0.5)
        click(at(.dashboard) + 0.04)
        whoosh(at(.dashboard) + 0.1, 0.35, 0.25)
        whoosh(at(.dashboard) + 2.4, 0.8, 0.3)
        for offset in [4.5, 5.7, 6.9, 8.1] { whoosh(at(.dashboard) + offset, 0.45, 0.12) }
        for offset in DemoFrame.tileClicks { click(at(.dashboard) + offset) }
        for part in [DemoVideo.Part.lid, .plug, .ports, .heat] { whoosh(at(part), 0.3, 0.22) }
        thud(at(.news) + 0.1)
        for offset in [0.6, 1.9, 3.2, 4.5] { chime(at(.heat) + offset) }
        click(at(.outcome) + 0.55)
        whoosh(at(.outcome) + 0.65, 0.45, 0.25)
        chime(at(.thesis) + 4.5)
        swell(at(.brand), 3.0)
        pop(at(.cta) + 0.8)
        for i in samples.indices { samples[i] = max(-0.9, min(0.9, samples[i])) }

        let folder = video.deletingLastPathComponent()
        let wav = folder.appendingPathComponent("sound.wav"), m4a = folder.appendingPathComponent("sound.m4a")
        let muxed = folder.appendingPathComponent("muxed.mp4")
        [wav, m4a, muxed].forEach { try? FileManager.default.removeItem(at: $0) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            try file.write(from: buffer)
        } catch { print("Sound failed: \(error)"); return }

        // WAV to AAC, then AAC next to the untouched video track.
        guard let toAAC = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A) else { return }
        try? await toAAC.export(to: m4a, as: .m4a)
        let composition = AVMutableComposition()
        let movie = AVURLAsset(url: video), sound = AVURLAsset(url: m4a)
        guard let duration = try? await movie.load(.duration),
              let picture = try? await movie.loadTracks(withMediaType: .video).first,
              let audio = try? await sound.loadTracks(withMediaType: .audio).first,
              let pictureTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { print("Sound: couldn't read the tracks"); return }
        let range = CMTimeRange(start: .zero, duration: duration)
        try? pictureTrack.insertTimeRange(range, of: picture, at: .zero)
        try? audioTrack.insertTimeRange(range, of: audio, at: .zero)
        guard let mux = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { return }
        do {
            try await mux.export(to: muxed, as: .mp4)
            _ = try FileManager.default.replaceItemAt(video, withItemAt: muxed)
        } catch { print("Sound: mux failed: \(error)") }
        [wav, m4a].forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
