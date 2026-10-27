import Foundation
import SQLite3

struct HistoryRecord: Sendable {
    let second: Int64
    let observed: Double
    let watts: Double?
    let cpu: Double?
    let gpu: Double?
    let display: Double?
    let input: Double?
    let battery: Double?
    let external: Bool
    let flow: String
    let estimated: Bool
    let source: String
    let sensorTime: Double?

    init(_ s: PowerSnapshot) {
        observed = s.timestamp.timeIntervalSince1970
        second = Int64(floor(observed))
        func valid(_ v: Double?, signed: Bool = false) -> Double? {
            v.flatMap { $0.isFinite && (signed || $0 >= 0) ? $0 : nil }
        }
        func fresh(_ date: Date?, allowingAhead: TimeInterval = 0) -> Bool {
            date.map { (-allowingAhead...2).contains(s.timestamp.timeIntervalSince($0)) } ?? false
        }
        // A cached revision is retained as a reference, never relabelled as fresh.
        watts = s.available && fresh(s.systemUpdatedAt) ? valid(s.systemWatts) : nil
        // IOReport completes just after the SMC observation timestamp in the same read.
        cpu = fresh(s.componentsUpdatedAt, allowingAhead: 0.25) ? valid(s.cpuWatts) : nil
        gpu = fresh(s.componentsUpdatedAt, allowingAhead: 0.25) ? valid(s.gpuWatts) : nil
        display = fresh(s.displayUpdatedAt) ? valid(s.displayWatts) : nil
        input = fresh(s.inputUpdatedAt) ? valid(s.inputWatts) : nil
        battery = fresh(s.batteryUpdatedAt) ? valid(s.batteryWatts, signed: true) : nil
        external = s.externalConnected; flow = s.flow.rawValue
        estimated = s.systemEstimated; source = s.systemSource.rawValue
        sensorTime = s.systemUpdatedAt?.timeIntervalSince1970
    }
}

struct HistoryBucket: Sendable, Identifiable {
    var id: Int64 { second }
    let second: Int64
    let minimum: Double?
    let maximum: Double?
    let average: Double?
    let valid: Int
    let expected: Int
    var complete: Bool { valid == expected }
}
struct HistorySummary: Sendable {
    var buckets: [HistoryBucket] = []
    var recorded = 0
    var valid = 0
    var integratedSeconds = 0.0
    var wattHours = 0.0
    var peak: Double = 0
    var lower: Int64 = 0
    var upper: Int64 = 0
    var bucketWidth: Int64 = 1
    var average: Double? {
        guard valid > 0 else { return nil }
        return buckets.reduce(0) { $0 + ($1.average ?? 0) * Double($1.valid) } / Double(valid)
    }
}
struct HistorySecond: Sendable, Identifiable {
    var id: Int64 { second }
    let second: Int64
    let watts: Double?
    let cpu: Double?
    let gpu: Double?
    let display: Double?
    let external: Bool
    let flow: String
    let estimated: Bool
    let source: String
    let sensorTime: Double?
}

