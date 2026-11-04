import SwiftUI

// MARK: - Acted out (--v6)

/// The 26-second cut, shown rather than read: the pointer clicks, the answer lands, a problem appears
/// and is fixed in one click; then each old design shrinks away as the new one grows in its place.
extension DemoFrame {
    // Timing of the opening (seconds into .open6).
    static let v6MenuClick = 0.6, v6WarnAt = 2.3, v6QuitClick = 4.0
    /// Where the memory-full panel's stage sits in the opening (its Quit Safari button is clicked).
    static let v6StageFraming = Framing.fit(0, 384, centreY: 860, maxHeight: 470)
    static let v6CalmFraming = Framing.fit(6, 306, centreY: 860, maxHeight: 470)

    // Timing of each change (seconds into its beat).
    static let v6Beat = 3.6, v6Morph = 1.3, v6NewIn = 1.75
    static let v6RowFraming = Framing.fit(300, 478, centreY: 780, maxHeight: 560, maxWidth: 1000)
    static let v6TodayFraming = Framing.fit(470, 808, centreY: 780, maxHeight: 560, maxWidth: 1000)

    /// The bottom edge of each change's new design, so its lesson sits right under it.
    static func v6NewBottom(_ i: Int, _ local: Double) -> CGFloat {
        switch i {
        case 0: return DemoVideo.size.height / 2 + 189
        case 1: return v6RowFraming.rect.maxY
        case 2: return v6DetailFraming(local).rect.maxY
        default: return v6TodayFraming.rect.maxY
        }
    }

    static func v6Warning(_ part: DemoVideo.Part, _ local: Double) -> Bool {
        DemoVideo.v6 && part == .open6 && local >= v6WarnAt && local < v6QuitClick + 0.15
    }

    static func v6WarningGlow(_ part: DemoVideo.Part, _ local: Double) -> Double {
        guard v6Warning(part, local) else { return 0 }
        return 0.25 + 0.2 * sin((local - v6WarnAt) * 9)
    }

    /// The menu bar item shakes once when the warning arrives.
    static func v6Shake(_ part: DemoVideo.Part, _ local: Double) -> CGFloat {
        guard DemoVideo.v6, part == .open6, local >= v6WarnAt, local < v6WarnAt + 0.7 else { return 0 }
        let t = local - v6WarnAt
        return CGFloat(sin(t * 44) * 9 * exp(-t * 6))
    }

    /// The Memory beat's click on the stats row: where, and when (seconds into .changes6).
    static func v6DetailPointer(_ local: Double) -> (CGPoint, Double) {
        let click = 2 * v6Beat + v6NewIn + 0.6
        return (v6DetailFraming(local).point(v2MemoryTile.x, v2MemoryTile.y), click)
    }

    static func v6DetailClickActive(_ local: Double) -> Bool {
        let click = v6DetailPointer(local).1
        return local > click - 0.7 && local < click + 0.8
    }

    /// The new stats row, growing down as Memory opens.
    static func v6DetailFraming(_ local: Double) -> Framing {
        let click = 2 * v6Beat + v6NewIn + 0.6
        let open = v6ease((local - click - 0.08) / 0.45)
        return Framing.fit(300, 478 + (768 - 478) * CGFloat(open), centreY: 820, maxHeight: 640, maxWidth: 1000)
    }

