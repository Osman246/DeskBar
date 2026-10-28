import AVFoundation
import CoreText
import SwiftUI

/// `DESKBAR_DEMO=1 DeskBar --snapshot <dir> --demo-video [--fonts <dir>]` renders a one-minute
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
    enum Part: CaseIterable { case hook, reveal, panel, interact, lid, plug, ports, news, heat, thesis, brand, cta, open }

    static let sequence: [Part] = [.hook, .reveal, .panel, .interact, .lid, .plug, .ports, .news, .heat, .thesis, .brand, .cta]
    static let size = CGSize(width: 1080, height: 1350)
    static let fps = 30.0
    static let lengths: [Part: Double] = [.hook: 2.75, .reveal: 5.65, .panel: 6.0, .interact: 4.6, .lid: 3.2, .plug: 4.2,
                                          .ports: 4.8, .news: 6.4, .heat: 6.0, .thesis: 5.2, .brand: 5.2, .cta: 6.0, .open: 0]
    static var total: Double { sequence.reduce(0) { $0 + lengths[$1]! } }
    /// When each part starts, for the sound track.
    static func start(of part: Part) -> Double { sequence.prefix { $0 != part }.reduce(0) { $0 + lengths[$1]! } }
    nonisolated(unsafe) static var serif = "Hoefler Text"   // set once before rendering
    nonisolated(unsafe) static var credit: String?
    nonisolated(unsafe) static var creditNote: String?

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
        print("Headlines in \(serif)")
        let mac = model.mac
        await mac.waitUntilLoaded()
        let clips = await record(mac)
        let images = FileManager.default.currentDirectoryPath + "/docs/images/"
        let shots = Shots(panel: NSImage(contentsOfFile: images + "panel-dark.png"),
                          memory: NSImage(contentsOfFile: images + "memory.png"),
                          battery: NSImage(contentsOfFile: images + "battery.png"))

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

    /// The real panel, as the screenshots in docs/images show it (closed, Memory open, Battery open).
    struct Shots {
        var panel: NSImage?
        var memory: NSImage?
        var battery: NSImage?
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
        clips[.lid] = await mac.recordClip(seconds: 3.2) { t in
            let angle = t < 0.3 ? 112 : t < 1.3 ? 112 - 77 * ease((t - 0.3) / 1.0) : t < 1.6 ? 35 : 35 + 77 * ease((t - 1.6) / 1.0)
            mac.simulateLid(angle)
        }

        // MagSafe goes in, then the monitors rise around it: power and desk in one beat.
        reset(base)
        var plugged = false, atDesk = false
        clips[.plug] = await mac.recordClip(seconds: 4.2) { t in
            if t > 0.4 && !plugged { plugged = true; mac.update(charging) }
            if t > 1.7 && !atDesk { atDesk = true; mac.update(desk); mac.setMode(.desk) }
        }

        reset(desk)
        var leftSide = false, rightSide = false
        clips[.ports] = await mac.recordClip(seconds: 4.8) { t in
            if !leftSide { leftSide = true; mac.setMode(.ports(.left)) }
            if t > 2.4 && !rightSide { rightSide = true; mac.setMode(.ports(.right)) }
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
            state.warning = ["Running hot", "Memory full", "Disk almost full", "Low battery"][next]
            if next == 3 { state.batteryPercent = 18 }
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

private struct DemoFrame: View {
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
    /// Scenes with a headline at the top and a chapter marker at the bottom.
    static let chapters: [DemoVideo.Part] = [.reveal, .panel, .interact, .lid, .plug, .ports, .heat]
    /// Parts that open on a hard cut: a white flash and a punch-in. The reveal carries straight on
    /// from the hook (the click opens the panel), so it doesn't cut.
    static let cuts: [DemoVideo.Part] = [.panel, .interact, .lid, .plug, .ports, .news, .heat, .thesis, .brand, .cta]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Group {
                switch part {
                case .hook: hook
                case .reveal: reveal
                case .panel: panelTour
                case .interact: interact
                case .thesis: thesis
                case .news: news
                case .brand: brand
                case .cta: callToAction
                default: EmptyView()
                }
                if Self.productParts.contains(part) { product }
                if Self.productParts.contains(part) || part == .panel || part == .interact { caption }
                if part == .heat { notifications }
                if Self.chapters.contains(part) { chapter }
            }
            .scaleEffect(punch, anchor: .center)
            menuBar
            cursor
            finish
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
        .clipped()
    }

    /// The zoom on a cut: starts 6% in and settles.
    private var punch: CGFloat {
        Self.cuts.contains(part) ? 1 + 0.06 * (1 - easeOut(local / 0.35)) : 1
    }

    /// Flash, vignette and the progress line, over everything.
    private var finish: some View {
        ZStack(alignment: .topLeading) {
            if Self.cuts.contains(part) {
                Color.white.opacity(0.32 * (1 - clamp(local / 0.12)))
            }
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 380, endRadius: 900)
            Rectangle().fill(Color.white.opacity(0.85))
                .frame(width: DemoVideo.size.width * t / DemoVideo.total, height: 3)
                .offset(y: DemoVideo.size.height - 3)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
        .allowsHitTesting(false)
    }

    // MARK: Hook

    /// Readable from the very first frame (feeds autoplay muted): the question, with the first of the
    /// four places you'd check today already on screen. They pile up, then fly into one menu bar item.
    private var hook: some View {
        ZStack(alignment: .topLeading) {
            Text("Is your Mac OK?")
                .font(serif(104))
                .tracking(-1.5)
                .foregroundStyle(.white)
                .frame(width: DemoVideo.size.width)
                .offset(y: 120)
                .opacity(1 - clamp((local - 2.3) / 0.3))
            clutter(local + 0.35)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    /// The places you'd check today: four windows, then all of them into the menu bar.
    private static let places: [(name: String, symbol: String, centre: CGPoint, angle: Double)] = [
        ("Activity Monitor", "waveform.path.ecg", CGPoint(x: 330, y: 560), -5),
        ("System Settings", "gearshape.fill", CGPoint(x: 740, y: 660), 4),
        ("Control Centre", "switch.2", CGPoint(x: 360, y: 860), 3),
        ("Battery menu", "battery.75percent", CGPoint(x: 720, y: 960), -4),
    ]

    private func clutter(_ t: Double) -> some View {
        let collapse = ease((t - 2.6) / 0.45)   // about two seconds with all four on screen
        return ZStack(alignment: .topLeading) {
            Text("TODAY YOU'D CHECK")
                .font(.system(size: 30, weight: .semibold)).tracking(10)
                .foregroundStyle(Color(white: 0.7))
                .frame(width: DemoVideo.size.width)
                .offset(y: 300)
                .opacity((1 - collapse))
            ForEach(Array(Self.places.enumerated()), id: \.offset) { i, place in
                placeWindow(place.name, place.symbol, pop: springy((t - 0.1 - Double(i) * 0.3) / 0.4))
                    .rotationEffect(.degrees(place.angle * (1 - collapse)))
                    .scaleEffect(1 - 0.94 * collapse)
                    .position(x: place.centre.x + (Self.itemCentre.x - place.centre.x) * collapse,
                              y: place.centre.y + (Self.itemCentre.y - place.centre.y) * collapse)
                    .opacity(1 - clamp((collapse - 0.85) / 0.15))
            }
            // The menu bar item lights up as they land.
            let land = clamp((t - 3.0) / 0.3)
            if land > 0 {
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

    // MARK: Menu bar and cursor

    private var menuBarShown: Double {
        switch part {
        case .hook: easeOut((local + 0.35 - 2.75) / 0.3)   // slides in as the windows fly up into it
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
        case .reveal: local > 0.24
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
        case .reveal where local < 1.6:
            let at = glide(CGPoint(x: 760, y: 420), Self.itemCentre, ease(local / 0.22))
            return (at, clicking(local - 0.24), Self.itemCentre)
        case .interact:
            let memory = Self.memoryTile, battery = Self.batteryTile
            if local < 2.4 {
                return (glide(CGPoint(x: 540, y: 1150), memory, ease((local - 0.3) / 0.6)), clicking(local - 0.95), memory)
            }
            return (glide(memory, battery, ease((local - 2.4) / 0.55)), clicking(local - 3.0), battery)
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
                    .opacity(part == .reveal ? 1 - clamp((local - 1.2) / 0.3) : 1 - leaving)
            }
            .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
        }
    }

    // MARK: Captions and chapters

    private var captionText: (kicker: String, headline: String, line: String) {
        switch part {
        case .reveal: ("One answer", "", "")
        case .panel: ("The panel", "Everything, *at a glance.*", "One panel, read top to bottom.")
        case .interact: ("Detail", "Detail *on request.*", "Click any tile to see what's behind it.")
        case .lid: ("Live", "It mirrors *your* Mac.", "Move the lid, and so does it.")
        case .plug: ("Power", "Plug in. *It knows.*", "Charger, monitors, the whole desk.")
        case .ports: ("Ports", "Every port, *labelled.*", "What's plugged in, and where.")
        case .heat: ("Alerts", "Warns you *early.*", "Heat, memory, disk and battery.")
        default: ("", "", "")
        }
    }

    private var caption: some View {
        let text = captionText
        return VStack(spacing: 14) {
            Headline(text: text.headline, size: 84, time: local - 0.08, leave: leaving)
            Text(text.line)
                .font(.system(size: 30))
                .foregroundStyle(Color(white: 0.58))
                .opacity(easeOut((local - 0.45) / 0.4) * (1 - leaving))
        }
        .frame(width: DemoVideo.size.width)
        .offset(y: 150)
    }

    /// "03 / 07  PORTS", like a chapter card in a film.
    private var chapter: some View {
        let steps = Self.chapters
        let number = (steps.firstIndex(of: part) ?? 0) + 1
        return HStack(spacing: 22) {
            Text(String(format: "%02d", number)).foregroundStyle(.white)
            Rectangle().fill(Color(white: 0.35)).frame(width: 60, height: 1.5)
            Text(String(format: "%02d", steps.count)).foregroundStyle(Color(white: 0.45))
            Text(captionText.kicker.uppercased()).tracking(7).foregroundStyle(Color(white: 0.55)).padding(.leading, 18)
        }
        .font(.system(size: 23, weight: .medium))
        .monospacedDigit()
        .frame(width: DemoVideo.size.width)
        .offset(y: 1210)
        .opacity(easeOut(local / 0.3) * (1 - leaving))
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
        .offset(x: stage.minX, y: stage.minY)
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
            .offset(y: Self.stage.maxY + 22)
            .opacity(easeOut(local / 0.3) * (1 - leaving))
        }
    }

    /// Rings on the ports and labels below, arriving one after another once the camera settles.
    private func portLabels(_ now: MacScene.ClipFrame) -> some View {
        let side: Ports.Side = local < 2.4 ? .left : .right
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

    /// DeskBar's real alerts, arriving one after another and stacking like Notification Centre.
    private static let alerts: [(at: Double, symbol: String, tint: Color, title: String, body: String)] = [
        (0.6, "thermometer.high", .orange, "Mac running hot", "macOS is slowing the chip down to cool it (95°C)."),
        (1.9, "memorychip", Color(red: 1, green: 0.72, blue: 0.2), "Memory full", "Apps may slow down. Safari is using 6.4 GB."),
        (3.2, "internaldrive", Color(red: 0.95, green: 0.36, blue: 0.24), "Disk almost full", "Only 8.6 GB free. Try Clean up in DeskBar."),
        (4.5, "battery.25percent", Color(red: 0.98, green: 0.42, blue: 0.4), "Battery low", "18% left, about 1h 5m."),
    ]

    private var notifications: some View {
        let alerts = Self.alerts
        return ZStack(alignment: .topLeading) {
            ForEach(Array(alerts.enumerated()), id: \.offset) { i, alert in
                // How far newer alerts have pushed this one back into the stack.
                let depth = alerts[(i + 1)...].reduce(0.0) { $0 + easeOut((local - $1.at) / 0.35) }
                notification(alert.symbol, alert.tint, alert.title, alert.body, arrival: springy((local - alert.at) / 0.5), depth: depth)
                    .zIndex(Double(i))
            }
        }
        .opacity(1 - leaving)
    }

    private func notification(_ symbol: String, _ tint: Color, _ title: String, _ body: String, arrival p: Double, depth: Double) -> some View {
        let x: CGFloat = Self.stage.maxX - 540 + 60 * (1 - p)
        let y: CGFloat = Self.stage.minY - 10 + 24 * depth
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
                Text(body).font(.system(size: 22)).foregroundStyle(Color(white: 0.8))
                    .lineLimit(2)
            }
            .opacity(1 - clamp(depth * 2))   // only the newest one's text shows
        }
        .padding(22)
        .frame(width: 540, height: 158, alignment: .topLeading)   // one height, so the stack lines up
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.17 - 0.03 * min(depth, 2))))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
        .scaleEffect(scale * (0.96 + 0.04 * p), anchor: .top)
        .offset(x: x, y: y)
        .opacity(clamp(p * 5) * (1 - clamp((depth - 2) / 0.6)))   // solid almost at once, so nothing shows through
    }

    // MARK: The real panel

    /// Where the Memory and Battery tiles land in the interaction shot, in canvas points.
    static let memoryTile = CGPoint(x: 289, y: 669)
    static let batteryTile = CGPoint(x: 791, y: 669)

    /// The click on the menu bar opens the real panel beneath it; then a slow zoom onto its verdict.
    private var reveal: some View {
        let k: CGFloat = 428 / 680                     // panel shown 428 points wide, under the menu bar item
        let origin = CGPoint(x: 612, y: 64)
        let drop = springy((local - 0.3) / 0.45)
        let zoom = ease((local - 2.7) / 0.8)
        // Once zoomed, only the top card stays: the rest of the panel fades out below it.
        let keep = 1 - (1 - 840 / DemoVideo.size.height) * zoom
        // Zoom so the panel's top card (the 3D Mac and its verdict) fills the middle of the frame.
        let focus = CGPoint(x: origin.x + 340 * k, y: origin.y + 230 * k)
        let scale: CGFloat = 1 + zoom
        let shift = CGSize(width: (540 - focus.x * 2) * zoom, height: (560 - focus.y * 2) * zoom)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if let panel = shots.panel {
                    Image(nsImage: panel).resizable()
                        .frame(width: 680 * k, height: 1746 * k)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.7), radius: 30, y: 12)
                        .scaleEffect(0.92 + 0.08 * drop, anchor: .top)
                        .offset(x: origin.x, y: origin.y - 24 * (1 - drop))
                        .opacity(clamp(drop * 2))
                }
            }
            .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(shift)
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: keep),
                                       .init(color: .clear, location: min(1, keep + 0.04))],
                               startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 16) {
                Kicker(text: "Introducing DeskBar", time: local - 0.5, size: 26)
                Headline(text: "One click.|*One answer.*", size: 84, time: local - 0.6, alignment: .leading)
                Text("“All good”, or the one\nthing that isn't.")
                    .font(.system(size: 32))
                    .foregroundStyle(Color(white: 0.62))
                    .opacity(easeOut((local - 1.2) / 0.4))
            }
            .offset(x: 60, y: 430)
            .opacity(1 - clamp((local - 2.5) / 0.3))
            VStack(spacing: 12) {
                Kicker(text: "The verdict comes first", time: local - 3.4, size: 28)
                Text("Health, heat and power, summed up in two words.")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(white: 0.62))
                    .opacity(easeOut((local - 3.6) / 0.4))
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 900)
            .opacity(1 - leaving)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    /// Sections of the panel screenshot (680 × 1746): their tops and bottoms, and what each is for.
    private static let sections: [(top: CGFloat, bottom: CGFloat, title: String, detail: String)] = [
        (20, 440, "A living 3D Mac", "With one verdict on top: “All good”, or what isn't."),
        (455, 630, "CPU, heat and fans", "Every core at a glance, with a short history."),
        (645, 880, "Memory, disk, battery", "Plus your Wi-Fi link and latency."),
        (900, 1270, "Network, sound, display", "Speed test, devices and smart alerts."),
        (1290, 1600, "Quick actions", "Focus, keep awake, lock and more."),
    ]

    /// The whole panel at a readable size, scrolled section by section, each one outlined and named.
    private var panelTour: some View {
        let k: CGFloat = 560 / 680
        let view = CGRect(x: 70, y: 360, width: 560, height: 800)
        let beat = 1.1, first = 0.45
        let i = min(max(Int((local - first) / beat), 0), Self.sections.count - 1)
        func scroll(_ index: Int) -> CGFloat {
            let section = Self.sections[index]
            let centre = (section.top + section.bottom) / 2
            return min(0, max(view.height - 1746 * k, view.height / 2 - centre * k))
        }
        let into = local - first - Double(i) * beat
        let move = i == 0 ? 1 : ease(into / 0.45)
        let y = scroll(max(i - 1, 0)) + (scroll(i) - scroll(max(i - 1, 0))) * move
        let section = Self.sections[i]
        let frameTop = view.minY + y + section.top * k
        let frameHeight = (section.bottom - section.top) * k
        let show = easeOut((into - 0.15) / 0.35)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if let panel = shots.panel {
                    Image(nsImage: panel).resizable()
                        .frame(width: view.width, height: 1746 * k)
                        .offset(y: y)
                }
            }
            .frame(width: view.width, height: view.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .offset(x: view.minX, y: view.minY)
            .opacity(easeOut(local / 0.4) * (1 - leaving))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: view.width - 8, height: frameHeight)
                .offset(x: view.minX + 4, y: frameTop)
                .opacity(show * (1 - leaving))
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: "%02d / %02d", i + 1, Self.sections.count))
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit().tracking(3)
                    .foregroundStyle(Color(white: 0.5))
                Text(section.title).font(serif(46)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(section.detail).font(.system(size: 27)).foregroundStyle(Color(white: 0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 370, alignment: .leading)
            .offset(x: 670 + 16 * (1 - show), y: min(max(frameTop + frameHeight / 2 - 90, 400), 980))
            .blur(radius: 8 * (1 - show))
            .opacity(show * (1 - leaving))
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    /// The pointer clicks Memory, then Battery, and the real panel opens each one.
    private var interact: some View {
        let k: CGFloat = 780 / 680
        let view = CGRect(x: 150, y: 380, width: 780, height: 820)
        let toMemory = easeOut((local - 1.05) / 0.25), toBattery = easeOut((local - 3.1) / 0.25)
        func shot(_ image: NSImage?, _ height: CGFloat) -> some View {
            Group {
                if let image {
                    Image(nsImage: image).resizable()
                        .frame(width: view.width, height: height * k)
                        .offset(y: -455 * k)
                }
            }
        }
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                shot(shots.panel, 1746)
                shot(shots.memory, 2144).opacity(toMemory * (1 - toBattery))
                shot(shots.battery, 2316).opacity(toBattery)
            }
            .frame(width: view.width, height: view.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .offset(x: view.minX, y: view.minY)
            .opacity(easeOut(local / 0.35) * (1 - leaving))
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    // MARK: Brand and download

    /// The brand moment: the wordmark over the 3D Mac opening, and what it does well.
    private var brand: some View {
        let mac = clips[.open].flatMap { clip in clip.last { $0.time <= local } ?? clip.first }
        return ZStack(alignment: .topLeading) {
            if let mac {
                Image(nsImage: mac.image).resizable()
                    .frame(width: Self.stage.width, height: Self.stage.height)
                    .scaleEffect(1.05 + 0.04 * local / length)
                    .offset(x: Self.stage.minX, y: 440)
            }
            VStack(spacing: 6) {
                Headline(text: "DeskBar.", size: 150, time: local - 0.3)
                Text("Your Mac, at a glance.")
                    .font(serif(46)).italic()
                    .foregroundStyle(Color(white: 0.68))
                    .opacity(easeOut((local - 0.8) / 0.45))
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 120)
            VStack(spacing: 14) {
                Text("ONE VERDICT  ·  A LIVE 3D MAC")
                Text("EVERY PORT LABELLED  ·  PRIVATE BY DESIGN")
            }
            .font(.system(size: 22, weight: .semibold)).tracking(5)
            .foregroundStyle(Color(white: 0.6))
            .frame(width: DemoVideo.size.width)
            .offset(y: 1110)
            .opacity(easeOut((local - 1.6) / 0.5))
        }
        .opacity(1 - leaving)
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    /// Where to get it, and who made it.
    private var callToAction: some View {
        let button = springy((local - 0.9) / 0.45)
        return VStack(spacing: 0) {
            Headline(text: "Get *DeskBar.*", size: 136, time: local - 0.1)
            Text("Free and open source for macOS.")
                .font(.system(size: 36))
                .foregroundStyle(Color(white: 0.7))
                .opacity(easeOut((local - 0.5) / 0.4))
                .padding(.top, 14)
            HStack(spacing: 16) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 38))
                Text("Get it free on GitHub").font(.system(size: 36, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 44).padding(.vertical, 24)
            .background(Capsule().fill(Color.white))
            .scaleEffect(0.8 + 0.2 * button)
            .opacity(clamp(button * 1.6))
            .padding(.top, 70)
            HStack(spacing: 10) {
                Text("Link in the comments")
                Image(systemName: "arrow.down").font(.system(size: 24, weight: .light))
                    .offset(y: 6 * sin(max(0, local - 1.6) * 6))
            }
            .font(.system(size: 30))
            .foregroundStyle(Color(white: 0.72))
            .opacity(easeOut((local - 1.5) / 0.4))
            .padding(.top, 28)
            Text("macOS 15 or later  ·  Apple silicon")
                .font(.system(size: 22, weight: .medium)).tracking(2)
                .foregroundStyle(Color(white: 0.45))
                .opacity(easeOut((local - 1.8) / 0.4))
                .padding(.top, 18)
            if let credit = DemoVideo.credit {
                Text(credit)
                    .font(serif(36)).italic()
                    .foregroundStyle(.white)
                    .opacity(easeOut((local - 2.4) / 0.5))
                    .padding(.top, 110)
            }
            if let note = DemoVideo.creditNote {
                Text(note)
                    .font(.system(size: 24))
                    .foregroundStyle(Color(white: 0.6))
                    .opacity(easeOut((local - 2.7) / 0.5))
                    .padding(.top, 10)
            }
            Text("RENDERED BY DESKBAR ITSELF")
                .font(.system(size: 16, weight: .semibold)).tracking(5)
                .foregroundStyle(Color(white: 0.38))
                .opacity(easeOut((local - 3.0) / 0.5))
                .padding(.top, DemoVideo.credit == nil ? 110 : 18)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }

    // MARK: Why it matters now

    /// Halfway through, the news that makes it timely (a change of pace that leads into the alerts),
    /// set as a clipping, then what DeskBar does about it.
    /// Reported by PBS NewsHour, 26 June 2026 (Apple announced it on the 25th): Apple raised Mac and
    /// iPad prices, blaming a memory chip shortage driven by AI; the 1 TB 14-inch MacBook Pro went
    /// from $1,699 to $1,999. The quote is Apple's written statement from that report.
    private var news: some View {
        let split = 4.4
        let second = local > split
        let into = second ? local - split : local
        let leave = second ? leaving : clamp((into - (split - 0.25)) / 0.22)
        return ZStack {
            if second {
                VStack(spacing: 34) {
                    Kicker(text: "What you can do", time: into - 0.05, size: 30)
                        .opacity(1 - leave)
                    Headline(text: "Know what's using your memory|*before you pay for more.*", size: 68, time: into - 0.1, leave: leave)
                        .frame(height: 200)
                    Text("DeskBar shows memory pressure, the apps behind it,\nand warns you before it's full.")
                        .font(.system(size: 30))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(white: 0.62))
                        .opacity(easeOut((into - 0.9) / 0.4) * (1 - leave))
                }
                Color.white.opacity(0.25 * (1 - clamp(into / 0.1)))   // a flash between the two beats
            } else {
                clipping(into: into)
                    .opacity(1 - leave)
                    .blur(radius: 12 * leave)
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }

    private static let ink = Color(red: 0.11, green: 0.1, blue: 0.09)
    private static let paper = Color(red: 0.96, green: 0.945, blue: 0.915)

    /// A newspaper pull-out: it drops in, the old price is struck through, Apple's own words get
    /// highlighted.
    private func clipping(into t: Double) -> some View {
        let drop = springy(t / 0.6)
        let angle: Double = -1.6 - 2.4 * (1 - drop)
        let scale: CGFloat = 0.9 + 0.1 * drop + 0.02 * t / 4.4
        let lift: CGFloat = 40 + 60 * (1 - drop)
        return VStack(alignment: .leading, spacing: 0) {
            clippingMasthead
            Text("Apple raises Mac prices, blaming an AI-driven memory shortage")
                .font(serif(62, .medium))
                .foregroundStyle(Self.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)
            priceRow(t)
                .padding(.top, 22)
            pullQuote(t)
                .padding(.top, 34)
            Text("Apple, in a statement reported by PBS NewsHour")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Self.ink.opacity(0.55))
                .padding(.top, 14)
        }
        .padding(.horizontal, 54).padding(.vertical, 46)
        .frame(width: 880, alignment: .leading)
        .background(Self.paper)
        .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
        .rotationEffect(.degrees(angle))
        .scaleEffect(scale)
        .offset(y: lift)
        .opacity(clamp(drop * 1.6))
    }

    private var clippingMasthead: some View {
        VStack(spacing: 0) {
            HStack {
                Text("IN THE NEWS").tracking(5)
                Spacer()
                Text("JUNE 2026").tracking(3)
            }
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(Self.ink.opacity(0.65))
            Rectangle().fill(Self.ink).frame(height: 3).padding(.top, 16)
            Rectangle().fill(Self.ink).frame(height: 1).padding(.top, 4)
        }
    }

    private func priceRow(_ t: Double) -> some View {
        let strike = easeOut((t - 1.0) / 0.35)
        let shown = easeOut((t - 1.25) / 0.3)
        let red = Color(red: 0.75, green: 0.12, blue: 0.08)
        return HStack(spacing: 18) {
            Text("14-inch MacBook Pro, 1 TB").font(.system(size: 28, weight: .medium)).foregroundStyle(Self.ink.opacity(0.7))
            Text("$1,699")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Self.ink.opacity(0.5))
                .overlay(alignment: .leading) {
                    Rectangle().fill(red).frame(height: 3).scaleEffect(x: strike, anchor: .leading)
                }
            Text("→ $1,999")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(red)
                .opacity(shown)
                .offset(x: 12 * (1 - shown))
        }
    }

    private func pullQuote(_ t: Double) -> some View {
        let sweep = ease((t - 1.8) / 0.8)
        return Text("“We have never seen a component price increase this much, this quickly.”")
            .font(serif(44)).italic()
            .foregroundStyle(Self.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(alignment: .leading) {
                Rectangle()
                    .fill(Color(red: 1, green: 0.86, blue: 0.35).opacity(0.75))
                    .scaleEffect(x: sweep, anchor: .leading)
            }
    }

    // MARK: The point of it

    /// What building it taught me: two lines, each with its own beat.
    private var thesis: some View {
        let lines = [
            ("Nobody wants a dashboard.|*They want one sentence.*", 76.0),
            ("AI made building cheap.|*Deciding what to build* is the job.", 72.0),
        ]
        let beat = 2.6
        let i = min(Int(local / beat), lines.count - 1)
        let into = local - Double(i) * beat
        let leave = i == lines.count - 1 ? leaving : clamp((into - (beat - 0.25)) / 0.22)
        return ZStack {
            VStack(spacing: 34) {
                Kicker(text: "What building it taught me", time: local - 0.1, size: 30)
                    .opacity(1 - leaving)
                Headline(text: lines[i].0, size: lines[i].1, time: into - 0.08, leave: leave)
                    .frame(height: 200)
            }
            if i > 0 { Color.white.opacity(0.25 * (1 - clamp(into / 0.1))) }   // a flash between lines
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
        for i in 1...3 { pop(at(.hook) + 0.3 * Double(i) - 0.25) }
        whoosh(at(.hook) + 2.25, 0.5, 0.5)
        click(at(.reveal) + 0.24)
        whoosh(at(.reveal) + 0.3, 0.35, 0.25)
        whoosh(at(.reveal) + 2.7, 0.8, 0.3)
        for part in [DemoVideo.Part.panel, .interact, .lid, .plug, .ports, .heat, .thesis] { whoosh(at(part), 0.3, 0.22) }
        click(at(.interact) + 0.95)
        click(at(.interact) + 3.0)
        thud(at(.news) + 0.15)
        for offset in [0.6, 1.9, 3.2, 4.5] { chime(at(.heat) + offset) }
        swell(at(.brand), 3.0)
        pop(at(.cta) + 0.95)
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
