import Foundation
import Testing
@testable import DeskBar

/// The verdict is DeskBar's one promise: "All good", or the one thing that isn't. These pin down
/// when each problem appears, what it says, and which one wins the headline.
@Suite struct VerdictTests {
    private func memory(_ pressure: Readers.Memory.Pressure) -> Readers.Memory {
        Readers.Memory(used: 0, total: 16 << 30, pressure: pressure, app: 0, wired: 0, compressed: 0, cached: 0)
    }

    @Test func allClearMeansNoProblems() {
        #expect(Readings().problems.isEmpty)
    }

    @Test func runningHotFromEightyFiveDegrees() {
        #expect(Readings(cpuTemp: 84.9).problems.isEmpty)
        let hot = Readings(cpuTemp: 85, cpuUsers: [TopAppTracker.CPUUser(name: "Xcode", percent: 300, share: 0.8, app: nil, pid: 42)])
        #expect(hot.problems.map(\.word) == ["Running hot"])
        #expect(hot.problems.first?.reason == "Xcode is working hardest")
        #expect(hot.problems.first?.fix == nil)   // no running app behind it, so no Quit button
    }

    @Test func lowBatteryOnlyWhenUnplugged() {
        let low = Stats.Battery(percent: 20, charging: false, onPower: false, minutesLeft: 90)
        #expect(Readings(battery: low).problems.map(\.word) == ["Low battery"])
        #expect(Readings(battery: low).problems.first?.reason == "About 1 h 30 m left")

        var plugged = low; plugged.onPower = true
        #expect(Readings(battery: plugged).problems.isEmpty)
        var fine = low; fine.percent = 21
        #expect(Readings(battery: fine).problems.isEmpty)
        var unknown = low; unknown.minutesLeft = nil
        #expect(Readings(battery: unknown).problems.first?.reason == "20% left")
    }

    @Test func memoryFullOnlyAtHighPressure() {
        #expect(Readings(memory: memory(.moderate)).problems.isEmpty)
        #expect(Readings(memory: memory(.high)).problems.first?.reason == "Too many apps open")
        let user = TopAppTracker.MemoryUser(name: "Chrome", bytes: 6 << 30, app: nil, pid: 7)
        let full = Readings(memory: memory(.high), memoryUsers: [user]).problems.first
        #expect(full?.title == "Memory is full")
        #expect(full?.reason.hasPrefix("Chrome is using") == true)
    }

    @Test func diskAlmostFullUnderTenGigabytes() {
        #expect(Readings(storage: (free: 10_000_000_000, total: 500_000_000_000)).problems.isEmpty)
        let full = Readings(storage: (free: 9_999_999_999, total: 500_000_000_000)).problems.first
        #expect(full?.word == "Disk almost full")
        #expect(full?.fix == .cleanDownloads)
    }

    @Test func throttlingWhenThermalStateIsSerious() {
        #expect(Readings(thermal: .fair).problems.isEmpty)
        #expect(Readings(thermal: .serious).problems.map(\.word) == ["Throttling"])
        #expect(Readings(thermal: .critical).problems.map(\.word) == ["Throttling"])
    }

    @Test func offlineAndNoInternetAreDifferent() {
        let off = Readings(wifi: Stats.WiFi(on: false, name: nil, linkMbps: 0, signal: 0), pingMs: nil)
        #expect(off.problems.map(\.word) == ["Offline"])          // never "No internet" as well
        #expect(off.problems.first?.reason == "Wi-Fi is off")

        let notJoined = Readings(wifi: Stats.WiFi(on: true, name: nil, linkMbps: 0, signal: 0), pingMs: nil)
        #expect(notJoined.problems.first?.reason == "Not connected to a network")

        let noInternet = Readings(pingMs: nil)
        #expect(noInternet.problems.map(\.word) == ["No internet"])
        #expect(noInternet.problems.first?.fix == .wifiSettings)
    }

    @Test func mostUrgentProblemWinsTheHeadline() {
        let many = Readings(cpuTemp: 95, battery: Stats.Battery(percent: 5, charging: false, onPower: false, minutesLeft: 10),
                            memory: memory(.high), storage: (free: 1_000_000_000, total: 500_000_000_000),
                            thermal: .critical, pingMs: nil)
        #expect(many.problems.map(\.word) == ["Running hot", "Low battery", "Memory full", "Disk almost full", "Throttling", "No internet"])
    }

    @Test func durations() {
        #expect(Stats.duration(45) == "45 min")
        #expect(Stats.duration(60) == "1 h 0 m")
        #expect(Stats.duration(125) == "2 h 5 m")
    }
}
