import AppKit
import SwiftUI

// Native AppKit integration regression: exercise the same controller methods as
// status clicks, the history button and application reopen, using isolated defaults.
@main
struct WindowInteractionTests {
    static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        let passed = condition()
        if !passed {
            for window in NSApp.windows {
                print("WINDOW_STATE", window.title, "visible", window.isVisible, "mini", window.isMiniaturized, "key", window.isKeyWindow)
            }
            fflush(stdout)
        }
        precondition(passed, message)
    }
    @MainActor static func pump(_ duration: Double = 0.08) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            // AppKit activation/key-window changes arrive as application events,
            // not just Foundation run-loop sources.
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            _ = RunLoop.main.run(mode: .default, before: Date())
        }
    }
    @MainActor static func restoreOnly(controller: FlowWindowController) {
        controller.showHistory(); pump()
        let history = controller.historyWindow!, window = history.window!
        window.animationBehavior = .default
        var intent = "history", cycle = 0
        var updates = 0
        let began = ProcessInfo.processInfo.systemUptime
        let names: [Notification.Name] = [NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification]
        let observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                MainActor.assumeIsolated {
                    if note.name == NSWindow.didUpdateNotification { updates += 1 }
                    // Full notification sequence for the first cycle, significant
                    // transitions for later cycles. State is observed at this
                    // notification callback, after any earlier delegate handling.
                    if cycle == 1 || note.name != NSWindow.didUpdateNotification {
                        print(String(format: "TRACE %.4f", ProcessInfo.processInfo.systemUptime - began), "cycle", cycle, "intent", intent, note.name.rawValue, "panel", controller.isVisible, "history", window.isVisible, "mini", window.isMiniaturized, "key", window.isKeyWindow, "active", NSApp.isActive)
                        fflush(stdout)
                    }
                }
            }
        }
        let focusObservers = [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { note in
                MainActor.assumeIsolated {
                    print(String(format: "APP_FOCUS %.4f", ProcessInfo.processInfo.systemUptime - began), "cycle", cycle, "lastExplicitIntent", intent, note.name.rawValue, "active", NSApp.isActive, "panel", controller.isVisible, "history", window.isVisible)
                    fflush(stdout)
                }
            }
        }
        defer { (observers + focusObservers).forEach { NotificationCenter.default.removeObserver($0) } }
        for i in 1...12 {
            cycle = i; intent = "history"
            controller.showHistory(); pump(0.1)
            window.miniaturize(nil); pump(0.5)
            check(window.isMiniaturized, "targeted restore begins from minimized history")
            controller.showHistory()
            intent = "panel"
            controller.toggle(from: nil)
            pump(0.75)
            check(controller.isVisible && !(window.isVisible && !window.isMiniaturized), "targeted latest panel request must survive restore, cycle \(i), active=\(NSApp.isActive)")
            pump(1)
            check(controller.isVisible && !window.isVisible, "panel remains alone after animation settles, cycle \(i)")
            intent = "history"
            controller.showHistory(); pump(0.1)
            window.miniaturize(nil); pump(0.5)
            controller.showHistory()
            intent = "panel"; controller.toggle(from: nil)
            intent = "history"; controller.showHistory()
            pump(0.75)
            check(!controller.isVisible && window.isVisible && !window.isMiniaturized, "targeted latest history request must survive restore, cycle \(i)")
            pump(1)
            check(!controller.isVisible && window.isVisible && !window.isMiniaturized, "history remains alone after animation settles, cycle \(i)")
        }
        controller.hide(); history.suspend(); pump()
        print("PASS: \(checks) targeted window checks; 12 cycles × two restore races plus 1s settling checks; observed \(updates) history update notifications")
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        pump(0.4)
        if !app.isActive {
            let focusWindow = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 360, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            focusWindow.isReleasedWhenClosed = false
            focusWindow.title = "CurrentFlow 窗口回归验证"
            focusWindow.makeKeyAndOrderFront(nil)
            print("WAITING_FOR_NATIVE_FOCUS"); fflush(stdout)
            let deadline = Date().addingTimeInterval(60)
            while !app.isActive && Date() < deadline { pump(0.1) }
            focusWindow.orderOut(nil)
        }
        check(app.isActive, "native test application must have real focus for key-window checks")
        let domain = "local.currentflow.window-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let monitor = PowerMonitor(defaults: defaults, observeSystem: false, readSource: { .demo(0) })
        defer { monitor.stop() }
        let controller = FlowWindowController(monitor: monitor, quit: {})
        if CommandLine.arguments.contains("--restore-only") {
            restoreOnly(controller: controller)
            return
        }
        check(!controller.isVisible && !monitor.panelVisible, "cold start remains silent")
        controller.toggle(from: nil); pump()
        check(controller.isVisible && monitor.panelVisible, "first status click opens panel")
        controller.toggle(from: nil); pump()
        check(!controller.isVisible && !monitor.panelVisible, "second status click hides panel")
        controller.show(from: nil); pump()
        controller.showHistory(); pump()
        let history = controller.historyWindow!
        let window = history.window!
        window.animationBehavior = .none
        let content = window.contentView
        check(!controller.isVisible && !monitor.panelVisible && window.isVisible, "history button leaves exactly one visible window")
        // Keep the requested frame on screen. The compact default starts higher,
        // so adding the old 750pt height can trigger AppKit screen clamping.
        let screen = window.screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 900)
        let frame = CGRect(x: screen.midX - 320, y: screen.midY - 270, width: 640, height: 540)
        window.setFrame(frame, display: true)
        controller.toggle(from: nil); pump()
        check(controller.isVisible && !window.isVisible && !window.isMiniaturized, "status click while history open suspends history before showing panel")
        controller.toggle(from: nil); pump()
        check(!controller.isVisible && !window.isVisible, "repeat status click closes panel without resurrecting history")
        controller.show(from: nil); controller.showHistory(); pump()
        check(controller.historyWindow === history && window.contentView === content, "history query view is reused across toggles")
        check(window.frame == frame, "history window position and size survive toggles")
        check(window.isVisible && !controller.isVisible, "reopening history never stacks the panel")
        controller.reopen(from: nil); pump()
        check(window.isVisible && !controller.isVisible, "application reopen focuses visible history")
        window.miniaturize(nil); pump(0.4)
        check(window.isMiniaturized, "history can be minimized")
        controller.reopen(from: nil); pump(0.4)
        check(window.isVisible && !window.isMiniaturized && !controller.isVisible, "application reopen restores minimized history without a panel")
        window.miniaturize(nil); pump(0.4)
        controller.toggle(from: nil); pump(0.4)
        check(controller.isVisible && !window.isVisible && !window.isMiniaturized, "status click closes minimized history without restoring it")
        controller.reopen(from: nil); pump()
        check(controller.isVisible && !window.isVisible, "application reopen preserves an already visible panel")
        controller.showHistory(); pump()
        window.performClose(nil); pump()
        check(!window.isVisible && !controller.isVisible, "closing history leaves both windows hidden")
        controller.reopen(from: nil); pump()
        check(controller.isVisible && !window.isVisible, "reopen after closing history opens only panel")
        // A previously hidden history brought to front by AppKit must also hide the panel.
        history.present(); pump()
        check(window.isVisible && !controller.isVisible && !monitor.panelVisible, "history activation dismisses panel (panel=\(controller.isVisible), history=\(window.isVisible), key=\(window.isKeyWindow))")
        controller.show(from: nil); pump()
        let about = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 250, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        about.isReleasedWhenClosed = false
        about.makeKeyAndOrderFront(nil); pump()
        check(!controller.isVisible && !window.isVisible, "another titled application window cannot be covered by panel")
        about.orderOut(nil)
        controller.showHistory(); pump()
        NSApp.deactivate(); pump()
        check(!controller.isVisible && window.isVisible, "application deactivation leaves normal history, no floating panel")
        for _ in 0..<20 {
            controller.toggle(from: nil); pump(0.03)
            check(controller.isVisible && !window.isVisible, "rapid status switch preserves panel-only invariant")
            controller.showHistory(); pump(0.03)
            check(window.isVisible && !controller.isVisible, "rapid history switch preserves history-only invariant")
        }
        check(controller.historyWindow === history, "rapid toggles never create duplicate history windows")
        window.animationBehavior = .default
        window.miniaturize(nil); pump(0.5)
        controller.showHistory()
        controller.toggle(from: nil)
        pump(0.7)
        check(controller.isVisible && !(window.isVisible && !window.isMiniaturized), "latest panel during restore (panel=\(controller.isVisible), history=\(window.isVisible), mini=\(window.isMiniaturized), key=\(window.isKeyWindow), active=\(app.isActive))")
        controller.showHistory(); pump(0.4)
        window.miniaturize(nil); pump(0.5)
        controller.showHistory()
        controller.toggle(from: nil)
        controller.showHistory()
        pump(0.7)
        check(!controller.isVisible && window.isVisible && !window.isMiniaturized, "latest history selection wins during animation and rapid status clicks")
        check(window.contentView === content && window.frame == frame, "closing for switches retains the same query view and geometry")
        window.performClose(nil)
        controller.showHistory(); pump(0.3)
        check(controller.presentationTarget == .history && window.isVisible && !controller.isVisible, "new history request survives an earlier user close notification")
        controller.show(from: nil); pump()
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.postEvent(escape, atStart: false); pump(0.3)
        check(controller.presentationTarget == .none && !controller.isVisible && !window.isVisible, "Esc dismisses both surfaces and clears intent")
        pump(1)
        check(!controller.isVisible && !window.isVisible, "dismissed windows do not reappear after deferred notifications")
        controller.showHistory(); pump()
        window.performClose(nil); pump(0.3)
        check(controller.presentationTarget == .none && !history.isPresented && !window.isVisible, "red-button close clears document intent")
        controller.show(from: nil); pump()
        NSApp.hide(nil); pump(0.4)
        check(NSApp.isHidden && !NSApp.isActive, "native app hide actually removes app focus")
        check(controller.presentationTarget == .none && !controller.isVisible && !window.isVisible && controller.window.hidesOnDeactivate, "real focus loss dismisses the panel with native hidesOnDeactivate retained")
        pump(1)
        check(!controller.isVisible && !window.isVisible && !NSApp.isActive, "none intent never reactivates the application")
        controller.hide(); history.suspend()
        pump()
        print("PASS: \(checks) native window checks — status toggles / history reuse / geometry / minimize / close / reopen / activation / About / deactivation / rapid switching")
    }
}
