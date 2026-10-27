import Foundation
import AppKit

@main
struct HistoryMonitorTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    @MainActor static func run(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    @MainActor static func main() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CurrentFlowHistoryMonitor-" + UUID().uuidString)
        let domain = "local.currentflow.history-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        defaults.set(60, forKey: RefreshPolicy.key)
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite3"))
        let monitor = PowerMonitor(defaults: defaults, observeSystem: false, historyStore: store, readSource: {
            var s = PowerSnapshot.demo(0)
            s.systemUpdatedAt = s.timestamp; s.systemSource = .sensor
            return s
        })
        run(4.3)
        check(!monitor.panelVisible && !monitor.detailsExpanded, "collection independent of panel")
        check(monitor.sampleCount == 1, "sixty-second display preference remains unchanged")
        var summary: HistorySummary?
        Task { summary = try? await store.summary(from: Int64(Date().timeIntervalSince1970) - 60, through: Int64(Date().timeIntervalSince1970)) }
        run(0.2)
        check((summary?.valid ?? 0) >= 4, "one-second history despite sixty-second display")
        check(monitor.historyError == nil, "no persistence error")
        monitor.selectDemo(1)
        let before = summary?.recorded
        run(1.2)
        Task { summary = try? await store.summary(from: Int64(Date().timeIntervalSince1970) - 60, through: Int64(Date().timeIntervalSince1970)) }
        run(0.2)
        check(summary?.recorded == before, "demo observations never pollute live history")
        monitor.selectDemo(nil)
        _ = monitor.setRefreshInterval(0.5)
        run(2.2)
        Task { summary = try? await store.summary(from: Int64(Date().timeIntervalSince1970) - 60, through: Int64(Date().timeIntervalSince1970)) }
        run(0.2)
        check((summary?.recorded ?? 0) <= (before ?? 0) + 4, "half-second reads deduplicate persisted seconds")
        check(monitor.sampleCount >= 6, "half-second display still updates")
        monitor.stop()
        let stopped = monitor.sampleCount
        run(1.1)
        check(monitor.sampleCount == stopped, "history and display stop cleanly")
        let brokenURL = directory.appendingPathComponent("not-a-directory")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data("file".utf8).write(to: brokenURL)
        let broken = PowerMonitor(defaults: defaults, observeSystem: false,
                                  historyStore: HistoryStore(url: brokenURL.appendingPathComponent("history.sqlite3")),
                                  readSource: { PowerSnapshot.demo(0) })
        run(0.3)
        check(broken.historyError != nil && broken.sampleCount > 0, "storage failure surfaced while live panel continues")
        broken.stop()
        print("PASS: \(checks) history monitor checks — closed panel / 60s display / 1s history / demo isolation / 0.5s display / shutdown / storage error")
    }
}
