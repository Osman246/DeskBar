import SwiftUI

// MARK: - Before and after (--v4)

/// Five changes, each with v1.0 on top and 1.1 below, both held long enough to read: the feedback
/// that led to it, the lesson, and the skill it shows. Then how it shipped.
extension DemoFrame {
    static var pairBeat: Double { DemoVideo.v5 ? 3.1 : 3.7 }
    /// "Now" arrives a beat after "Before", so each is read on its own first.
    static var nowDelay: Double { DemoVideo.v5 ? 0.7 : 0.8 }

    enum Change { case icon, answer, colour, detail, today }
    /// The 22 s cut opens on the answer itself, so its changes skip the answer beat.
    static var changes: [Change] { DemoVideo.v5 ? [.icon, .colour, .detail, .today] : [.icon, .answer, .colour, .detail, .today] }
    /// Bands of the frame: before on top, now below.
    static let beforeBand = (centre: CGFloat(480), height: CGFloat(390))
    static let nowBand = (centre: CGFloat(950), height: CGFloat(390))

    private static func rows(_ image: NSImage?, _ fallback: CGFloat) -> CGFloat {
        CGFloat(image?.representations.first?.pixelsHigh ?? Int(fallback))
    }

    /// Local time and fade-out for the before-and-after parts (DemoFrame's own are private).
    private var beatLocal: Double { DemoVideo.part(at: t).1 }
    private var beatLeaving: Double {
        let (part, local) = DemoVideo.part(at: t)
        let length = DemoVideo.lengths[part] ?? 1
        return min(max((local - (length - 0.22)) / 0.22, 0), 1)
    }

    private func fadeIn(_ x: Double) -> Double { 1 - pow(1 - min(max(x, 0), 1), 3) }
    private func pop(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return 1 - pow(2, -9 * x) * cos(x * 7.5)
    }

