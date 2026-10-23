import Foundation

@main
struct RefreshPolicyTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        precondition(condition(), message)
    }
    static func main() {
        check(RefreshPolicy.restored(nil) == 1, "未保存时每秒刷新")
        check(RefreshPolicy.restored(0) == 1, "无效保存值不能禁用定时器")
        check(RefreshPolicy.restored(.nan) == 1, "NaN 不得成为计时器间隔")
        check(RefreshPolicy.restored(7.5) == 7.5, "恢复自定义刷新间隔")
        for preset in RefreshPolicy.presets { check(RefreshPolicy.isValid(preset), "全部预设都能用于定时器") }
        check(!RefreshPolicy.isValid(.infinity), "拒绝无限间隔")
        check(!RefreshPolicy.isValid(-2), "拒绝负数")
        check(!RefreshPolicy.isValid(0.49), "拒绝过高采样频率")
        check(!RefreshPolicy.isValid(301), "拒绝超过最大间隔")
        check(RefreshPolicy.parse(" 2.5 ") == 2.5, "小数与首尾空格")
        check(RefreshPolicy.parse("2,5") == 2.5, "支持本地逗号小数")
        check(RefreshPolicy.parse("abc") == nil, "拒绝非数值")
        check(RefreshPolicy.parse("0") == nil && RefreshPolicy.parse("300.1") == nil, "输入边界校验")
        check(RefreshPolicy.parse("0.5") == 0.5 && RefreshPolicy.parse("300") == 300, "允许区间端点")
        let now = Date(timeIntervalSince1970: 1000)
        let samples = [-61.0, -60, -30, -0.5, 0, 1].map { PowerSample(timestamp: now.addingTimeInterval($0), watts: 1) }
        let recent = PowerHistory.recent(samples, at: now)
        check(recent.count == 4, "按真实 60 秒筛选，排除过期与未来读数")
        check(recent.first?.timestamp == now.addingTimeInterval(-60), "保留一分钟边界")
        let slow = [PowerSample(timestamp: now.addingTimeInterval(-300), watts: 1), PowerSample(timestamp: now, watts: 2)]
        check(PowerHistory.recent(slow, at: now).count == 1, "五分钟刷新不能显示为一分钟内的连续采样")
        let fast = (0..<121).map { PowerSample(timestamp: now.addingTimeInterval(Double($0) * -0.5), watts: 1) }
        check(PowerHistory.recent(fast, at: now).count == 121, "半秒刷新保留整分钟数据")
        check(PowerHistory.upperBound(for: []) == 5, "等待采样时保持可读 W 刻度")
        check(PowerHistory.upperBound(for: [PowerSample(timestamp: now, watts: 33)]) == 40, "功耗刻度留出顶部空间并按 5W 取整")
        check(PowerHistory.upperBound(for: [PowerSample(timestamp: now, watts: 0)]) == 5, "零功耗仍保持零基线")
        check(PowerHistory.upperBound(for: [PowerSample(timestamp: now, watts: .nan), PowerSample(timestamp: now, watts: -5)]) == 5, "无效功耗不能破坏图表范围")
        print("PASS: \(count) refresh/history checks — custom interval / restore / input validation / real-time history")
    }
}
