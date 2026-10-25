import Foundation

@main struct ProcessPowerTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ text: String) { count += 1; precondition(value(), text) }
    static func counter(_ pid: Int32, _ energy: UInt64, group: String = "app:browser", start: UInt64 = 10) -> ProcessEnergyCounter {
        ProcessEnergyCounter(pid: pid, startTime: start, energyNanojoules: energy, groupID: group, name: group)
    }
    static func main() {
        let now = Date()
        let before = ProcessEnergyBatch(timestamp: now, uptime: 100, available: true,
                                        counters: [counter(1, 1_000_000_000), counter(2, 500_000_000), counter(3, 1000, group: "system")])
        var after = ProcessEnergyBatch(timestamp: now.addingTimeInterval(2), uptime: 102, available: true,
                                       counters: [counter(1, 3_000_000_000), counter(2, 1_500_000_000), counter(3, 1_000_001_000, group: "system")])
        let s = ProcessPowerPolicy.sample(previous: before, current: after)
        check(s.phase == .ready && s.rows.count == 2, "就绪后按应用合并排行")
        check(s.rows[0].watts == 1.5 && s.rows[0].processCount == 2, "主程序与 Helper 各自能量差只相加一次")
        check(s.rows[1].watts == 0.5, "纳焦除以真实秒数换算 W")
        var timedBefore = before, timedAfter = after
        var first = counter(1, 1_000_000_000), next = counter(1, 3_000_000_000)
        first.sampledUptime = 99.5; next.sampledUptime = 102
        timedBefore.counters = [first]; timedAfter.counters = [next]
        check(ProcessPowerPolicy.sample(previous: timedBefore, current: timedAfter).rows.first?.watts == 0.8, "首轮应用名称查询较慢时，按每个 PID 自己的读取时间计算，避免冷扫描抬高功率")
        check(s.updatedAt == after.timestamp && s.isFresh(at: after.timestamp), "时间来自实际批次")
        check(!s.isFresh(at: after.timestamp.addingTimeInterval(7)), "超时排行不继续宣称实时")
        check(!s.isFresh(at: after.timestamp.addingTimeInterval(-2)), "未来的异常时间不可显示")
        check(ProcessPowerPolicy.sample(previous: nil, current: after).phase == .sampling, "第一次读取建立基线，不能用进程一生累计能量显示 W")
        check(ProcessPowerPolicy.sample(previous: before, current: ProcessEnergyBatch()).phase == .unavailable, "权限或接口不可用明确显示缺失")
        after.counters = [counter(1, 9_000_000_000, start: 20)]
        check(ProcessPowerPolicy.sample(previous: before, current: after).rows.isEmpty, "PID 重用时不计算旧进程与新进程之差")
        after.counters = [counter(1, 1)]
        check(ProcessPowerPolicy.sample(previous: before, current: after).rows.isEmpty, "计数器回退不下溢")
        after.counters = [counter(1, 1_000_000_000), counter(4, 2_000_000_000)]
        check(ProcessPowerPolicy.sample(previous: before, current: after).rows.isEmpty, "零差值不占排行，新进程等待自己的第二个样本")
        after.counters = [counter(1, 3_000_000_000), counter(1, 3_000_000_000)]
        check(ProcessPowerPolicy.sample(previous: before, current: after).rows.first?.watts == 1, "重复 PID 不重复计算")
        after.counters = [counter(1, UInt64.max)]
        check(ProcessPowerPolicy.sample(previous: before, current: after).rows.isEmpty, "异常巨额能量不破坏排行")
        after.uptime = 200
        after.timestamp = now.addingTimeInterval(100)
        check(ProcessPowerPolicy.sample(previous: before, current: after).phase == .sampling, "长时间停采样必须重建基线")
        after.uptime = 102
        check(ProcessPowerPolicy.sample(previous: before, current: after).phase == .sampling, "跨休眠或系统时钟跳变不计算错误平均值")
        var older = before, newer = before
        older.counters = (1...5).map { counter(Int32($0), 100, group: "app:\($0)") }
        newer.counters = (1...5).map { counter(Int32($0), UInt64($0) * 1_000_000_000 + 100, group: "app:\($0)") }
        newer.timestamp = now.addingTimeInterval(2); newer.uptime = 102
        let top = ProcessPowerPolicy.sample(previous: older, current: newer)
        check(top.rows.count == 3 && top.rows.map(\.id) == ["app:5", "app:4", "app:3"], "只列出按功率排序的前三名")
        check(ProcessPowerPolicy.appPath(in: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper") == "/Applications/Browser.app", "嵌套 Helper 归属外层应用")
        check(ProcessPowerPolicy.appPath(in: "/usr/libexec/bird") == nil, "系统进程不假冒应用")
        check(precisePowerReading(0.033) == "0.033 W", "低功耗不能四舍五入成零")
        check(precisePowerReading(1.234, estimated: true) == "≈1.23 W", "排行明确标为估算 W")
        check(precisePowerReading(nil) == "— W" && precisePowerReading(.nan) == "— W", "缺失和非法值不冒充 0 W")
        print("PASS: \(count) process power checks — deltas / grouping / top three / PID reuse / reset / freshness / precision")
    }
}
