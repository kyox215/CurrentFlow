import Foundation

enum RefreshPolicy {
    static let key = "refreshIntervalSeconds"
    static let defaultInterval: TimeInterval = 1
    static let minimum: TimeInterval = 0.5
    static let maximum: TimeInterval = 300
    static let presets: [TimeInterval] = [0.5, 1, 2, 5, 10, 30, 60]

    static func isValid(_ interval: TimeInterval) -> Bool {
        interval.isFinite && interval >= minimum && interval <= maximum
    }

    static func restored(_ interval: TimeInterval?) -> TimeInterval {
        interval.flatMap { isValid($0) ? $0 : nil } ?? defaultInterval
    }

    static func label(_ interval: TimeInterval) -> String {
        String(format: "%g 秒", interval)
    }

    static func parse(_ string: String) -> TimeInterval? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let interval = Double(normalized), isValid(interval) else { return nil }
        return interval
    }
}

struct PowerSample {
    let timestamp: Date
    let amps: Double?
}

enum PowerHistory {
    static func recent(_ samples: [PowerSample], at now: Date) -> [PowerSample] {
        samples.filter { let age = now.timeIntervalSince($0.timestamp); return age >= 0 && age <= 60 }
    }
}
