import AppKit
import CoreAudio
import IOKit.pwr_mgt

enum Shell {
    /// Runs a command off the main thread and returns its stdout.
    @discardableResult
    static func run(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    done.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    done.resume(returning: "")
                }
            }
        }
    }
}

/// The one-click buttons. Toggles keep their state; one-shot actions report a message.
@MainActor
final class Actions: ObservableObject {
    @Published var message = "Tap an action"
    @Published var focusOn = UserDefaults.standard.bool(forKey: "focusOn")
    @Published var stayAwake = false
    @Published var desktopHidden = Actions.finderHidesDesktop
    @Published var micMuted = false

    private var awakeAssertion: IOPMAssertionID = 0

    init() { micMuted = Self.inputVolume() == 0 }

    /// Re-reads state that can change outside the app.
    func refresh() {
        desktopHidden = Self.finderHidesDesktop
        micMuted = Self.inputVolume() == 0
    }

    // MARK: Toggles

    /// Runs the "Toggle Do Not Disturb" shortcut. macOS doesn't let apps read the
    /// Focus state, so this remembers what it last set.
    func toggleFocus() async {
        guard await runShortcut("Toggle Do Not Disturb") else { return }
        focusOn.toggle()
        UserDefaults.standard.set(focusOn, forKey: "focusOn")
        message = focusOn ? "Do Not Disturb on" : "Do Not Disturb off"
    }

    func toggleStayAwake() {
        if stayAwake {
            IOPMAssertionRelease(awakeAssertion)
            stayAwake = false
            message = "Your Mac can sleep again"
        } else {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "DeskBar: Stay awake" as CFString, &awakeAssertion)
            stayAwake = result == kIOReturnSuccess
            message = stayAwake ? "Staying awake until you turn this off" : "Couldn't keep your Mac awake"
        }
    }

    func toggleDesktop() async {
        let hide = !desktopHidden
        await Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hide ? "false" : "true"])
        await Shell.run("/usr/bin/killall", ["Finder"])
        desktopHidden = hide
        message = hide ? "Desktop icons hidden" : "Desktop icons back"
    }

    func toggleMic() {
        if micMuted {
            let saved = UserDefaults.standard.integer(forKey: "micVolume")
            Self.setInputVolume(saved > 0 ? saved : 75)
            message = "Microphone on"
        } else {
            UserDefaults.standard.set(Self.inputVolume() ?? 75, forKey: "micVolume")
            Self.setInputVolume(0)
            message = "Microphone muted"
        }
        micMuted = Self.inputVolume() == 0
    }

    // MARK: One-shot actions

    func screenshot() {
        closePanel()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                                           configuration: .init())
    }

    /// Moves Downloads items untouched for 30 days to the Trash, after asking.
    func cleanUpDownloads() {
        let fm = FileManager.default
        let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let items = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys,
                                                      options: .skipsHiddenFiles) else {
            message = "Couldn't open your Downloads folder"
            return
        }
        let old = items.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            let date = values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantFuture
            return date < cutoff
        }
        guard !old.isEmpty else {
            message = "Nothing in Downloads older than 30 days"
            return
        }
        let bytes = old.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move \(old.count) old download\(old.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "These items in Downloads haven't been touched in 30 days (\(size)). You can put them back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let moved = old.filter { (try? fm.trashItem(at: $0, resultingItemURL: nil)) != nil }.count
        message = "Moved \(moved) item\(moved == 1 ? "" : "s") (\(size)) to the Trash"
    }

    /// Puts the displays to sleep; the Mac keeps running.
    func sleepDisplays() {
        closePanel()
        Task { await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
    }

    func lockScreen() {
        closePanel()
        // Same call the Control Center "Lock Screen" item uses.
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias Lock = @convention(c) () -> Int32
            _ = unsafeBitCast(symbol, to: Lock.self)()
        } else {
            Task { await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
        }
    }

    // MARK: Helpers

    private func runShortcut(_ name: String) async -> Bool {
        let list = await Shell.run("/usr/bin/shortcuts", ["list"])
        guard list.split(separator: "\n").contains(where: { $0 == name }) else {
            message = "Add a shortcut called \"\(name)\" first"
            return false
        }
        await Shell.run("/usr/bin/shortcuts", ["run", name])
        return true
    }

    private func closePanel() {
        NSApp.windows.filter { $0.isVisible && $0.className.contains("MenuBarExtra") }.forEach { $0.orderOut(nil) }
    }

    private static var finderHidesDesktop: Bool {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        return (CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? Bool) == false
    }

    // Input volume of the current microphone, via CoreAudio (0–100).
    private static func inputVolume() -> Int? {
        guard let device = defaultInput() else { return nil }
        for element in volumeElements(device) {
            var address = volumeAddress(element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return Int((value * 100).rounded())
            }
        }
        return nil
    }

    private static func setInputVolume(_ percent: Int) {
        guard let device = defaultInput() else { return }
        var value = Float32(percent) / 100
        for element in volumeElements(device) {
            var address = volumeAddress(element)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// Some mics expose one main volume, others one per channel.
    private static func volumeElements(_ device: AudioDeviceID) -> [UInt32] {
        var main = volumeAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { var a = volumeAddress($0); return AudioObjectHasProperty(device, &a) }
    }

    private static func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }
}
