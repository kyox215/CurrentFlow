import Foundation

/// One state drives chart, overview, buttons, keyboard and exact-time navigation.
struct HistoryNavigation: Equatable, Sendable {
    static let retention: Int64 = 604800
    static let minimumSpan: Int64 = 15
    static let presets: [Int64] = [300, 900, 3600, 86400, retention]
    private(set) var latest: Int64
    private(set) var span: Int64 = 3600
    private(set) var end: Int64
    private(set) var selected: Int64
    private(set) var followsLatest = true
    var oldest: Int64 { latest - Self.retention + 1 }
    var start: Int64 { end - span + 1 }
    var center: Int64 { start + (span - 1) / 2 }
    var canZoomIn: Bool { span > Self.minimumSpan }
    var canZoomOut: Bool { span < Self.retention }
    var canGoBack: Bool { start > oldest }
    var canGoForward: Bool { end < latest }

    init(now: Int64) { latest = now; end = now; selected = now }
    mutating func refresh(now: Int64) {
        latest = now
        if followsLatest { end = now; selected = now }
        clamp()
    }
    mutating func chooseSpan(_ seconds: Int64, now: Int64) {
        refresh(now: now)
        span = min(Self.retention, max(Self.minimumSpan, seconds))
        end = followsLatest ? latest : selected + span / 2
        clamp()
    }
    mutating func zoom(_ factor: Double, now: Int64) {
        guard factor.isFinite, factor > 0 else { return }
        followsLatest = false
        let size = min(Double(Self.retention), max(Double(Self.minimumSpan), Double(span) * factor))
        chooseSpan(Int64(size.rounded()), now: now)
    }
    mutating func pan(_ seconds: Int64) {
        let oldEnd = end
        end = min(latest, max(oldest + span - 1, end + seconds))
        selected += end - oldEnd
        followsLatest = false
        clamp()
    }
    mutating func center(on second: Int64) { pan(second - center) }
    mutating func select(_ second: Int64) {
        selected = min(end, max(start, second)); followsLatest = false
    }
    mutating func seek(_ second: Int64) {
        let value = min(latest, max(oldest, second))
        if value < start || value > end { end = value + span / 2 }
        selected = value; followsLatest = false; clamp()
    }
    mutating func step(_ delta: Int64) { seek(selected + delta) }
    mutating func returnToLatest(now: Int64) {
        followsLatest = true; refresh(now: now)
    }
    func second(at fraction: Double) -> Int64 {
        let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return start + Int64((Double(span - 1) * value).rounded())
    }
    private mutating func clamp() {
        end = min(latest, max(oldest + span - 1, end))
        selected = min(end, max(start, selected))
    }
    static func label(_ seconds: Int64) -> String {
        if seconds == 86400 { return "24 小时" }
        if seconds >= 86400, seconds % 86400 == 0 { return "\(seconds / 86400) 天" }
        if seconds >= 3600, seconds % 3600 == 0 { return "\(seconds / 3600) 小时" }
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }
}
