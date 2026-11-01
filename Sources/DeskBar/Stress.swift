import AppKit
import SwiftUI

/// `DeskBar --snapshot <dir> --stress`: the live panel in an off-screen window, flipped through
/// every tile, section, size and warning hundreds of times, printing memory as it goes.
/// Memory that keeps climbing round after round is a leak (like the 386,000-object one in 1.0).
@MainActor
enum Stress {
    static func run(model: AppModel) async {
        let host = NSHostingView(rootView: Panel(model: model))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 340, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        let keys = ["", "cpu", "memory", "disk", "battery", "Wi-Fi", "Sound", "Display", "Settings"]
        let defaults = UserDefaults.standard
        let normal = model.stats.memory

        func step(_ i: Int) async {
            defaults.set(keys[i % keys.count], forKey: "open")
            if i % 7 == 0 { defaults.set(!defaults.bool(forKey: "macExpanded"), forKey: "macExpanded") }
            if i % 5 == 0 { defaults.set(!defaults.bool(forKey: "moreActions"), forKey: "moreActions") }
            if i % 11 == 0, var memory = model.stats.memory {
                // A warning comes and goes.
                memory.pressure = memory.pressure == .high ? .normal : .high
                model.stats.memory = memory
            }
            try? await Task.sleep(for: .milliseconds(40))
        }

        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<60 { await step(i) }   // warm up: every view built once
        let base = footprint()
        print(String(format: "after warm-up      %6.1f MB", base))
        let rounds = 6, perRound = 200
        for round in 1...rounds {
            for i in 0..<perRound { await step(round * perRound + i) }
            print(String(format: "after %4d changes %6.1f MB  (%+.1f)", round * perRound, footprint(), footprint() - base))
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print(String(format: "%d state changes in %.0f s", 60 + rounds * perRound, seconds))
        model.stats.memory = normal
        defaults.set("", forKey: "open")
        defaults.set(false, forKey: "macExpanded")
        defaults.set(false, forKey: "moreActions")
    }

    /// The "Memory" column in Activity Monitor for this process, in MB.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
