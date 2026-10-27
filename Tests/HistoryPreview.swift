import AppKit
import SwiftUI
import SQLite3

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var monitor: PowerMonitor!
    var model: HistoryExplorerModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        NSApp.setActivationPolicy(.accessory)
        monitor = PowerMonitor(observeSystem: false, readSource: { PowerSnapshot() })
        monitor.stop() // No hardware collection and no writes to any real history.
        let i = args.firstIndex(of: "--data")!
        let store = HistoryStore(url: URL(fileURLWithPath: args[i + 1]))
        var database: OpaquePointer?, statement: OpaquePointer?
        precondition(sqlite3_open_v2(args[i + 1], &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        precondition(sqlite3_prepare_v2(database, "SELECT MAX(second) FROM samples", -1, &statement, nil) == SQLITE_OK)
        precondition(sqlite3_step(statement) == SQLITE_ROW)
        let anchor = sqlite3_column_int64(statement, 0)
        sqlite3_finalize(statement); sqlite3_close(database)
        if args.contains("--error") {
            model = HistoryExplorerModel(now: anchor, clock: { anchor }, summary: { _, _, _ in throw NSError(domain: "演示读取错误", code: 1, userInfo: [NSLocalizedDescriptionKey: "演示错误：历史暂时无法读取"]) }, seconds: { _ in [] })
        } else if args.contains("--empty") {
            model = HistoryExplorerModel(now: anchor, clock: { anchor }, summary: { _, _, _ in HistorySummary() }, seconds: { _ in [] })
        } else {
            model = HistoryExplorerModel(now: anchor, clock: { anchor }, summary: { start, end, budget in
                try await store.summary(from: start, through: end, maxBuckets: budget)
            }, seconds: { second in try await store.seconds(around: second) })
        }
        let small = args.contains("--small")
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1500, height: 960)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: args.contains("--large") ? min(1060, screen.width - 60) : (small ? 600 : 720), height: args.contains("--large") ? min(860, screen.height - 70) : (small ? 468 : 600)), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "功耗历史 · 演示数据"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: HistoryView(monitor: monitor, model: model, demonstration: true))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.setVisible(true)
        if args.contains("--unfocused") {
            // Presentation-only capture mode; keyboard focus remains unchanged in the product.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.window.makeFirstResponder(nil)
            }
        }
    }
    func windowWillClose(_ notification: Notification) { model.setVisible(false); NSApp.terminate(nil) }
}

@main
struct HistoryPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
