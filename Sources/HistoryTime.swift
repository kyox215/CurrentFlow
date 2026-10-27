import Foundation

// Include a numeric UTC offset so the repeated hour at a DST transition is unambiguous.
enum HistoryTime {
    static func formatter(timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.isLenient = false
        return formatter
    }
    static func label(_ second: Int64, timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone).string(from: Date(timeIntervalSince1970: Double(second)))
    }
    static func parse(_ text: String) -> Date? {
        guard let value = formatter().date(from: text),
              text.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}$"#, options: .regularExpression) != nil else { return nil }
        // Round-trip in the provided offset to reject lenient calendar rollover.
        let suffix = String(text.suffix(5))
        let hours = Int(suffix.dropFirst().prefix(2)) ?? 99
        let minutes = Int(suffix.suffix(2)) ?? 99
        guard hours <= 14, minutes < 60, hours < 14 || minutes == 0,
              let zone = TimeZone(secondsFromGMT: (suffix.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)),
              formatter(timeZone: zone).string(from: value) == text else { return nil }
        return value
    }
}
