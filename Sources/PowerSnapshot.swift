import Foundation

enum BatteryFlow: String, Codable, Sendable {
    case charging, discharging, idle, unknown
    var title: String {
        switch self {
        case .charging: return "正在充电"
        case .discharging: return "正在放电"
        case .idle: return "电池待机"
        case .unknown: return "等待读数"
        }
    }
}

enum PowerDataSource: String, Codable, Sendable {
    case sensor, systemCache
    var title: String { self == .sensor ? "直接采样" : "系统缓存" }
}

struct PowerSnapshot: Codable, Sendable {
    var timestamp = Date()
    var available = false
    var batteryInstalled = false
    var externalConnected = false
    var percent: Double?
    var batteryAmps: Double?
    var batteryVolts: Double?
    // Positive means into battery; negative means battery supplies the computer.
    var batteryWatts: Double?
    var inputAmps: Double?
    var inputVolts: Double?
    var inputWatts: Double?
    var systemWatts: Double?
    var adapterRatedWatts: Double?
    var inputAmpsEstimated = false
    var inputWattsEstimated = false
    var systemEstimated = false
    var error: String?
    var batterySource: PowerDataSource = .systemCache
    var inputSource: PowerDataSource = .systemCache
    var systemSource: PowerDataSource = .systemCache
    var batteryUpdatedAt: Date?
    var inputUpdatedAt: Date?

    var liveCurrents: Bool {
        (!batteryInstalled || (batteryAmps != nil && batterySource == .sensor)) &&
        (!externalConnected || (inputAmps != nil && inputSource == .sensor)) && available
    }

    func freshnessLabel(at now: Date, interval: TimeInterval) -> String {
        guard available else { return "读取失败" }
        if liveCurrents {
            let age = max(0, now.timeIntervalSince(timestamp))
            if age > max(3, interval * 2) { return "\(Int(age)) 秒未采样" }
            return "采样 " + timestamp.formatted(date: .omitted, time: .standard)
        }
        let updates = [batteryUpdatedAt, externalConnected ? inputUpdatedAt : nil].compactMap { $0 }
        guard let oldest = updates.min() else { return "系统缓存" }
        return "缓存 \(Int(max(0, now.timeIntervalSince(oldest)))) 秒前"
    }

    var flow: BatteryFlow {
        guard batteryInstalled else { return .unknown }
        if let a = batteryAmps {
            if a > 0.05 { return .charging }
            if a < -0.05 { return .discharging }
            return .idle
        }
        return .unknown
    }

    var status: String {
        if !available { return "无法读取电源数据" }
        if !batteryInstalled { return externalConnected ? "外接电源供电" : "未检测到内置电池" }
        if externalConnected && flow == .discharging { return "电源 + 电池共同供电" }
        if externalConnected && flow == .idle { return "外接供电 · 电池待机" }
        if externalConnected && flow == .unknown { return "外接供电 · 电池读数未知" }
        return flow == .charging ? "电源供电 · 正在充电" : (flow == .unknown ? "电池读数未知" : "电池正在为电脑供电")
    }

    var adapterToComputer: Double? {
        guard externalConnected, let inputWatts else { return nil }
        guard batteryInstalled else { return inputWatts }
        guard let batteryWatts else { return nil }
        return max(0, inputWatts - max(0, batteryWatts))
    }