    /// The poster frame: what this is, with before and after already on screen.
    var intro4: some View {
        let leave = beatLeaving
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 18) {
                Text("DESKBAR · ONE WEEK AFTER LAUNCH")
                    .font(.system(size: 26, weight: .semibold)).tracking(7)
                    .foregroundStyle(Color(white: 0.6))
                Headline(text: "Before → *now.*", size: 112, time: beatLocal + 1, leave: leave)
                Text("Five changes, from launch data and feedback.")
                    .font(.system(size: 34)).foregroundStyle(Color(white: 0.7))
                    .opacity(1 - leave)
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 150)
            beforeAfterLabel("BEFORE · 1.0", y: 590).opacity(1 - leave)
            framedShot(shots.beforeAlert, Self.rows(shots.beforeAlert, 1746), Framing.fit(14, 446, centreY: 790, maxHeight: 300))
                .opacity(0.9 * (1 - leave))
            beforeAfterLabel("NOW · 1.1", y: 950, bright: true).opacity(1 - leave)
            framedShot(shots.alertPanel, Self.rows(shots.alertPanel, 1222), Framing.fit(0, 384, centreY: 1140, maxHeight: 300))
                .opacity(1 - leave)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    var pairs: some View {
        let local = beatLocal
        let changes = Self.changes
        let i = min(changes.count - 1, Int(local / Self.pairBeat))
        let change = changes[i]
        let beat = local - Double(i) * Self.pairBeat
        let out = i < changes.count - 1 ? min(max((beat - (Self.pairBeat - 0.22)) / 0.22, 0), 1) : beatLeaving
        let now = fadeIn((beat - Self.nowDelay) / 0.4)
        let item: (feedback: String, lesson: String, skill: String) = switch change {
        case .icon: ("“39° in the menu bar isn't useful.”", "Quiet when fine. *Speaks when it isn't.*", "Act on feedback, fast")
        case .answer: ("“The one sentence wasn't clear.”", "Lead with the answer, *then the fix.*", "Explain it in plain English")
        case .colour: ("“There's a lot to take in.”", "Colour should mean *one thing.*", "Cut what doesn't earn its place")
        case .detail: ("“Two clicks is fine.”", "Detail in plain words, *one click away.*", "Detail on demand, not by default")
        case .today: ("New: what happened today", "Report the day, *not just the moment.*", "Turn data into something people use")
        }
        return ZStack(alignment: .topLeading) {
            // The feedback that led to it, and the lesson.
            VStack(spacing: 10) {
                Text("\(i + 1) / \(changes.count)   " + item.feedback)
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(Color(white: 0.62))
                    .opacity(fadeIn(beat / 0.25) * (1 - out))
                Headline(text: item.lesson, size: 60, time: beat - 0.05, leave: out)
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 92)
            beforeAfterLabel("BEFORE · 1.0", y: Self.beforeBand.centre - Self.beforeBand.height / 2 - 38)
                .opacity(fadeIn(beat / 0.3) * (1 - out))
            beforeShot(change).opacity(fadeIn(beat / 0.3) * (1 - out) * (1 - 0.35 * now))
            beforeAfterLabel("NOW · 1.1", y: Self.nowBand.centre - Self.nowBand.height / 2 - 38, bright: true)
                .opacity(now * (1 - out))
            nowShot(change).opacity(now * (1 - out)).offset(y: 30 * (1 - now))
            // The skill it shows, for anyone hiring.
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.green.opacity(0.8))
                Text(item.skill).foregroundStyle(.white)
            }
            .font(.system(size: 32, weight: .semibold))
            .frame(width: DemoVideo.size.width)
            .offset(y: 1212)
            .opacity(fadeIn((beat - 1.4) / 0.35) * (1 - out))
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    private func beforeAfterLabel(_ text: String, y: CGFloat, bright: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold)).tracking(5)
            .foregroundStyle(bright ? Color.white : Color(white: 0.5))
            .frame(width: DemoVideo.size.width)
            .offset(y: y)
    }

    private func band(_ top: CGFloat, _ bottom: CGFloat, _ b: (centre: CGFloat, height: CGFloat)) -> Framing {
        Framing.fit(top, bottom, centreY: b.centre, maxHeight: b.height)
    }

    /// A stretch of a screenshot in its band, with the panel's rounded card look.
    private func framedShot(_ image: NSImage?, _ height: CGFloat, _ f: Framing) -> some View {
        let rect = f.rect
        return ZStack(alignment: .topLeading) {
            if let image {
                Image(nsImage: image).resizable().frame(width: 680 * f.scale, height: height * f.scale)
                    .offset(x: f.x, y: f.y - f.top * f.scale)
            }
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
        .mask {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    @ViewBuilder private func beforeShot(_ change: Change) -> some View {
        switch change {
        case .icon: bigMenuItems([("thermometer.medium", "39°", "what does 39° mean?")], centre: Self.beforeBand.centre)
        case .answer: framedShot(shots.beforeAlert, Self.rows(shots.beforeAlert, 1746), band(14, 446, Self.beforeBand))
        case .colour: framedShot(shots.beforePanel, Self.rows(shots.beforePanel, 1746), band(447, 795, Self.beforeBand))   // CPU and tiles, not Wi-Fi
        case .detail: framedShot(shots.beforeMemory, Self.rows(shots.beforeMemory, 2144), band(796, 1180, Self.beforeBand))   // its Memory list (rows 788–1186)
        case .today:
            Text("Not there.")
                .font(.system(size: 52, weight: .regular)).italic().foregroundStyle(Color(white: 0.45))
                .frame(width: DemoVideo.size.width)
                .offset(y: Self.beforeBand.centre - 30)
        }
    }

    @ViewBuilder private func nowShot(_ change: Change) -> some View {
        switch change {
        case .icon: bigMenuItems([("macbook", "", "all good"), ("exclamationmark.triangle", "Memory full", "a problem")], centre: Self.nowBand.centre)
        case .answer: framedShot(shots.alertPanel, Self.rows(shots.alertPanel, 1222), band(0, 384, Self.nowBand))
        case .colour: framedShot(shots.panel, Self.rows(shots.panel, 1142), band(300, 478, Self.nowBand))
        case .detail: framedShot(shots.memory, Self.rows(shots.memory, 1532), band(480, 768, Self.nowBand))   // the answer and top apps (detail from row 473)
        case .today: framedShot(shots.panel, Self.rows(shots.panel, 1142), band(470, 808, Self.nowBand))
        }
    }

    /// Menu bar items drawn large, with a caption beside each, in one aligned column.
    private func bigMenuItems(_ items: [(symbol: String, text: String, caption: String)], centre: CGFloat) -> some View {
        VStack(spacing: 26) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 30) {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                        if !item.text.isEmpty { Text(item.text) }
                    }
                    .font(.system(size: 54, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 36).frame(height: 104)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.12)))
                    .frame(width: 470, alignment: .trailing)
                    Text(item.caption).font(.system(size: 32, weight: .medium)).foregroundStyle(Color(white: 0.78))
                        .frame(width: 330, alignment: .leading)
                }
            }
        }
        .frame(width: DemoVideo.size.width)
        .offset(y: centre - CGFloat(items.count) * 65)
    }

    /// How it shipped: the delivery loop, and the proof.
    var process: some View {
        let local = beatLocal, leave = beatLeaving
        let steps = ["Scope", "Build", "Test on real data", "Ship", "Measure", "Improve"]
        return VStack(spacing: 44) {
            Headline(text: "How it *shipped.*", size: 92, time: local - 0.05, leave: leave)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(steps.enumerated()), id: \.offset) { n, step in
                    let p = pop((local - 0.5 - 0.28 * Double(n)) / 0.35)
                    HStack(spacing: 18) {
                        Text(String(format: "%02d", n + 1)).font(.system(size: 28, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color(white: 0.5))
                        Text(step).font(.system(size: 42, weight: .medium)).foregroundStyle(.white)
                    }
                    .opacity(min(max(p * 1.5, 0), 1) * (1 - leave))
                    .offset(x: 20 * (1 - p))
                }
            }
            Text("Every release checked on real data before it went live.\nThe launch video held people for 17 s. This one is 29 s.")
                .font(.system(size: 30)).foregroundStyle(Color(white: 0.7))
                .multilineTextAlignment(.center)
                .opacity(fadeIn((local - 2.3) / 0.4) * (1 - leave))
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }
}

