import Foundation

/// Runs macOS's own `networkQuality` test (Apple's servers, ~15 s) and keeps the last ten results.
@MainActor
final class SpeedTest: ObservableObject {
    struct Result: Codable, Identifiable {
        var date: Date
        var downMbps: Double
        var upMbps: Double
        var pingMs: Double
        var network: String?
        var id: Date { date }
    }

    @Published var results: [Result] = SpeedTest.load()
    @Published var running = false
    @Published var error: String?

    var latest: Result? { results.first }

    var summary: String {
        if running { return "Testing…" }
        guard let latest else { return "Not run yet" }
        return "↓ \(Int(latest.downMbps.rounded())) Mbps · \(latest.date.formatted(.relative(presentation: .named)))"
    }

    func run(network: String?) async {
        guard !running else { return }
        running = true
        error = nil
        let output = await Shell.run("/usr/bin/networkQuality", ["-c"])
        running = false
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let down = json["dl_throughput"] as? Double, let up = json["ul_throughput"] as? Double else {
            error = "The test didn't finish. Check your connection and try again."
            return
        }
        let result = Result(date: Date(), downMbps: down / 1_000_000, upMbps: up / 1_000_000,
                            pingMs: json["base_rtt"] as? Double ?? 0, network: network)
        results.insert(result, at: 0)
        results = Array(results.prefix(10))
        if let data = try? JSONEncoder().encode(results) { UserDefaults.standard.set(data, forKey: "speedTests") }
    }

    private static func load() -> [Result] {
        guard let data = UserDefaults.standard.data(forKey: "speedTests") else { return [] }
        return (try? JSONDecoder().decode([Result].self, from: data)) ?? []
    }
}
