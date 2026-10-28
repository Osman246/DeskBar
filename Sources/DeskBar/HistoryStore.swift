import Foundation
import SQLite3

/// Minute-by-minute history for the DeskBar window, kept in
/// ~/Library/Application Support/DeskBar/history.sqlite (about 1 MB a month; 90 days are kept).
///
/// Writes happen on a private serial queue; reads are small and run on the caller's thread.
final class HistoryStore: @unchecked Sendable {
    struct Sample: Identifiable, Sendable {
        var date: Date
        var cpu: Double            // %
        var gpu: Double            // %
        var temperature: Double?   // °C
        var memoryUsed: Double     // bytes
        var pressure: Int          // 0 normal, 1 moderate, 2 high
        var battery: Double?       // %
        var charging: Bool
        var watts: Double?
        var download: Double       // bytes per second
        var upload: Double
        var displays: Int
        var id: Date { date }
    }

    struct AppUsage: Identifiable, Sendable {
        var name: String
        var cpuSeconds: Double
        var id: String { name }
    }

    struct AlertEvent: Identifiable, Sendable {
        var date: Date
        var title: String
        var body: String
        var id: String { "\(date.timeIntervalSince1970)\(title)" }
    }

    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "DeskBar.history")

    private init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // DESKBAR_HISTORY lets snapshot tests use a separate file instead of your real history.
        let path = ProcessInfo.processInfo.environment["DESKBAR_HISTORY"] ?? folder.appendingPathComponent("history.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS samples (
                t INTEGER PRIMARY KEY, cpu REAL, gpu REAL, temp REAL, mem REAL, pressure INTEGER,
                battery REAL, charging INTEGER, watts REAL, down REAL, up REAL, displays INTEGER);
            CREATE TABLE IF NOT EXISTS apps (t INTEGER, name TEXT, cpu REAL);
            CREATE INDEX IF NOT EXISTS apps_t ON apps (t);
            CREATE TABLE IF NOT EXISTS alerts (t INTEGER, title TEXT, body TEXT);
            """)
        queue.async { self.execute("DELETE FROM samples WHERE t < \(Int(Date().timeIntervalSince1970) - 90 * 86_400);"
                                   + "DELETE FROM apps WHERE t < \(Int(Date().timeIntervalSince1970) - 90 * 86_400);") }
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: Writing

    func record(_ sample: Sample, apps: [(String, Double)]) {
        queue.async { [self] in
            guard let db else { return }
            var statement: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            let t = Int64(sample.date.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 1, t)
            sqlite3_bind_double(statement, 2, sample.cpu)
            sqlite3_bind_double(statement, 3, sample.gpu)
            bind(statement, 4, sample.temperature)
            sqlite3_bind_double(statement, 5, sample.memoryUsed)
            sqlite3_bind_int(statement, 6, Int32(sample.pressure))
            bind(statement, 7, sample.battery)
            sqlite3_bind_int(statement, 8, sample.charging ? 1 : 0)
            bind(statement, 9, sample.watts)
            sqlite3_bind_double(statement, 10, sample.download)
            sqlite3_bind_double(statement, 11, sample.upload)
            sqlite3_bind_int(statement, 12, Int32(sample.displays))
            sqlite3_step(statement)
            sqlite3_finalize(statement)

            for (name, cpu) in apps {
                var row: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO apps VALUES (?,?,?)", -1, &row, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(row, 1, t)
                sqlite3_bind_text(row, 2, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_double(row, 3, cpu)
                sqlite3_step(row)
                sqlite3_finalize(row)
            }
        }
    }

    func logAlert(title: String, body: String) {
        queue.async { [self] in
            guard let db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO alerts VALUES (?,?,?)", -1, &statement, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(statement, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(statement, 2, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 3, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    // MARK: Reading

    /// Samples since `start`, averaged into buckets of `bucket` seconds (60 = every minute).
    func samples(since start: Date, bucket: Int = 60) -> [Sample] {
        let sql = """
            SELECT (t / \(bucket)) * \(bucket), AVG(cpu), AVG(gpu), AVG(temp), AVG(mem), MAX(pressure),
                   AVG(battery), MAX(charging), AVG(watts), AVG(down), AVG(up), MAX(displays)
            FROM samples WHERE t >= ? GROUP BY t / \(bucket) ORDER BY 1
            """
        return query(sql, [Int64(start.timeIntervalSince1970)]) { s in
            Sample(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 0))),
                   cpu: sqlite3_column_double(s, 1), gpu: sqlite3_column_double(s, 2), temperature: Self.optional(s, 3),
                   memoryUsed: sqlite3_column_double(s, 4), pressure: Int(sqlite3_column_int(s, 5)),
                   battery: Self.optional(s, 6), charging: sqlite3_column_int(s, 7) != 0, watts: Self.optional(s, 8),
                   download: sqlite3_column_double(s, 9), upload: sqlite3_column_double(s, 10),
                   displays: Int(sqlite3_column_int(s, 11)))
        }
    }

    /// CPU time per app between two dates (each stored row is one minute at an average %).
    func busiestApps(from start: Date, to end: Date = .distantFuture, limit: Int = 6) -> [AppUsage] {
        let sql = "SELECT name, SUM(cpu) * 0.6 FROM apps WHERE t >= ? AND t < ? GROUP BY name ORDER BY 2 DESC LIMIT \(limit)"
        let to = end == .distantFuture ? Int64.max : Int64(end.timeIntervalSince1970)
        return query(sql, [Int64(start.timeIntervalSince1970), to]) { s in
            AppUsage(name: String(cString: sqlite3_column_text(s, 0)), cpuSeconds: sqlite3_column_double(s, 1))
        }
    }

    func alerts(since start: Date) -> [AlertEvent] {
        query("SELECT t, title, body FROM alerts WHERE t >= ? ORDER BY t DESC", [Int64(start.timeIntervalSince1970)]) { s in
            AlertEvent(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 0))),
                       title: String(cString: sqlite3_column_text(s, 1)), body: String(cString: sqlite3_column_text(s, 2)))
        }
    }

    private static func optional(_ s: OpaquePointer?, _ column: Int32) -> Double? {
        sqlite3_column_type(s, column) == SQLITE_NULL ? nil : sqlite3_column_double(s, column)
    }

    private func query<T>(_ sql: String, _ arguments: [Int64], _ row: (OpaquePointer?) -> T) -> [T] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        for (i, value) in arguments.enumerated() { sqlite3_bind_int64(statement, Int32(i + 1), value) }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(row(statement)) }
        return rows
    }
}

/// Averages the 2-second readings into one history row per minute.
@MainActor
final class HistoryRecorder {
    private var minute = 0
    private var count = 0.0
    private var sums = (cpu: 0.0, gpu: 0.0, temp: 0.0, tempCount: 0.0, mem: 0.0, watts: 0.0, wattsCount: 0.0, down: 0.0, up: 0.0)
    private var pressure = 0, displays = 0
    private var battery: Double?
    private var charging = false
    private var apps: [String: Double] = [:]

    func add(_ stats: Stats, displays: Int) {
        let now = Int(Date().timeIntervalSince1970) / 60
        if minute != 0 && now != minute { flush() }
        minute = now
        count += 1
        sums.cpu += stats.cpuPercent
        sums.gpu += Double(stats.gpuPercent ?? 0)
        if let t = stats.cpuTemp { sums.temp += t; sums.tempCount += 1 }
        sums.mem += Double(stats.memory?.used ?? 0)
        if let w = stats.power?.systemWatts { sums.watts += w; sums.wattsCount += 1 }
        sums.down += stats.download
        sums.up += stats.upload
        pressure = max(pressure, stats.memory.map { $0.pressure == .high ? 2 : $0.pressure == .moderate ? 1 : 0 } ?? 0)
        self.displays = max(self.displays, displays)
        battery = stats.battery.map { Double($0.percent) }
        charging = charging || (stats.battery?.charging ?? false)
        for user in stats.cpuUsers { apps[user.name, default: 0] += user.percent }
    }

    private func flush() {
        guard count > 0 else { return }
        let sample = HistoryStore.Sample(
            date: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
            cpu: sums.cpu / count, gpu: sums.gpu / count,
            temperature: sums.tempCount > 0 ? sums.temp / sums.tempCount : nil,
            memoryUsed: sums.mem / count, pressure: pressure, battery: battery, charging: charging,
            watts: sums.wattsCount > 0 ? sums.watts / sums.wattsCount : nil,
            download: sums.down / count, upload: sums.up / count, displays: displays)
        let top = apps.map { ($0.key, $0.value / count) }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.prefix(5)
        HistoryStore.shared.record(sample, apps: Array(top))
        count = 0
        sums = (0, 0, 0, 0, 0, 0, 0, 0, 0)
        pressure = 0; displays = 0; charging = false
        apps = [:]
    }
}
