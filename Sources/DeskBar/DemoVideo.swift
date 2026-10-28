import AVFoundation
import CoreText
import SwiftUI

/// `DESKBAR_DEMO=1 DeskBar --snapshot <dir> --demo-video [--fonts <dir>]` renders a one-minute
/// launch video (1080 × 1350, 30 fps) from the real 3D Mac, recorded live. Everything else
/// (captions, menu bar, cursor) is drawn here, cut like a short cinematic edit: black, serif
/// headlines. The first frame already reads, since feeds autoplay muted.
///
/// `--credit "Built by …"` adds a credit line to the end card.
///
/// The headlines use EB Garamond (SIL Open Font License) when its .ttf files are in the `--fonts`
/// directory, and macOS's Hoefler Text otherwise.
@MainActor
enum DemoVideo {
    enum Part: CaseIterable { case hook, menuBar, open, lid, plug, ports, desk, news, heat, actions, thesis, end }

    static let size = CGSize(width: 1080, height: 1350)
    static let fps = 30.0
    static let lengths: [Part: Double] = [.hook: 3.0, .news: 8.0, .menuBar: 2.2, .open: 3.6, .lid: 3.8, .plug: 4.0,
                                          .ports: 5.2, .desk: 3.6, .heat: 6.6, .actions: 3.0, .thesis: 8.9, .end: 4.4]
    static var total: Double { lengths.values.reduce(0, +) }
    nonisolated(unsafe) static var serif = "Hoefler Text"   // set once before rendering
    nonisolated(unsafe) static var credit: String?

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
        print("Headlines in \(serif)")
        let mac = model.mac
        await mac.waitUntilLoaded()
        let clips = await record(mac)

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
            let view = DemoFrame(t: t, clips: clips)
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
        clips[.lid] = await mac.recordClip(seconds: 3.8) { t in
            let angle = t < 0.4 ? 112 : t < 1.5 ? 112 - 77 * ease((t - 0.4) / 1.1) : t < 2.0 ? 35 : 35 + 77 * ease((t - 2.0) / 1.2)
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
        clips[.ports] = await mac.recordClip(seconds: 5.2) { t in
            if !leftSide { leftSide = true; mac.setMode(.ports(.left)) }
            if t > 2.4 && !rightSide { rightSide = true; mac.setMode(.ports(.right)) }
        }

        reset(desk)
        var atDesk = false
        clips[.desk] = await mac.recordClip(seconds: 3.6) { t in
            if t > 0.3 && !atDesk { atDesk = true; mac.setMode(.desk) }
        }

        // The screen and the status follow each alert as it arrives (times match `alerts`).
        reset(hot)
        var heated = false, shown = 0
        clips[.heat] = await mac.recordClip(seconds: 6.6) { t in
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

    private var current: (DemoVideo.Part, Double) { DemoVideo.part(at: t) }
    private var part: DemoVideo.Part { current.0 }
    private var local: Double { current.1 }
    private var length: Double { DemoVideo.lengths[part]! }
    private var leaving: Double { clamp((local - (length - 0.22)) / 0.22) }

    /// Where the 3D Mac sits.
    static let stage = CGRect(x: 60, y: 430, width: 960, height: 630)
    static let productParts: [DemoVideo.Part] = [.open, .lid, .plug, .ports, .desk, .heat]
    /// Parts that open on a hard cut: a white flash and a punch-in.
    /// The lid scene carries straight on from the opening (same shot), so it doesn't cut.
    static let cuts: [DemoVideo.Part] = [.news, .open, .plug, .ports, .desk, .heat, .actions, .thesis, .end]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Group {
                switch part {
                case .hook: hook
                case .menuBar: introducing
                case .actions: actions
                case .thesis: thesis
                case .news: news
                case .end: endCard
                default: EmptyView()
                }
                if Self.productParts.contains(part) { product }
                if Self.productParts.contains(part) || part == .actions { caption }
                if part == .heat { notifications }
                if Self.productParts.contains(part) || part == .actions { chapter }
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

    /// Readable from the very first frame (feeds autoplay muted): the question over the Mac, then a
    /// quick montage of the places you'd check today.
    private var hook: some View {
        let places = ["Activity Monitor.", "System Settings.", "Control Centre.", "The battery menu."]
        let montage = local - 1.4
        return ZStack(alignment: .topLeading) {
            if montage < 0 {
                if let mac = clips[.lid]?.first {
                    Image(nsImage: mac.image).resizable()
                        .frame(width: Self.stage.width, height: Self.stage.height)
                        .scaleEffect(1.3 + 0.04 * local)
                        .offset(x: Self.stage.minX, y: Self.stage.minY + 40)
                }
                Text("Is your Mac OK?")
                    .font(serif(112))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                    .frame(width: DemoVideo.size.width)
                    .offset(y: 170)
            } else {
                let step = 0.36
                let i = min(Int(montage / step), places.count - 1)
                let into = montage - Double(i) * step
                VStack(spacing: 26) {
                    Kicker(text: "Today you'd check", time: 1)
                    Text(places[i])
                        .font(serif(92))
                        .italic()
                        .foregroundStyle(.white)
                        .scaleEffect(1.08 - 0.08 * easeOut(into / 0.3))
                }
                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
                .opacity(1 - clamp((montage - 1.42) / 0.15))
                Color.white.opacity(0.22 * (1 - clamp(into / 0.08)))   // a flash on every word
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    // MARK: Menu bar and cursor

    private var introducing: some View {
        VStack(spacing: 22) {
            Kicker(text: "Introducing", time: local - 0.1)
            Headline(text: "DeskBar.", size: 150, time: local - 0.25, leave: leaving)
            Text("It lives in your menu bar.")
                .font(.system(size: 32))
                .foregroundStyle(Color(white: 0.6))
                .opacity(easeOut((local - 0.7) / 0.4) * (1 - leaving))
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }

    private var menuBarShown: Double {
        switch part {
        case .hook: 0
        case .menuBar: easeOut(local / 0.35)
        case .end: 1 - ease(local / 0.4)
        default: 1
        }
    }

    /// The DeskBar item, in canvas points.
    static let itemCentre = CGPoint(x: 626, y: 28)

    private var panelOpen: Bool {
        switch part {
        case .hook, .end: false
        case .menuBar: local > 1.3
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
            Text(Date.now.formatted(.dateTime.weekday(.abbreviated).hour().minute()))   // matches the 3D Mac's screen
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

    private var cursorPoint: CGPoint? {
        let start = CGPoint(x: 540, y: 1000), end = Self.itemCentre
        switch part {
        case .menuBar:
            let p = ease((local - 0.45) / 0.75)
            return CGPoint(x: start.x + (end.x - start.x) * p + 10, y: start.y + (end.y - start.y) * p + 6)
        case .open where local < 0.6:
            return CGPoint(x: end.x + 10, y: end.y + 6)
        default: return nil
        }
    }

    @ViewBuilder private var cursor: some View {
        if let point = cursorPoint {
            let click = part == .menuBar ? clamp((local - 1.25) / 0.45) : 1
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
                    .frame(width: 36, height: 53)
                    .scaleEffect(click > 0 && click < 0.25 ? 0.85 : 1, anchor: .topLeading)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .offset(x: point.x, y: point.y)
                    .opacity(part == .open ? 1 - clamp((local - 0.35) / 0.25) : 1)
            }
        }
    }

    // MARK: Captions and chapters

    private var captionText: (kicker: String, headline: String, line: String) {
        switch part {
        case .open: ("One answer", "One click. *One answer.*", "All good, or the one thing that isn't.")
        case .lid: ("Live", "It mirrors *your* Mac.", "Move the lid, and so does it.")
        case .plug: ("Power", "Plug in. *It knows.*", "MagSafe, charge level, charger speed.")
        case .ports: ("Ports", "Every port, *labelled.*", "What's plugged in, and where.")
        case .desk: ("Desk", "Your whole *desk.*", "Monitors appear as you connect them.")
        case .heat: ("Alerts", "Warns you *early.*", "Heat, memory, disk and battery.")
        case .actions: ("Actions", "One tap, *done.*", "Focus, keep awake, lock and more.")
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
        let steps: [DemoVideo.Part] = [.open, .lid, .plug, .ports, .desk, .heat, .actions]
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
        let shownPills = part == .open ? [HeroPill(text: "All good", color: .green)] : pills
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
            .opacity((part == .open ? easeOut((local - 2.1) / 0.4) : easeOut(local / 0.3)) * (1 - leaving))
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

    // MARK: Quick actions

    private var actions: some View {
        let items: [(String, String)] = [("Focus", "moon.fill"), ("Awake", "cup.and.saucer.fill"), ("Hide desk", "eye.slash.fill"),
                                         ("Mute mic", "mic.slash.fill"), ("Display off", "display"), ("Capture", "camera.viewfinder"),
                                         ("Clean up", "arrow.down.circle"), ("Lock", "lock.fill")]
        let focusOn = local > 1.55
        let tap = clamp((local - 1.4) / 0.35)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let p = springy((local - 0.15 - Double(i) * 0.05) / 0.4)
                let on = i == 0 && focusOn
                VStack(spacing: 18) {
                    Circle()
                        .fill(on ? Color.white : Color.white.opacity(0.08))
                        .overlay(Circle().strokeBorder(Color.white.opacity(on ? 0 : 0.14), lineWidth: 1.5))
                        .frame(width: 150, height: 150)
                        .overlay(Image(systemName: item.1).font(.system(size: 52, weight: .regular)).foregroundStyle(on ? Color.black : Color.white))
                        .scaleEffect(i == 0 && tap > 0 && tap < 1 ? 1 - 0.12 * sin(tap * .pi) : 1)
                    Text(item.0).font(.system(size: 27, weight: .medium)).foregroundStyle(Color(white: on ? 1 : 0.7))
                }
                .frame(width: 230)
                .scaleEffect(0.4 + 0.6 * p)
                .opacity(clamp(p * 1.5) * (1 - leaving))
                .offset(x: 80 + CGFloat(i % 4) * 230, y: 470 + CGFloat(i / 4) * 290)
            }
            Text("Focus on.")
                .font(.system(size: 30))
                .foregroundStyle(Color(white: 0.7))
                .frame(width: DemoVideo.size.width)
                .offset(y: 1090)
                .opacity(easeOut((local - 1.65) / 0.3) * (1 - leaving))
        }
    }

    // MARK: Why it matters now

    /// Halfway through, the news that makes it timely (a change of pace that leads into the alerts),
    /// set as a clipping, then what DeskBar does about it.
    /// Reported by PBS NewsHour, 26 June 2026 (Apple announced it on the 25th): Apple raised Mac and
    /// iPad prices, blaming a memory chip shortage driven by AI; the 1 TB 14-inch MacBook Pro went
    /// from $1,699 to $1,999. The quote is Apple's written statement from that report.
    private var news: some View {
        let split = 5.2
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
        let scale: CGFloat = 0.9 + 0.1 * drop + 0.02 * t / 5.2
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

    /// What building it taught me: three lines, each with its own beat.
    private var thesis: some View {
        let lines = [
            ("The most valuable 24 pixels|on a Mac *are in the menu bar.*", 70.0),
            ("Nobody wants a dashboard.|*They want one sentence.*", 76.0),
            ("AI made building cheap.|*Deciding what to build* is the job.", 72.0),
        ]
        let beat = 2.95
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

    // MARK: End card

    private var endCard: some View {
        VStack(spacing: 0) {
            Headline(text: "DeskBar.", size: 160, time: local - 0.1)
            Text("Your Mac, at a glance.")
                .font(serif(46)).italic()
                .foregroundStyle(Color(white: 0.65))
                .blur(radius: 10 * (1 - easeOut((local - 0.45) / 0.45)))
                .opacity(easeOut((local - 0.45) / 0.45))
                .padding(.top, 6)
            Text("FREE  ·  OPEN SOURCE  ·  PRIVATE BY DESIGN")
                .font(.system(size: 20, weight: .semibold)).tracking(5)
                .foregroundStyle(Color(white: 0.55))
                .opacity(easeOut((local - 0.9) / 0.45))
                .padding(.top, 44)
            Headline(text: "What should it|show *next?*", size: 76, time: local - 1.4)
                .padding(.top, 120)
            HStack(spacing: 12) {
                Text("Tell me in the comments. The link's there too.")
                Image(systemName: "arrow.down").font(.system(size: 26, weight: .light))
                    .offset(y: 6 * sin(max(0, local - 2.3) * 6))
            }
            .font(.system(size: 30))
            .foregroundStyle(Color(white: 0.7))
            .opacity(easeOut((local - 2.3) / 0.4))
            .padding(.top, 40)
            if let credit = DemoVideo.credit {
                Text(credit)
                    .font(serif(36)).italic()
                    .foregroundStyle(.white)
                    .opacity(easeOut((local - 2.7) / 0.5))
                    .padding(.top, 90)
            }
            Text("RENDERED BY DESKBAR ITSELF")
                .font(.system(size: 16, weight: .semibold)).tracking(5)
                .foregroundStyle(Color(white: 0.38))
                .opacity(easeOut((local - 3.0) / 0.5))
                .padding(.top, DemoVideo.credit == nil ? 110 : 18)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
        .offset(y: 40)
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
