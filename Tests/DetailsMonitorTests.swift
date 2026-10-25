import Foundation
import AppKit

private final class ProcessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var peak = 0
    let delay: TimeInterval
    init(delay: TimeInterval = 0) { self.delay = delay }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var maximumOverlap: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func read() -> ProcessEnergyBatch {
        lock.lock(); calls += 1; active += 1; peak = max(peak, active); let number = calls; lock.unlock()
        Thread.sleep(forTimeInterval: delay)
        let batch = ProcessEnergyBatch(available: true, counters: [
            ProcessEnergyCounter(pid: 1, startTime: 10, energyNanojoules: UInt64(number) * 1_000_000_000, groupID: "app", name: "测试应用")
        ])
        lock.lock(); active -= 1; lock.unlock()
        return batch
    }
}

@main struct DetailsMonitorTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ text: String) { count += 1; precondition(value(), text) }
    @MainActor static func run(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    @MainActor static func main() {
        let domain = "local.currentflow.details-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0.5, forKey: RefreshPolicy.key)
        let probe = ProcessProbe()
        let monitor = PowerMonitor(defaults: defaults, observeSystem: false, readSource: { .demo(0) }, processSource: { probe.read() })
        run(0.1)
        check(probe.count == 0, "菜单栏启动不扫描进程")
        monitor.setDetailsExpanded(true)
        run(0.1)
        check(probe.count == 0, "面板隐藏时即使保留展开状态也不扫描")
        monitor.panelVisible = true
        run(0.15)
        check(probe.count == 1 && monitor.processPower.phase == .sampling, "展开面板详情后先建基线")
        run(2.1)
        check(probe.count == 2 && monitor.processPower.phase == .ready, "每两秒更新排行")
        check(monitor.processPower.rows.first?.watts ?? 0 > 0, "使用新能量差值产生真实功率")
        monitor.setDetailsExpanded(false)
        let samples = monitor.sampleCount, scans = probe.count
        run(2.15)
        check(probe.count == scans, "收起详情后停止扫描进程")
        check(monitor.sampleCount > samples, "停止排行不影响整机采样")
        monitor.setDetailsExpanded(true)
        run(0.1)
        check(monitor.processPower.phase == .sampling && monitor.processPower.rows.isEmpty, "重新展开不沿用收起前的旧基线或旧排行")
        monitor.panelVisible = false
        let hidden = probe.count
        run(2.1)
        check(probe.count == hidden && monitor.processPower.phase == .idle, "关闭面板停止扫描并清理排行")
        monitor.stop()
        monitor.panelVisible = true
        run(0.1)
        check(probe.count == hidden, "停止后不因可见状态变化重启扫描")

        let slow = ProcessProbe(delay: 0.25)
        let second = PowerMonitor(defaults: defaults, observeSystem: false, readSource: { .demo(0) }, processSource: { slow.read() })
        second.panelVisible = true
        second.setDetailsExpanded(true)
        run(0.05)
        second.setDetailsExpanded(false)
        second.setDetailsExpanded(true)
        run(0.65)
        check(slow.maximumOverlap == 1, "快速收起再展开不能让旧扫描和新扫描重叠")
        check(second.processPower.phase == .sampling && second.processPower.rows.isEmpty, "旧扫描完成后不能回写过期排行")
        second.stop()
        print("PASS: \(count) details lifecycle checks — on-demand / timers / stop / core sampling / fresh baseline / slow scan")
    }
}