    private static func v6ease(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private var v6Local: Double { DemoVideo.part(at: t).1 }
    private var v6Leaving: Double {
        let (part, local) = DemoVideo.part(at: t)
        let length = DemoVideo.lengths[part] ?? 1
        return min(max((local - (length - 0.22)) / 0.22, 0), 1)
    }
    private func v6in(_ x: Double) -> Double { 1 - pow(1 - min(max(x, 0), 1), 3) }
    /// A spring with a little overshoot, for things landing.
    private func v6spring(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return 1 - pow(2, -9 * x) * cos(x * 7.5)
    }
    private func v6rows(_ image: NSImage?, _ fallback: CGFloat) -> CGFloat {
        CGFloat(image?.representations.first?.pixelsHigh ?? Int(fallback))
    }

    /// A stretch of a screenshot, as a rounded card.
    private func v6card(_ image: NSImage?, _ height: CGFloat, _ f: Framing, glow: Double = 0) -> some View {
        let rect = f.rect
        return ZStack(alignment: .topLeading) {
            if let image {
                Image(nsImage: image).resizable().frame(width: 680 * f.scale, height: height * f.scale)
                    .offset(x: f.x, y: f.y - f.top * f.scale)
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
        .mask {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1 + 0.6 * glow), lineWidth: 1.5 + 3 * glow)
                .shadow(color: Color.green.opacity(0.45 * glow), radius: 40 * glow)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    // MARK: The opening: the answer, acted out

    var open6: some View {
        let local = v6Local, leave = v6Leaving
        let drop = v6spring((local - Self.v6MenuClick - 0.05) / 0.5)
        let stamp = v6spring((local - Self.v6MenuClick - 0.35) / 0.45)
        let warn = v6in((local - Self.v6WarnAt) / 0.25)
        let fixed = v6in((local - Self.v6QuitClick - 0.25) / 0.3)
        let phase = local < Self.v6WarnAt ? 0 : local < Self.v6QuitClick + 0.25 ? 1 : 2
        let jolt = local >= Self.v6WarnAt && local < Self.v6WarnAt + 0.5
            ? CGFloat(sin((local - Self.v6WarnAt) * 40) * 10 * exp(-(local - Self.v6WarnAt) * 7)) : 0
        let sweep = (local - Self.v6QuitClick - 0.05) / 0.5
        return ZStack(alignment: .topLeading) {
            // The question stays; the answer under it changes.
            VStack(spacing: 6) {
                Text("Is your Mac OK?").font(.custom(DemoVideo.serif, size: 84)).foregroundStyle(.white)
                ZStack {
                    HStack(spacing: 18) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 88)).foregroundStyle(Color.green)
                            .scaleEffect(0.4 + 0.6 * stamp)
                        Text("All good.").font(.custom(DemoVideo.serif, size: 132)).foregroundStyle(.white)
                    }
                    .scaleEffect(1.25 - 0.25 * stamp)
                    .opacity(min(stamp * 2, 1) * (phase == 0 ? 1 : 0))
                    VStack(spacing: 0) {
                        Text("Or the one thing").font(.custom(DemoVideo.serif, size: 84)).foregroundStyle(.white)
                        Text("that isn't.").font(.custom(DemoVideo.serif, size: 84)).italic().foregroundStyle(Color.orange)
                    }
                    .opacity(phase == 1 ? warn : 0)
                    .scaleEffect(phase == 1 ? 0.9 + 0.1 * warn : 1)
                    HStack(spacing: 18) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 80)).foregroundStyle(Color.green)
                            .scaleEffect(0.4 + 0.6 * v6spring((local - Self.v6QuitClick - 0.35) / 0.45))
                        Text("One click. ").font(.custom(DemoVideo.serif, size: 96)).foregroundStyle(.white)
                            + Text("All good.").font(.custom(DemoVideo.serif, size: 96)).italic().foregroundStyle(.white)
                    }
                    .opacity(phase == 2 ? fixed : 0)
                }
                .frame(height: 230)
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 120)
            .opacity(1 - leave)
            // The real panel: dropping in, then the warning, then fixed.
            v6card(shots.panel, v6rows(shots.panel, 1142), Self.v6CalmFraming, glow: phase == 2 ? 1 - min(max((local - Self.v6QuitClick - 0.6) / 0.9, 0), 1) : 0)
                .offset(y: -60 * (1 - drop))
                .opacity(min(drop * 2, 1) * (phase == 1 ? 1 - warn : 1) * (phase == 2 ? fixed : 1) * (1 - leave))
            v6card(shots.alertPanel, v6rows(shots.alertPanel, 1222), Self.v6StageFraming)
                .offset(x: jolt)
                .opacity(phase == 1 ? warn : phase == 2 ? 1 - fixed : 0)
                .overlay {
                    // Quit Safari pressed, then a green sweep across the card.
                    if phase >= 1 && local >= Self.v6QuitClick {
                        let r = Self.v6StageFraming.rect
                        let b = Self.v6StageFraming.point(32, 297), e = Self.v6StageFraming.point(204, 352)
                        Capsule().fill(Color.white.opacity(0.35 * (1 - min(max((local - Self.v6QuitClick) / 0.25, 0), 1))))
                            .frame(width: e.x - b.x, height: e.y - b.y)
                            .offset(x: b.x, y: b.y)
                            .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
                        if sweep > 0 && sweep < 1 {
                            LinearGradient(colors: [.clear, Color.green.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 260, height: r.height)
                                .offset(x: r.minX - 260 + (r.width + 260) * CGFloat(sweep), y: r.minY)
                                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
                                .mask {
                                    RoundedRectangle(cornerRadius: 24).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                                        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
                                }
                        }
                    }
                }
                .opacity(1 - leave)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    // MARK: The changes: the old one morphs into the new

    var changes6: some View {
        let local = v6Local
        let i = min(3, Int(local / Self.v6Beat))
        let beat = local - Double(i) * Self.v6Beat
        let out = i < 3 ? min(max((beat - (Self.v6Beat - 0.22)) / 0.22, 0), 1) : v6Leaving
        let items: [(feedback: String, lesson: String)] = [
            ("“39° in the menu bar isn't useful.”", "Quiet when fine. *Speaks when it isn't.*"),
            ("“There's a lot to take in.”", "Colour should mean *one thing.*"),
            ("“Two clicks is fine.”", "Detail in plain words, *one click away.*"),
            ("New: what happened today", "Report the day, *not just the moment.*"),
        ]
        let item = items[i]
        // The old shrinks up and away while the new grows out of the same spot.
        let shrink = v6in((beat - Self.v6Morph) / 0.4)
        let grow = v6spring((beat - Self.v6Morph - 0.1) / 0.5)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 8) {
                Text("\(i + 1) / 4  ·  FEEDBACK AFTER LAUNCH")
                    .font(.system(size: 22, weight: .bold)).tracking(4).foregroundStyle(Color(white: 0.55))
                Text(item.feedback).font(.custom(DemoVideo.serif, size: 50)).italic().foregroundStyle(Color(white: 0.88))
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 96)
            .opacity(v6in(beat / 0.25) * (1 - out))
            // Big, unmissable tags: what it was, then what it is.
            ZStack {
                let before = v6spring(beat / 0.45), now = v6spring((beat - Self.v6Morph - 0.25) / 0.45)
                v6tag("Before", "1.0", now: false)
                    .scaleEffect((0.6 + 0.4 * before) * (1 - 0.3 * shrink))
                    .opacity(min(before * 1.6, 1) * (1 - min(shrink * 2.5, 1)))
                v6tag("Now", "1.1", now: true)
                    .scaleEffect(0.6 + 0.4 * now)
                    .opacity(min(max(now * 1.6, 0), 1) * (1 - out))
            }
            .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
            .offset(y: -240)
            // Before: shrinks up and fades.
            v6old(i)
                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
                .scaleEffect(1 - 0.6 * shrink)
                .offset(y: -40 * CGFloat(shrink))
                .opacity(v6in(beat / 0.25) * (1 - shrink))
            // Now: grows out of the same spot (the menu bar's two states one after the other).
            v6new(i, local, beat)
                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
                .scaleEffect(i == 0 || i == 3 ? 1 : 0.4 + 0.6 * grow)
                .opacity((i == 0 || i == 3 ? 1 : min(max(grow * 1.6, 0), 1)) * (1 - out))
            // The lesson, right under the new design (following it down as Memory opens).
            Headline(text: item.lesson, size: 58, time: beat - Self.v6Morph - 0.3, leave: out)
                .frame(width: DemoVideo.size.width)
                .offset(y: Self.v6NewBottom(i, local) + 40)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    @ViewBuilder private func v6old(_ i: Int) -> some View {
        switch i {
        case 0: v6menuItem("thermometer.medium", "39°", caption: nil)
        case 1: v6card(shots.beforePanel, v6rows(shots.beforePanel, 1746), Framing.fit(447, 795, centreY: 780, maxHeight: 560, maxWidth: 1000))
        case 2: v6card(shots.beforeMemory, v6rows(shots.beforeMemory, 2144), Framing.fit(796, 1180, centreY: 780, maxHeight: 560, maxWidth: 1000))
        default:
            Text("Not there.").font(.custom(DemoVideo.serif, size: 80)).italic().foregroundStyle(Color(white: 0.5))
                .offset(y: 60)
        }
    }

    @ViewBuilder private func v6new(_ i: Int, _ local: Double, _ beat: Double) -> some View {
        switch i {
        case 0:
            let first = v6spring((beat - Self.v6Morph - 0.1) / 0.5), second = v6spring((beat - Self.v6Morph - 0.3) / 0.5)
            VStack(spacing: 30) {
                v6menuItem("macbook", "", caption: "all good")
                    .scaleEffect(0.3 + 0.7 * first).opacity(min(max(first * 1.6, 0), 1))
                v6menuItem("exclamationmark.triangle", "Memory full", caption: "a problem")
                    .scaleEffect(0.3 + 0.7 * second).opacity(min(max(second * 1.6, 0), 1))
            }
        case 1: v6card(shots.panel, v6rows(shots.panel, 1142), Self.v6RowFraming)
        case 2:
            let f = Self.v6DetailFraming(local)
            let open = Self.v6ease((local - Self.v6DetailPointer(local).1 - 0.08) / 0.45)
            v6card(shots.panel, v6rows(shots.panel, 1142), f)
                .overlay {
                    v6card(shots.memory, v6rows(shots.memory, 1532), f).opacity(open > 0 ? 1 : 0)
                }
        default:
            // The day's report writes itself out, top to bottom.
            let f = Self.v6TodayFraming, r = f.rect
            let written = Self.v6ease((beat - Self.v6Morph - 0.05) / 0.9)
            v6card(shots.panel, v6rows(shots.panel, 1142), f)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: DemoVideo.size.width, height: max(0, r.minY - 6 + (r.height + 12) * CGFloat(written)))
                }
        }
    }

    private func v6tag(_ word: String, _ version: String, now: Bool) -> some View {
        HStack(spacing: 14) {
            if now { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green) }
            Text(word).foregroundStyle(now ? Color.white : Color(white: 0.75))
            Text(version).foregroundStyle(Color(white: now ? 0.75 : 0.5))
        }
        .font(.system(size: 46, weight: .semibold))
        .padding(.horizontal, 34).frame(height: 84)
        .background(Capsule().fill(now ? Color.green.opacity(0.2) : Color.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(now ? Color.green.opacity(0.7) : Color.white.opacity(0.2), lineWidth: 2))
    }

    private func v6menuItem(_ symbol: String, _ text: String, caption: String?) -> some View {
        HStack(spacing: 30) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                if !text.isEmpty { Text(text) }
            }
            .font(.system(size: 64, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 40).frame(height: 124)
            .background(RoundedRectangle(cornerRadius: 26).fill(Color.white.opacity(0.13)))
            .frame(width: caption == nil ? nil : 520, alignment: .trailing)
            if let caption {
                Text(caption).font(.system(size: 34, weight: .medium)).foregroundStyle(Color(white: 0.8))
                    .lineLimit(1).fixedSize()
                    .frame(width: 260, alignment: .leading)
            }
        }
        .offset(y: 50)
    }

    // MARK: How it shipped, as a pipeline

    /// The six steps as a delivery pipeline: a pulse runs down the line and each step passes as it arrives.
    /// Testing holds the pulse until it passes; Ship then goes live.
    static let v6StepReached: [Double] = [0.45, 0.8, 1.15, 2.25, 2.6, 2.95]
    static let v6StepPassed: [Double] = [0.45, 0.8, 1.9, 2.25, 2.6, 2.95]

    var process6: some View {
        let local = v6Local, leave = v6Leaving
        let steps = ["Scope", "Build", "Test on real data", "Ship", "Measure", "Improve"]
        let x: CGFloat = 300, top: CGFloat = 380, gap: CGFloat = 118
        let moves: [(Double, Double)] = [(0.5, 0.8), (0.85, 1.15), (1.95, 2.25), (2.3, 2.6), (2.65, 2.95)]
        let y = top + gap * CGFloat(moves.map { v6in((local - $0.0) / ($0.1 - $0.0)) }.reduce(0, +))
        let checking = local >= Self.v6StepReached[2] && local < Self.v6StepPassed[2]
        return ZStack(alignment: .topLeading) {
            Headline(text: "How it *shipped.*", size: 88, time: local + 0.3, leave: leave)
                .frame(width: DemoVideo.size.width)
                .offset(y: 150)
            // The line, filling green behind the pulse.
            Capsule().fill(Color.white.opacity(0.15)).frame(width: 6, height: gap * 5).offset(x: x - 3, y: top)
            Capsule().fill(Color.green).frame(width: 6, height: y - top).offset(x: x - 3, y: top)
            ForEach(0..<6, id: \.self) { n in
                let ny = top + gap * CGFloat(n)
                let passed = local >= Self.v6StepPassed[n]
                let bump = passed ? sin(.pi * min(max((local - Self.v6StepPassed[n]) / 0.3, 0), 1)) : 0
                ZStack {
                    Circle().fill(passed ? Color.green : Color(white: 0.11))
                    Circle().strokeBorder(passed ? Color.green : Color(white: 0.3), lineWidth: 4)
                    if passed { Image(systemName: "checkmark").font(.system(size: 22, weight: .heavy)).foregroundStyle(.black) }
                }
                .frame(width: 48, height: 48)
                .scaleEffect(1 + 0.25 * bump)
                .offset(x: x - 24, y: ny - 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 16) {
                        Text(String(format: "%02d", n + 1)).font(.system(size: 28, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color(white: 0.5))
                        Text(steps[n]).font(.system(size: 46, weight: .medium)).foregroundStyle(.white)
                        if n == 3 {
                            let live = v6spring((local - Self.v6StepPassed[3] - 0.05) / 0.4)
                            Text("live").font(.system(size: 28, weight: .bold)).foregroundStyle(.black)
                                .padding(.horizontal, 18).frame(height: 44)
                                .background(Capsule().fill(Color.green))
                                .scaleEffect(0.5 + 0.5 * live).opacity(min(max(live * 1.6, 0), 1))
                        }
                    }
                    if n == 2 {
                        let pass = v6spring((local - Self.v6StepPassed[2]) / 0.4)
                        ZStack(alignment: .leading) {
                            Text("checking…").foregroundStyle(Color(white: 0.6)).opacity(checking ? 1 : 0)
                            Label("passed", systemImage: "checkmark").foregroundStyle(Color.green)
                                .scaleEffect(0.6 + 0.4 * pass, anchor: .leading).opacity(passed ? 1 : 0)
                        }
                        .font(.system(size: 28, weight: .semibold))
                        .padding(.leading, 50)
                    }
                }
                .fixedSize()
                .opacity((0.3 + 0.7 * v6in((local - Self.v6StepReached[n] + 0.05) / 0.2)) * (1 - leave))
                .offset(x: x + 50, y: ny - 30)
            }
            // The pulse, and the spinner while it waits on the test.
            Circle().fill(Color.green).frame(width: 26, height: 26).shadow(color: Color.green.opacity(0.8), radius: 16)
                .offset(x: x - 13, y: y - 13)
                .opacity(local >= 0.4 ? 1 - v6in((local - 3.05) / 0.2) : 0)
            Circle().trim(from: 0, to: 0.28).stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(local * 720))
                .offset(x: x - 38, y: top + gap * 2 - 38)
                .opacity(checking ? 1 : 0)
            Text("Every release tested on real data before it went live.")
                .font(.system(size: 30)).foregroundStyle(Color(white: 0.72))
                .frame(width: DemoVideo.size.width)
                .offset(y: 1110)
                .opacity(v6in((local - 3.1) / 0.35) * (1 - leave))
        }
        .opacity(1 - leave)
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }
}
