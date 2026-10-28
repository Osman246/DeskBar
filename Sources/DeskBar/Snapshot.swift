import SceneKit
import CoreWLAN
import Sensors
import AppKit
import SwiftUI

/// `DeskBar --snapshot <dir>` renders the panel, with live readings, to light and dark PNGs.
@MainActor
enum Snapshot {
    static func run(to directory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = AppModel(askForNotifications: false)
            if CommandLine.arguments.contains("--demo-video") {
                await DemoVideo.make(model: model, to: directory)
                exit(0)
            }
            model.stats.historyInterval = 2  // fill the graphs faster than once every 10 s
            try? await Task.sleep(for: .seconds(24))
            model.display.refresh()
            model.sound.refresh()
            if CommandLine.arguments.contains("--flat") {
                // A new install: no 3D model yet (run with DESKBAR_NO_MODEL=1).
                model.mac.loadIfNeeded()
                try? await Task.sleep(for: .seconds(3))
                for (file, name) in [("panel-flat-dark", NSAppearance.Name.darkAqua), ("panel-flat-light", .aqua)] {
                    let host = NSHostingView(rootView: Panel(model: model).background(Color(nsColor: .windowBackgroundColor)))
                    host.appearance = NSAppearance(named: name)
                    host.frame.size = host.fittingSize
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = host.appearance
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(file).png"))
                }
                print("Wrote panel-flat")
                exit(0)
            }
            await model.mac.waitUntilLoaded()
            if CommandLine.arguments.contains("--window") {
                // Seed the test database with a believable day so the charts can be checked.
                let start = Calendar.current.startOfDay(for: Date())
                let minutes = Int(Date().timeIntervalSince(start) / 60)
                for m in stride(from: 0, to: minutes, by: 1) {
                    let t = Double(m) / Double(max(minutes, 1))
                    let spike = exp(-pow((t - 0.6) / 0.03, 2))
                    let sample = HistoryStore.Sample(date: start.addingTimeInterval(Double(m * 60)),
                        cpu: 12 + 8 * sin(t * 30) .magnitude + 70 * spike, gpu: 5 + 65 * spike, temperature: 38 + 4 * sin(t * 12) + 36 * spike,
                        memoryUsed: 10.5e9 + 1.5e9 * sin(t * 5).magnitude, pressure: spike > 0.5 ? 1 : 0,
                        battery: max(20, 100 - Double(m) * 0.12), charging: t > 0.8, watts: 7 + 3 * sin(t * 20).magnitude + 18 * spike,
                        download: 2e5 + 3e6 * pow(sin(t * 9), 8), upload: 4e4 + 6e5 * pow(sin(t * 7), 8), displays: t > 0.3 ? 2 : 0)
                    HistoryStore.shared.record(sample, apps: [("Final Cut Pro", 4 + 70 * spike), ("Safari", 8), ("Xcode", 5), ("Music", 1.5)])
                }
                try? await Task.sleep(for: .seconds(2))
                model.stats.volumes = Readers.volumes()
                let deskStill = MacScene(size: CGSize(width: 880, height: 440))
                deskStill.playsIntro = false
                await deskStill.waitUntilLoaded()
                deskStill.update(MacHero.state(stats: model.stats, warning: nil))
                deskStill.setMode(.desk)
                deskStill.settleForStill()
                DeskStage.still = deskStill.still()
                for page in DashboardWindow.Page.allCases {
                    UserDefaults.standard.set(page.rawValue, forKey: "snapshotPage")
                    let pageView = VStack(alignment: .leading, spacing: 16) {
                        Text(page.rawValue).font(.title2.bold())
                        DashboardWindow.content(page, model: model, range: .day)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 22)
                    .frame(width: 960, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .dark)
                    let host = NSHostingView(rootView: pageView)
                    host.frame.size = host.fittingSize
                    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("window-\(page.rawValue.lowercased()).png"))
                }
                print("Wrote window pages")
                exit(0)
            }
            if CommandLine.arguments.contains("--profile") {
                func ms(_ f: () -> Void) -> Double { let t = DispatchTime.now().uptimeNanoseconds; f(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
                print(String(format: "install (first open, main thread)  %.1f ms", MacScene.installMilliseconds))
                let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                renderer.scene = model.mac.scene; renderer.pointOfView = model.mac.cameraNode
                print(String(format: "first render (shader compile)  %.1f ms", ms { _ = renderer.snapshot(atTime: 0, with: CGSize(width: 640, height: 420), antialiasingMode: .multisampling4X) }))
                print(String(format: "second render  %.1f ms", ms { _ = renderer.snapshot(atTime: 0, with: CGSize(width: 640, height: 420), antialiasingMode: .multisampling4X) }))
                print(model.mac.profileIntro())
                var fast: [Double] = []
                for _ in 0..<5 { fast.append(ms { model.stats.refreshFast() }) }
                print(String(format: "Stats.refreshFast (every 2 s, main thread)  %@ ms", fast.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
                print(String(format: "Ports.read  %.1f ms", ms { _ = Ports.read(chargerWatts: nil, charging: false) }))
                let parts: [(String, () -> Void)] = [
                    ("wifi", { _ = CWWiFiClient.shared().interface()?.ssid() }),
                    ("temp", { _ = sensors_cpu_temperature() }),
                    ("memory", { _ = Readers.memory() }), ("power", { _ = Readers.power() }),
                    ("gpu", { _ = Readers.gpuPercent() }), ("fans", { _ = Readers.fanSpeeds() }),
                    ("mic", { _ = Readers.micInUse() }), ("cameras", { _ = Readers.camerasInUse() }),
                    ("cores", { _ = Readers.coreTicks() }), ("disk", { _ = Readers.diskBytes() }),
                    ("net", { _ = Readers.networkBytes() }), ("storage", { _ = Readers.storage() }), ("volumes", { _ = Readers.volumes() }),
                ]
                for (name, f) in parts { print(String(format: "  %@ %.2f ms", name, ms(f))) }
                print(String(format: "TopApp sample  %.1f ms", ms { _ = TopAppTracker().sample() }))
                exit(0)
            }
            if CommandLine.arguments.contains("--states") {
                // Simulated states that aren't live right now: charging on MagSafe, camera + mic, clamshell.
                var fake = MacHero.state(stats: model.stats, warning: nil)
                fake.charging = true; fake.magSafeConnected = true; fake.batteryPercent = 64; fake.onPower = true
                var shots: [(String, NSImage)] = []
                @MainActor func shoot(_ name: String) {
                    model.mac.settleForStill()
                    if let image = model.mac.still() {
                        let host = NSHostingView(rootView: ZStack { Image(nsImage: image).resizable(); HeroPillsPreview(mac: model.mac) }
                            .frame(width: MacScene.panelSize.width, height: MacScene.panelSize.height).background(Color(white: 0.16)))
                        host.frame.size = host.fittingSize
                        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                        window.contentView = host; window.appearance = NSAppearance(named: .darkAqua)
                        host.layoutSubtreeIfNeeded()
                        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                        host.cacheDisplay(in: host.bounds, to: rep)
                        let out = NSImage(size: host.bounds.size); out.addRepresentation(rep)
                        shots.append((name, out))
                    }
                }
                // Every port in use.
                fake.ports = model.stats.ports.map { port in
                    var p = port
                    p.connected = true
                    return p
                }
                fake.externalDisplays = 2
                model.mac.setMode(.rest); model.mac.update(fake); shoot("Rest · charger, monitors, headphones, SD card")
                model.mac.setMode(.ports(.left)); model.mac.update(fake); shoot("Left side · MagSafe, two USB-C, headphones")
                model.mac.setMode(.ports(.right)); model.mac.update(fake); shoot("Right side · HDMI, USB-C, SD card")
                // Gear on the desk.
                fake.ports = model.stats.ports.map { var p = $0; p.connected = false; return p }
                fake.magSafeConnected = false; fake.charging = false
                fake.airPods = "L 80% · R 75%"
                model.mac.setMode(.rest); model.mac.update(fake); shoot("AirPods connected")
                fake.airPods = nil; fake.cameraInUse = true; fake.continuityCamera = true
                model.mac.update(fake); shoot("iPhone as the webcam")
                fake.airPods = "L 80% · R 75%"; fake.magSafeConnected = true; fake.charging = true
                fake.ports = model.stats.ports.map { var p = $0; p.connected = p.id.hasPrefix("Port-USB-C@1") || p.id.hasPrefix("Port-USB-C@2"); return p }
                model.mac.update(fake); shoot("Everything at once")
                // Desk view.
                var deskState = MacHero.state(stats: model.stats, warning: nil)
                deskState.externalDisplays = 2; deskState.leftMonitor = true; deskState.rightMonitor = true
                deskState.magSafeConnected = true; deskState.charging = true; deskState.batteryPercent = 64
                deskState.ports = model.stats.ports.map { var p = $0; p.connected = p.id == "Port-USB-C@1" || p.id == "Port-USB-C@2"; return p }
                model.mac.simulateLid(108)
                model.mac.setMode(.desk); model.mac.update(deskState); shoot("Desk view · both monitors")
                deskState.rightMonitor = false; deskState.externalDisplays = 1
                model.mac.update(deskState); shoot("Desk view · right monitor unplugged")
                deskState.rightMonitor = true; deskState.externalDisplays = 2
                model.mac.simulateLid(0); model.mac.update(deskState); shoot("Desk view · clamshell")
                model.mac.simulateLid(nil)
                let w = 640, h = 420
                let rows = (shots.count + 2) / 3
                let sheet = NSImage(size: NSSize(width: w * 3, height: (h + 40) * rows))
                sheet.lockFocus()
                NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w * 3, height: (h + 40) * rows).fill()
                for (i, shot) in shots.enumerated() {
                    let x = (i % 3) * w, y = (rows - 1 - i / 3) * (h + 40)
                    shot.1.draw(in: NSRect(x: x + 8, y: y + 8, width: w - 16, height: h - 16))
                    (shot.0 as NSString).draw(at: NSPoint(x: x + 12, y: y + h + 6), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white])
                }
                sheet.unlockFocus()
                try? NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("states.png"))
                print("Wrote states.png")
                exit(0)
            }
            if CommandLine.arguments.contains("--intro") {
                let stats = model.stats
                model.mac.update(MacHero.state(stats: stats, warning: nil))
                let frames = await model.mac.recordIntro()
                // Eight evenly spaced frames, 4 × 2.
                let picks = (0..<8).map { frames[min(frames.count - 1, $0 * frames.count / 8)] }
                let w = 320, h = 210
                let sheet = NSImage(size: NSSize(width: w * 4, height: h * 2))
                sheet.lockFocus()
                NSColor(white: 0.16, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: w * 4, height: h * 2).fill()
                for (i, frame) in picks.enumerated() {
                    frame.draw(in: NSRect(x: (i % 4) * w, y: (1 - i / 4) * h, width: w, height: h))
                }
                sheet.unlockFocus()
                try? NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("intro.png"))
                print("Wrote intro.png from \(frames.count) frames")
                exit(0)
            }
            if CommandLine.arguments.contains("--transition") {
                // Contact sheet of the Left → Right camera move.
                let frames = await model.mac.recordSideSwitch()
                let picks = stride(from: 0, to: frames.count, by: max(1, frames.count / 8)).map { frames[$0] }
                let w = 320, h = 210
                let sheet = NSImage(size: NSSize(width: w * 4, height: h * 2))
                sheet.lockFocus()
                NSColor(white: 0.16, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: w * 4, height: h * 2).fill()
                for (i, frame) in picks.prefix(8).enumerated() {
                    frame.draw(in: NSRect(x: (i % 4) * w, y: (1 - i / 4) * h, width: w, height: h))
                }
                sheet.unlockFocus()
                let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("side-switch.png"))
                print("Wrote side-switch.png from \(frames.count) frames")
                exit(0)
            }
            let shots: [(String, String, NSAppearance.Name)] = [
                ("panel-light", "", .aqua), ("panel-dark", "", .darkAqua),
                ("cpu", "cpu", .darkAqua), ("memory", "memory", .darkAqua), ("disk", "disk", .darkAqua),
                ("battery", "battery", .darkAqua), ("network", "Network", .darkAqua),
                ("sound", "Sound output", .darkAqua), ("display", "Display", .darkAqua),
                ("speed", "Speed test", .darkAqua), ("devices", "Devices", .darkAqua),
                ("alerts", "Smart alerts", .darkAqua),
                ("ports-left", "ports-left", .darkAqua), ("ports-right", "ports-right", .darkAqua),
            ]
            for (file, open, name) in shots {
                // Pose the 3D Mac for this shot and render it as a still.
                let stats = model.stats
                switch open {
                case "ports-left": model.mac.setMode(.ports(.left))
                case "ports-right": model.mac.setMode(.ports(.right))
                default: model.mac.setMode(.rest); model.mac.follow(tile: open)
                }
                model.mac.update(MacHero.state(stats: stats, warning: nil))
                model.mac.settleForStill()
                MacHero.stillImage = model.mac.still()
                UserDefaults.standard.set(open.hasPrefix("ports") ? "" : open, forKey: "open")
                let host = NSHostingView(rootView: Panel(model: model)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: name)
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(800))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(file).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("Wrote \(url.path)")
            }
            UserDefaults.standard.set("", forKey: "open")
            exit(0)
        }
        app.run()
    }
}

/// The hero's pills on their own, for snapshot testing.
struct HeroPillsPreview: View {
    @ObservedObject var mac: MacScene
    var body: some View {
        HStack(spacing: 6) {
            ForEach(mac.pills) { pill in
                HStack(spacing: 5) {
                    Circle().fill(pill.color).frame(width: 6, height: 6)
                    Text(pill.text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.45)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