    static func parse(_ d: [String: Any]) -> PowerSnapshot {
        var s = PowerSnapshot()
        s.available = !d.isEmpty
        s.batteryInstalled = d["BatteryInstalled"] as? Bool ?? (d["Voltage"] != nil)
        s.externalConnected = d["ExternalConnected"] as? Bool ?? false
        let t = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = d["AdapterDetails"] as? [String: Any] ?? [:]
        if let update = (d["UpdateTime"] as? NSNumber)?.doubleValue, update > 978307200,
           update <= s.timestamp.timeIntervalSince1970 + 5 {
            s.batteryUpdatedAt = Date(timeIntervalSince1970: update)
            s.inputUpdatedAt = s.batteryUpdatedAt
        }
        func number(_ dict: [String: Any], _ key: String, max limit: Double = 1_000_000) -> Double? {
            guard let n = dict[key] as? NSNumber else { return nil }
            let v = n.doubleValue
            return v.isFinite && v >= 0 && v <= limit ? v : nil
        }
        func positive(_ v: Double?) -> Double? { v.flatMap { $0 > 0 ? $0 : nil } }
        if s.batteryInstalled {
            if let current = number(d, "CurrentCapacity"), let max = positive(number(d, "MaxCapacity")) {
                s.percent = min(100, current / max * 100)
            }
            s.batteryVolts = positive(number(d, "Voltage", max: 100_000)).map { $0 / 1000 }
            s.batteryAmps = (signedCurrent(d["InstantAmperage"]) ?? signedCurrent(d["Amperage"])).map { $0 / 1000 }
            if let amps = s.batteryAmps, let volts = s.batteryVolts { s.batteryWatts = amps * volts }
        }
        if s.externalConnected {
            s.adapterRatedWatts = positive(number(adapter, "Watts", max: 1000))
            // AdapterDetails.Current is the negotiated ceiling, never actual current draw.
            s.inputVolts = positive(number(t, "SystemVoltageIn", max: 100_000)).map { $0 / 1000 }
            s.inputAmps = number(t, "SystemCurrentIn", max: 30_000).map { $0 / 1000 }
            s.inputWatts = number(t, "SystemPowerIn", max: 1_000_000).map { $0 / 1000 }
            if s.inputWatts == nil, let a = s.inputAmps, let v = s.inputVolts {
                s.inputWatts = a * v
                s.inputWattsEstimated = true
            }
            if s.inputAmps == nil, let w = s.inputWatts, let v = s.inputVolts {
                s.inputAmps = w / v
                s.inputAmpsEstimated = true
            }
        } else {
            // Ignore cached adapter values immediately after disconnect.
            s.inputAmps = 0
            s.inputWatts = 0
        }
        s.systemWatts = number(t, "SystemLoad", max: 1_000_000).map { $0 / 1000 }
        if s.systemWatts == nil {
            if let input = s.inputWatts, let battery = s.batteryWatts {
                s.systemWatts = max(0, input - battery)
                s.systemEstimated = true
            } else if !s.batteryInstalled, let input = s.inputWatts {
                s.systemWatts = input
                s.systemEstimated = true
            }
        }
        return s
    }

    static func signedCurrent(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        // IORegistry may encode a negative signed value as unsigned 64 or 32 bits.
        var signed = Int64(bitPattern: n.uint64Value)
        if signed > Int64(Int32.max), signed <= Int64(UInt32.max) {
            signed = Int64(Int32(bitPattern: UInt32(signed)))
        }
        let result = Double(signed)
        return abs(result) <= 30_000 ? result : nil
    }

    static func demo(_ mode: Int) -> PowerSnapshot {
        let base: [String: Any] = ["BatteryInstalled": true, "CurrentCapacity": 76, "MaxCapacity": 100, "Voltage": 12_400]
        var d = base
        d["ExternalConnected"] = mode != 1
        d["InstantAmperage"] = [2400, -1500, 0, -800][mode % 4]
        d["AdapterDetails"] = ["Watts": 96]
        d["PowerTelemetryData"] = ["SystemCurrentIn": mode == 3 ? 900 : 2600, "SystemVoltageIn": 20000,
                                     "SystemPowerIn": mode == 3 ? 18000 : 52000, "SystemLoad": [20000, 18600, 52000, 27920][mode % 4]]
        return parse(d)
    }
}

func reading(_ value: Double?, unit: String, digits: Int = 2, magnitude: Bool = false) -> String {
    guard let value else { return "— " + unit }
    return String(format: "%.*f %@", digits, magnitude ? abs(value) : value, unit)
}
