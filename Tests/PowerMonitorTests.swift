import Foundation
import AppKit

private final class ReaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var active = 0
    private(set) var peak = 0
    var delay: TimeInterval = 0.03
    let idleBattery: Bool
    init(idleBattery: Bool = false) { self.idleBattery = idleBattery }
    func read() -> PowerSnapshot {
        lock.lock(); count += 1; active += 1; peak = max(peak, active); let number = count; lock.unlock()
        Thread.sleep(forTimeInterval: delay)
        let amps = idleBattery ? 0 : Double(number) / 10
        let result = PowerFusion.merge(.demo(0), live: LiveSensorReadings(batteryAmps: amps, batteryVolts: 12.4, inputAmps: 3, inputVolts: 20, systemWatts: 20 + Double(number) / 10), external: true, at: Date())
        lock.lock(); active -= 1; lock.unlock()
        return result
    }
}

@main
struct PowerMonitorTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        precondition(condition(), message)
    }
    @MainActor static func run(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    @MainActor static func main() {
        let domain = "local.currentflow.monitor-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0.5, forKey: RefreshPolicy.key)
        let probe = ReaderProbe(idleBattery: true)
        let monitor = PowerMonitor(defaults: defaults, observeSystem: false, readSource: { probe.read() })
        run(1.6)
        check(monitor.sampleCount >= 3, "连续采样成功，不能只更新时间戳")
        check(monitor.snapshot.batteryAmps == 0, "电池待机为零时仍记录整机功耗")
        check(monitor.history.count >= 3, "历史包含每次新测量")
        check(Set(monitor.history.compactMap(\.watts)).count >= 3, "历史数值持续变化")
        check(monitor.history.last?.watts == monitor.snapshot.systemWatts, "图表功耗与主界面使用相同真实读数")
        check(monitor.setRefreshInterval(1), "修改刷新间隔")
        let start = monitor.sampleCount
        run(1.2)
        check(monitor.sampleCount > start && monitor.sampleCount <= start + 3, "更换定时器且无重复计时器")
        check(!monitor.setRefreshInterval(0), "非法间隔不生效")
        monitor.stop()
        let stopped = monitor.sampleCount
        run(0.65)
        check(monitor.sampleCount == stopped, "停止后不再采样或回写")

        let cacheStamp = Date().addingTimeInterval(-10)
        let cached = PowerMonitor(defaults: defaults, observeSystem: false, readSource: {
            var s = PowerSnapshot.demo(2)
            s.systemUpdatedAt = cacheStamp
            s.batteryUpdatedAt = Date()
            return s
        })
        run(1.1)
        check(cached.sampleCount >= 2 && cached.history.count == 1, "反复读取同一功耗缓存不会伪造新采样")
        check(cached.history.first?.timestamp == cacheStamp, "功耗时间不跟随电池读取时间改变")
        cached.stop()
        let missing = PowerMonitor(defaults: defaults, observeSystem: false, readSource: {
            var s = PowerSnapshot.demo(2)
            s.systemWatts = nil
            return s
        })
        run(0.1)
        check(missing.history.count == 1 && missing.history.first?.watts == nil, "缺失功耗记录为空值，曲线不能把它画成零瓦")
        missing.stop()

        let slowProbe = ReaderProbe()
        slowProbe.delay = 0.25
        let before = Date()
        let slow = PowerMonitor(defaults: defaults, observeSystem: false, readSource: { slowProbe.read() })
        check(Date().timeIntervalSince(before) < 0.15, "慢硬件读取不阻塞主线程初始化")
        for _ in 0..<10 { slow.refresh() }
        run(0.6)
        check(slowProbe.peak == 1, "重入刷新必须串行读取")
        slow.refresh()
        slow.selectDemo(1)
        run(0.4)
        check(slow.snapshot.flow == .discharging && slow.demoMode == 1, "旧异步读取不能覆盖刚选择的演示状态")
        slow.selectDemo(nil)
        run(0.4)
        check(slow.snapshot.liveCurrents && slow.snapshot.flow == .charging, "退出演示后恢复真实读取")
        slow.stop()
        print("PASS: \(count) running monitor checks — changing values / timers / background read / coalescing / stale result / stop")
    }
}