// One actor owns the connection. Inserts are bounded, indexed and off the UI thread.
// WAL + NORMAL commits one small row per second; no rewrite of the seven-day log.
actor HistoryStore {
    static let retention: Int64 = 7 * 24 * 3600
    private var db: OpaquePointer?
    private let session = UUID().uuidString
    private var previous: (second: Int64, observed: Double, uptime: Double, watts: Double)?
    private var highWater: Int64 = 0
    private var lastCleanup: Int64 = 0
    private let url: URL

    init(url: URL) { self.url = url }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier == "local.currentflow.history-candidate" ? "CurrentFlow-History-Candidate/history.sqlite3" : "CurrentFlow/history.sqlite3")
    }
    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw failure("无法打开历史库")
        }
        db = connection
        sqlite3_busy_timeout(db, 1500)
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA auto_vacuum=INCREMENTAL;")
            try execute("""
                CREATE TABLE IF NOT EXISTS samples (
                  second INTEGER PRIMARY KEY, observed REAL NOT NULL, watts REAL,
                  cpu REAL, gpu REAL, display REAL, input REAL, battery REAL,
                  external INTEGER NOT NULL, flow TEXT NOT NULL, estimated INTEGER NOT NULL,
                  source TEXT NOT NULL, sensor_time REAL, session TEXT NOT NULL,
                  energy_wh REAL NOT NULL, duration REAL NOT NULL);
                PRAGMA user_version=1;
                """)
            let statement = try prepare("SELECT COALESCE(MAX(second),0) FROM samples")
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW { highWater = sqlite3_column_int64(statement, 0) }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "CurrentFlow.History", code: 1, userInfo: [NSLocalizedDescriptionKey: message + ": " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? url.path)])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure("历史存储失败") }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure("历史查询失败") }
        return statement
    }
    private func bind(_ value: Double?, to statement: OpaquePointer, at index: Int32) {
        if let value, value.isFinite { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }
    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func number(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }
    private func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    func record(_ record: HistoryRecord, uptime: Double, now: Date = Date()) throws {
        try open()
        let nowSecond = Int64(floor(now.timeIntervalSince1970))
        try prune(now: nowSecond)
        guard record.second > highWater - Self.retention, record.second <= nowSecond,
              record.second > nowSecond - Self.retention else { previous = nil; return }
        var duration = 0.0, energy = 0.0
        if let p = previous, let watts = record.watts, record.second == p.second + 1 {
            let wall = record.observed - p.observed, elapsed = uptime - p.uptime
            // Neither wall-clock changes, sleep, missing seconds nor restarts bridge energy.
            if wall > 0, wall <= 1.75, elapsed > 0, abs(wall - elapsed) < 0.25 {
                duration = wall; energy = (p.watts + watts) * 0.5 * wall / 3600
            }
        }
        let statement = try prepare("INSERT OR IGNORE INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, record.second)
        for (offset, value) in [record.observed, record.watts, record.cpu, record.gpu, record.display, record.input, record.battery].enumerated() {
            bind(value, to: statement, at: Int32(offset + 2))
        }
        sqlite3_bind_int(statement, 9, record.external ? 1 : 0)
        bindText(record.flow, to: statement, at: 10)
        sqlite3_bind_int(statement, 11, record.estimated ? 1 : 0)
        bindText(record.source, to: statement, at: 12)
        bind(record.sensorTime, to: statement, at: 13)
        bindText(session, to: statement, at: 14)
        sqlite3_bind_double(statement, 15, energy); sqlite3_bind_double(statement, 16, duration)
        guard sqlite3_step(statement) == SQLITE_DONE else { previous = nil; throw failure("历史写入失败") }
        if sqlite3_changes(db) > 0 {
            highWater = max(highWater, record.second)
            previous = record.watts.map { (record.second, record.observed, uptime, $0) }
        } else if previous?.second != record.second { previous = nil }
    }

    // Exact open lower boundary (now - 604800, now], at most 604800 unique seconds.
    // A backwards clock cannot revive expired records; future records stay hidden.
    func prune(now: Int64) throws {
        try open()
        highWater = max(highWater, now)
        let statement = try prepare("DELETE FROM samples WHERE second <= ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, highWater - Self.retention)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("历史清理失败") }
        if now - lastCleanup >= 3600 {
            try execute("PRAGMA incremental_vacuum(32); PRAGMA wal_checkpoint(PASSIVE)")
            lastCleanup = now
        }
    }

    func summary(from start: Int64, through end: Int64, now: Date = Date(), maxBuckets: Int = 600) throws -> HistorySummary {
        try prune(now: Int64(floor(now.timeIntervalSince1970)))
        let lower = max(start, highWater - Self.retention + 1)
        let upper = min(end, Int64(floor(now.timeIntervalSince1970)))
        guard upper >= lower else { return HistorySummary() }
        let width = max(1, (upper - lower + 1 + Int64(maxBuckets) - 1) / Int64(maxBuckets))
        let statement = try prepare("""
            SELECT (second-?)/?, MIN(watts),MAX(watts),AVG(watts),COUNT(watts),COUNT(*),
                   SUM(CASE WHEN second > ? THEN energy_wh ELSE 0 END),
                   SUM(CASE WHEN second > ? THEN duration ELSE 0 END)
            FROM samples WHERE second BETWEEN ? AND ? GROUP BY (second-?)/? ORDER BY 1
            """)
        defer { sqlite3_finalize(statement) }
        for (i, v) in [lower, width, lower, lower, lower, upper, lower, width].enumerated() { sqlite3_bind_int64(statement, Int32(i + 1), v) }
        var result = HistorySummary()
        result.lower = lower; result.upper = upper; result.bucketWidth = width
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            let second = lower + sqlite3_column_int64(statement, 0) * width
            let valid = Int(sqlite3_column_int(statement, 4))
            let bucket = HistoryBucket(second: second, minimum: number(statement, 1), maximum: number(statement, 2), average: number(statement, 3), valid: valid, expected: Int(min(width, upper - second + 1)))
            result.buckets.append(bucket); result.valid += valid
            result.recorded += Int(sqlite3_column_int(statement, 5))
            result.wattHours += sqlite3_column_double(statement, 6)
            result.integratedSeconds += sqlite3_column_double(statement, 7)
            result.peak = max(result.peak, bucket.maximum ?? 0)
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw failure("历史查询中断") }
        return result
    }

    func seconds(around second: Int64, now: Date = Date()) throws -> [HistorySecond] {
        try prune(now: Int64(floor(now.timeIntervalSince1970)))
        let statement = try prepare("SELECT second,watts,cpu,gpu,display,external,flow,estimated,source,sensor_time FROM samples WHERE second BETWEEN ? AND ? ORDER BY second LIMIT 11")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, max(second - 5, highWater - Self.retention + 1))
        sqlite3_bind_int64(statement, 2, min(second + 5, Int64(floor(now.timeIntervalSince1970))))
        var result: [HistorySecond] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append(HistorySecond(second: sqlite3_column_int64(statement, 0), watts: number(statement, 1), cpu: number(statement, 2), gpu: number(statement, 3), display: number(statement, 4), external: sqlite3_column_int(statement, 5) != 0, flow: string(statement, 6), estimated: sqlite3_column_int(statement, 7) != 0, source: string(statement, 8), sensorTime: number(statement, 9)))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw failure("秒级查询中断") }
        return result
    }
    func breakContinuity() { previous = nil }
}
