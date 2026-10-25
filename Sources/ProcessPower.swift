import Foundation
import Darwin

struct ProcessEnergyCounter: Sendable {
    let pid: Int32
    let startTime: UInt64
    let energyNanojoules: UInt64
    let groupID: String
    let name: String
    var sampledUptime: TimeInterval?
}

struct ProcessEnergyBatch: Sendable {
    var timestamp = Date()
    var uptime = ProcessInfo.processInfo.systemUptime
    var available = false
    var counters: [ProcessEnergyCounter] = []
}

struct ProcessPowerRow: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    var watts: Double
    var processCount: Int
}

struct ProcessPowerSnapshot: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case idle, sampling, ready, unavailable }
    var phase: Phase = .idle
    var rows: [ProcessPowerRow] = []
    var updatedAt: Date?

    func isFresh(at now: Date) -> Bool {
        guard let updatedAt else { return false }
        return (-1...6).contains(now.timeIntervalSince(updatedAt))
    }

    static func preview() -> Self {
        Self(phase: .ready, rows: [
            ProcessPowerRow(id: "browser", name: "浏览器", watts: 1.243, processCount: 6),
            ProcessPowerRow(id: "editor", name: "视频剪辑", watts: 0.582, processCount: 2),
            ProcessPowerRow(id: "currentflow", name: "电流脉动", watts: 0.031, processCount: 1)
        ], updatedAt: Date())
    }
}

enum ProcessPowerPolicy {
    static func sample(previous: ProcessEnergyBatch?, current: ProcessEnergyBatch) -> ProcessPowerSnapshot {
        guard current.available else { return ProcessPowerSnapshot(phase: .unavailable) }
        guard let previous, previous.available else { return ProcessPowerSnapshot(phase: .sampling) }
        let seconds = current.uptime - previous.uptime
        let wallSeconds = current.timestamp.timeIntervalSince(previous.timestamp)
        guard seconds.isFinite, (0.1...10).contains(seconds), abs(wallSeconds - seconds) < 2 else {
            return ProcessPowerSnapshot(phase: .sampling)
        }
        let old = Dictionary(previous.counters.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: ProcessPowerRow] = [:]
        var seen = Set<Int32>()
        for item in current.counters where seen.insert(item.pid).inserted {
            guard let before = old[item.pid], before.startTime == item.startTime,
                  before.groupID == item.groupID, item.energyNanojoules >= before.energyNanojoules else { continue }
            // ri_energy_nj is task CPU-side energy, not billed energy or total
            // app energy. Every PID contributes its own delta exactly once.
            // Initial app-name discovery can take longer than a warm scan.
            // Use each PID's own read times so that delay does not inflate W.
            let elapsed = item.sampledUptime.flatMap { next in before.sampledUptime.map { next - $0 } } ?? seconds
            guard elapsed.isFinite, (0.1...10).contains(elapsed) else { continue }
            let watts = Double(item.energyNanojoules - before.energyNanojoules) / 1e9 / elapsed
            guard watts.isFinite, watts > 0, watts <= 1000 else { continue }
            var row = groups[item.groupID] ?? ProcessPowerRow(id: item.groupID, name: item.name, watts: 0, processCount: 0)
            row.watts += watts
            row.processCount += 1
            groups[item.groupID] = row
        }
        let rows = groups.values.filter { $0.watts <= 1000 }.sorted {
            if $0.watts != $1.watts { return $0.watts > $1.watts }
            return $0.id < $1.id
        }
        return ProcessPowerSnapshot(phase: .ready, rows: Array(rows.prefix(3)), updatedAt: current.timestamp)
    }

    static func appPath(in executable: String) -> String? {
        // The outer app owns nested Helper.app processes too.
        guard let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<range.upperBound].dropLast())
    }
}

final class ProcessPowerReader: @unchecked Sendable {
    static let shared = ProcessPowerReader()
    private let lock = NSLock()
    private var identities: [Int32: (start: UInt64, group: String, name: String)] = [:]
    private var appNames: [String: String] = [:]

    func read() -> ProcessEnergyBatch {
        lock.lock()
        defer { lock.unlock() }
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return ProcessEnergyBatch() }
        let capacity = min(32768, max(4096, Int(needed) / MemoryLayout<Int32>.stride + 256))
        var ids = [Int32](repeating: 0, count: capacity)
        let bytes = ids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return ProcessEnergyBatch() }
        let count = min(capacity, Int(bytes) / MemoryLayout<Int32>.stride)
        var counters: [ProcessEnergyCounter] = []
        var alive = Set<Int32>()
        for pid in ids.prefix(count) where pid > 0 && alive.insert(pid).inserted {
            var info = rusage_info_v6()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
            }
            guard result == 0 else { continue }
            let sampledUptime = ProcessInfo.processInfo.systemUptime
            let identity = identity(pid: pid, start: info.ri_proc_start_abstime)
            counters.append(ProcessEnergyCounter(pid: pid, startTime: info.ri_proc_start_abstime,
                                                 energyNanojoules: info.ri_energy_nj,
                                                 groupID: identity.group, name: identity.name, sampledUptime: sampledUptime))
        }
        identities = identities.filter { alive.contains($0.key) }
        // A supported struct with every energy field stuck at zero does not
        // establish that process energy is actually available on this system.
        return ProcessEnergyBatch(timestamp: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                                  available: counters.contains { $0.energyNanojoules > 0 }, counters: counters)
    }

    private func identity(pid: Int32, start: UInt64) -> (group: String, name: String) {
        if let cached = identities[pid], cached.start == start { return (cached.group, cached.name) }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let length = pathBuffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let path = length > 0 ? String(cString: pathBuffer) : ""
        let group: String, name: String
        if let app = ProcessPowerPolicy.appPath(in: path) {
            group = "app:" + app
            if let cached = appNames[app] { name = cached }
            else {
                let url = URL(fileURLWithPath: app)
                let bundle = Bundle(url: url)
                let title = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                name = String(title.prefix(100))
                appNames[app] = name
            }
        } else {
            var buffer = [CChar](repeating: 0, count: 1024)
            let length = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            name = length > 0 ? String(cString: buffer) : (path.isEmpty ? "进程 \(pid)" : URL(fileURLWithPath: path).lastPathComponent)
            group = path.isEmpty ? "pid:\(pid):\(start)" : "exec:" + path
        }
        identities[pid] = (start, group, name)
        return (group, name)
    }
}