// MARK: - The 22-second cut (--v5)

extension DemoFrame {
    /// The hook is the answer itself: the question, “All good.”, and the real panel saying it, all on the
    /// first frame (LinkedIn's thumbnail). Then the other half of the sentence: the one thing that isn't.
    var answer5: some View {
        let local = beatLocal, leave = beatLeaving
        let flip = fadeIn((local - 1.7) / 0.35)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 6) {
                Text("Is your Mac OK?")
                    .font(.system(size: 34, weight: .semibold)).foregroundStyle(Color(white: 0.62))
                ZStack {
                    Text("All good.").font(.custom(DemoVideo.serif, size: 150)).foregroundStyle(.white)
                        .opacity(1 - flip)
                    VStack(spacing: 2) {
                        Text("Or the one thing").font(.custom(DemoVideo.serif, size: 96)).foregroundStyle(.white)
                        Text("that isn't.").font(.custom(DemoVideo.serif, size: 96)).italic().foregroundStyle(.white)
                    }
                    .opacity(flip)
                    .blur(radius: 10 * (1 - flip))
                }
                .frame(height: 230)
                Text("DeskBar answers in one sentence.")
                    .font(.system(size: 32)).foregroundStyle(Color(white: 0.7))
            }
            .frame(width: DemoVideo.size.width)
            .offset(y: 118)
            .opacity(1 - leave)
            framedShot(shots.panel, Self.rows(shots.panel, 1142), Framing.fit(6, 306, centreY: 900, maxHeight: 470))
                .opacity((1 - flip) * (1 - leave))
            framedShot(shots.alertPanel, Self.rows(shots.alertPanel, 1222), Framing.fit(0, 384, centreY: 900, maxHeight: 470))
                .opacity(flip * (1 - leave))
                .scaleEffect(0.97 + 0.03 * flip)
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height, alignment: .topLeading)
    }

    /// How it shipped, in one beat: the delivery loop and the proof.
    var process5: some View {
        let local = beatLocal, leave = beatLeaving
        let steps = ["Scope", "Build", "Test on real data", "Ship", "Measure", "Improve"]
        return VStack(spacing: 40) {
            Headline(text: "How it *shipped.*", size: 88, time: local + 0.3, leave: leave)
            VStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 14) {
                        ForEach(0..<2, id: \.self) { col in
                            let n = row * 2 + col
                            let p = pop((local - 0.3 - 0.18 * Double(n)) / 0.3)
                            HStack(spacing: 12) {
                                Text(String(format: "%02d", n + 1)).font(.system(size: 26, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Color(white: 0.5))
                                Text(steps[n]).font(.system(size: 36, weight: .medium)).foregroundStyle(.white)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 26).frame(width: 420, height: 76)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
                            .opacity(min(max(p * 1.5, 0), 1) * (1 - leave))
                        }
                    }
                }
            }
            Text("Every release tested on real data before it went live.")
                .font(.system(size: 30)).foregroundStyle(Color(white: 0.72))
                .opacity(fadeIn((local - 1.4) / 0.35) * (1 - leave))
        }
        .frame(width: DemoVideo.size.width, height: DemoVideo.size.height)
    }
}
