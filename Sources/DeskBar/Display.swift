import AppKit
import Sensors

/// Brightness for every screen plus Night Shift.
///
/// The built-in screen uses Apple's private DisplayServices; external monitors take DDC
/// commands over the cable (works with most monitors);
/// Night Shift goes through CoreBrightness's `CBBlueLightClient`.
@MainActor
final class DisplayControl: ObservableObject {
    struct Screen: Identifiable {
        enum Kind { case builtIn(CGDirectDisplayID), external(ddcIndex: Int) }
        var id: String
        var name: String
        var kind: Kind
        var brightness: Double   // 0–1
        var known = true         // false when the monitor won't report its level
    }

    @Published var screens: [Screen] = []
    @Published var nightShift = false

    private var pendingWrites: [String: DispatchWorkItem] = [:]

    // DisplayServices, loaded at runtime.
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private lazy var getBrightness = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetBrightness.self) }
    private lazy var setBrightnessFn = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    private lazy var blueLight: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
    }()

    var summary: String {
        let count = screens.count
        return (count == 1 ? "1 screen" : "\(count) screens") + (nightShift ? " · Night Shift" : "")
    }

    /// Reads current levels. DDC reads take ~50 ms per monitor, so run this when the panel opens.
    func refresh() {
        var list: [Screen] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) != 0 else { continue }
            var level: Float = 0.5
            _ = getBrightness?(id, &level)
            list.append(Screen(id: "builtin", name: "MacBook screen", kind: .builtIn(id), brightness: Double(level)))
        }
        // External screens in macOS's order; DDC services come back in the same order.
        let externals = NSScreen.screens.filter {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false
        }
        let ddcCount = Int(ddc_display_count())
        for index in 0..<ddcCount {
            let level = ddc_get_brightness(Int32(index))
            let name = index < externals.count && !Demo.on ? externals[index].localizedName : "Monitor \(index + 1)"   // demo: no real model names
            // Some monitors stop answering DDC reads but still accept
            // writes, so fall back to the level last set from here.
            let saved = UserDefaults.standard.object(forKey: "ddcBrightness\(index)") as? Double
            list.append(Screen(id: "ddc\(index)", name: name, kind: .external(ddcIndex: index),
                               brightness: level >= 0 ? Double(level) / 100 : saved ?? 1,
                               known: level >= 0 || saved != nil))
        }
        screens = list
        nightShift = readNightShift()
    }

    /// Updates the slider at once; the monitor write is debounced so dragging stays smooth.
    func setBrightness(_ value: Double, for id: String) {
        guard let i = screens.firstIndex(where: { $0.id == id }) else { return }
        screens[i].brightness = value
        screens[i].known = true
        let kind = screens[i].kind
        if case .external(let index) = kind { UserDefaults.standard.set(value, forKey: "ddcBrightness\(index)") }
        pendingWrites[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            switch kind {
            case .builtIn(let display):
                _ = self?.setBrightnessFn?(display, Float(value))
            case .external(let index):
                DispatchQueue.global().async { _ = ddc_set_brightness(Int32(index), Int32((value * 100).rounded())) }
            }
        }
        pendingWrites[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func setNightShift(_ on: Bool) {
        guard let client = blueLight else { return }
        let selector = NSSelectorFromString("setEnabled:")
        guard client.responds(to: selector) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(client.method(for: selector), to: SetEnabled.self)(client, selector, on)
        nightShift = readNightShift()
    }

    private func readNightShift() -> Bool {
        guard let client = blueLight else { return false }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: selector) else { return false }
        // Status struct starts { BOOL active; BOOL enabled; ... }; a roomy buffer covers the rest.
        var status = [UInt8](repeating: 0, count: 64)
        typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let ok = status.withUnsafeMutableBytes {
            unsafeBitCast(client.method(for: selector), to: GetStatus.self)(client, selector, $0.baseAddress!)
        }
        return ok && status[1] != 0
    }
}
