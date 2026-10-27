import Foundation
import SQLite3

@main
struct HistoryStoreTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1; precondition(condition, message)
    }
    static func sample(_ second: Double, watts: Double? = 36) -> HistoryRecord {
        var s = PowerSnapshot.demo(0)
        s.timestamp = Date(timeIntervalSince1970: second)
        s.systemUpdatedAt = s.timestamp; s.systemWatts = watts
        s.systemSource = .sensor; s.componentsUpdatedAt = s.timestamp; s.displayUpdatedAt = s.timestamp
        return HistoryRecord(s)
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CurrentFlowHistoryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base: Int64 = 1_800_000_000
        let now = Date(timeIntervalSince1970: Double(base + 100))
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = HistoryStore(url: url)
        try await store.record(sample(Double(base) + 0.1), uptime: 100, now: now)
        try await store.record(sample(Double(base) + 0.8, watts: 99), uptime: 100.7, now: now)
        try await store.record(sample(Double(base + 1) + 0.1), uptime: 101, now: now)
        var result = try await store.summary(from: base, through: base + 10, now: now)
        check(result.recorded == 2 && result.valid == 2, "duplicate seconds ignored")
        check(abs(result.wattHours - 0.01) < 0.000001, "trapezoidal Wh from actual time, duplicates do not distort")
        let rows = try await store.seconds(around: base, now: now)
        check(rows.first?.watts == 36, "first observation retained within second")
        check(rows.first?.cpu == 7.8 && rows.first?.source == "sensor", "component and source metadata persist")
        let reopened = HistoryStore(url: url)
        let recovered = try await reopened.summary(from: base, through: base + 10, now: now)
        check(recovered.recorded == 2, "new connection recovers persisted data")
        try await reopened.record(sample(Double(base + 2) + 0.1), uptime: 200, now: now)
        result = try await reopened.summary(from: base, through: base + 10, now: now)
        check(abs(result.wattHours - 0.01) < 0.000001, "restart does not integrate across sessions")
        try await reopened.record(sample(Double(base + 3) + 0.1, watts: nil), uptime: 201, now: now)
        try await reopened.record(sample(Double(base + 4) + 0.1, watts: .nan), uptime: 202, now: now)
        try await reopened.record(sample(Double(base + 5) + 0.1, watts: -1), uptime: 203, now: now)
        try await reopened.record(sample(Double(base + 6) + 0.1), uptime: 204, now: now)
        result = try await reopened.summary(from: base, through: base + 10, now: now)
        check(result.recorded == 7 && result.valid == 4, "invalid, negative and missing power retained as NULL, never zero")
        check(abs(result.wattHours - 0.01) < 0.000001, "no integration across invalid values")
        try await reopened.record(sample(Double(base + 8) + 0.1), uptime: 206, now: now)
        result = try await reopened.summary(from: base, through: base + 10, now: now)
        check(abs(result.wattHours - 0.01) < 0.000001, "no integration across missing second")
        try await reopened.record(sample(Double(base + 9) + 0.1), uptime: 306, now: now)
        result = try await reopened.summary(from: base, through: base + 10, now: now)
        check(abs(result.wattHours - 0.01) < 0.000001, "wall clock and monotonic mismatch does not integrate")
        await reopened.breakContinuity()
        try await reopened.record(sample(Double(base + 10) + 0.1), uptime: 307, now: now)
        result = try await reopened.summary(from: base, through: base + 10, now: now)
        check(abs(result.wattHours - 0.01) < 0.000001, "sleep/demo reset breaks continuity")
        try await reopened.record(sample(Double(base + 11) + 0.1, watts: 0), uptime: 308, now: now)
        result = try await reopened.summary(from: base + 11, through: base + 11, now: now)
        check(result.valid == 1 && result.peak == 0 && result.wattHours == 0, "real zero remains valid, boundary edge excluded")
        var stale = PowerSnapshot.demo(0)
        stale.systemUpdatedAt = stale.timestamp.addingTimeInterval(-3)
        check(HistoryRecord(stale).watts == nil, "stale system cache not recorded as fresh power")
        stale.systemUpdatedAt = stale.timestamp.addingTimeInterval(1)
        check(HistoryRecord(stale).watts == nil, "future sensor timestamp rejected")
        stale.systemUpdatedAt = stale.timestamp; stale.available = false
        check(HistoryRecord(stale).watts == nil, "unavailable reading retains missing power")
        let firstHour = HistoryTime.parse("2026-10-25 02:30:00 +0200")!
        let secondHour = HistoryTime.parse("2026-10-25 02:30:00 +0100")!
        check(secondHour.timeIntervalSince(firstHour) == 3600, "DST repeated hour has distinct second-level addresses")
        check(HistoryTime.parse("2026-02-30 02:30:00 +0100") == nil, "invalid calendar date rejected")
        check(HistoryTime.parse("2026-10-25 02:30:00") == nil, "ambiguous local time requires explicit offset")
        check(HistoryTime.label(Int64(firstHour.timeIntervalSince1970), timeZone: TimeZone(identifier: "Europe/Rome")!) == "2026-10-25 02:30:00 +0200", "history labels preserve historical UTC offset")
        var components = PowerSnapshot.demo(0)
        components.componentsUpdatedAt = components.timestamp.addingTimeInterval(0.02)
        check(HistoryRecord(components).cpu == components.cpuWatts && HistoryRecord(components).gpu == components.gpuWatts, "IOReport completion slightly after SMC timestamp stays valid")
        components.componentsUpdatedAt = components.timestamp.addingTimeInterval(1)
        check(HistoryRecord(components).cpu == nil, "implausibly future component timestamp rejected")
        let expiry = base + HistoryStore.retention
        try await reopened.prune(now: expiry)
        result = try await reopened.summary(from: base, through: base + 20, now: Date(timeIntervalSince1970: Double(expiry)))
        check(result.recorded == 10, "exact seven-day lower boundary removed")
        let firstRemaining = try await reopened.seconds(around: base, now: Date(timeIntervalSince1970: Double(expiry)))
        check(firstRemaining.first?.second == base + 1, "one second inside boundary retained")
        // Backward clocks hide future points, never resurrect already removed samples.
        result = try await reopened.summary(from: base - 10, through: base, now: Date(timeIntervalSince1970: Double(base)))
        check(result.recorded == 0, "backward clock hides future records")
        try await reopened.record(sample(Double(base)), uptime: 500, now: Date(timeIntervalSince1970: Double(base)))
        let backwards = try await reopened.summary(from: base, through: expiry, now: Date(timeIntervalSince1970: Double(expiry)))
        check(backwards.recorded == 10, "backward clock cannot recreate expired seconds")
        try await reopened.prune(now: expiry + 100)
        result = try await reopened.summary(from: base, through: expiry + 100, now: Date(timeIntervalSince1970: Double(expiry + 100)))
        check(result.recorded == 0, "long sleep/exit followed by reopen expires entire old range")

        // Bulk fixture represents a full seven-day history, without a week-long wait.
        let largeURL = directory.appendingPathComponent("large.sqlite3")
        let large = HistoryStore(url: largeURL)
        try await large.prune(now: base)
        var db: OpaquePointer?
        precondition(sqlite3_open(largeURL.path, &db) == SQLITE_OK)
        let sql = """
            WITH RECURSIVE seq(x) AS (SELECT \(base - HistoryStore.retention + 1) UNION ALL SELECT x+1 FROM seq WHERE x<\(base))
            INSERT INTO samples SELECT x,x+0.1,36,7,2,3,52,16,1,'charging',0,'sensor',x+0.1,'fixture',0.01,1 FROM seq;
            """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = Date()
        result = try await large.summary(from: base - HistoryStore.retention + 1, through: base, now: Date(timeIntervalSince1970: Double(base)))
        let elapsed = Date().timeIntervalSince(before)
        check(result.recorded == 604800 && result.valid == 604800, "seven days preserve all raw seconds")
        check(result.buckets.count <= 600, "long-range UI loads at most 600 aggregate points")
        check(result.buckets.allSatisfy(\.complete), "complete buckets include all raw samples")
        check(abs(result.wattHours - 6047.99) < 0.001, "range excludes incoming edge from outside range")
        check(elapsed < 5, "full-range indexed query finishes within five seconds")
        let detail = try await large.seconds(around: base - 100000, now: Date(timeIntervalSince1970: Double(base)))
        check(detail.count == 11 && detail[5].second == base - 100000, "second-level lookup bounded to eleven rows")
        let size = (try FileManager.default.attributesOfItem(atPath: largeURL.path)[.size] as? NSNumber)?.intValue ?? 0
        check(size < 150_000_000, "seven-day storage stays bounded")
        print("PASS: \(checks) history checks; 604800 raw rows → \(result.buckets.count) buckets in \(String(format: "%.3f", elapsed))s; db \(size) bytes")
    }
}
