import AppKit
import SwiftUI

@MainActor
private final class FlowWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum WindowPresentationTarget: String { case panel, history, none }

@MainActor
final class FlowWindowController: NSObject, NSWindowDelegate {
    let window: NSPanel
    private let monitor: PowerMonitor
    private let hostingView: NSHostingView<FlowPanel>
    private(set) var historyWindow: HistoryWindowController?
    private(set) var presentationTarget: WindowPresentationTarget = .none
    private(set) var requestGeneration: UInt64 = 0
    private(set) var lastRequestReason = "initial"
    private var reconciliationScheduled = false
    private var reconciling = false
    private var reconcileAgain = false
    private var operationDepth = 0
    private var activationRequest: UInt64?
    private var focusRequest: UInt64?
    private var restoreRequest: UInt64?
    private var terminating = false
    private var placementDirty = true
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var lastAnchor: CGRect?
    private var lastScreen: NSScreen?
    private var requestedSize = PanelPlacement.preferredSize
    private var resizeScheduled = false
    private let diagnosticURL: URL?
    private let traceURL: URL?
    var isVisible: Bool { window.isVisible }

    init(monitor: PowerMonitor, quit: @escaping () -> Void) {
        self.monitor = monitor
        let args = CommandLine.arguments
        func argumentURL(_ name: String) -> URL? {
            guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
            return URL(fileURLWithPath: args[i + 1])
        }
        diagnosticURL = argumentURL("--ui-probe"); traceURL = argumentURL("--window-trace")
        window = FlowWindow(contentRect: CGRect(origin: .zero, size: PanelPlacement.preferredSize), styleMask: [.borderless], backing: .buffered, defer: false)
        hostingView = NSHostingView(rootView: FlowPanel(monitor: monitor, quit: quit))
        super.init()
        window.title = "电流脉动"
        window.identifier = NSUserInterfaceItemIdentifier("CurrentFlowPanel-v3")
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .aqua)
        window.hasShadow = true
        window.level = .floating
        // Keep NSPanel's native hidesOnDeactivate behavior.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self; window.animationBehavior = .none
        let container = NSView(frame: CGRect(origin: .zero, size: PanelPlacement.preferredSize))
        container.wantsLayer = true; container.layer?.cornerRadius = 18; container.layer?.masksToBounds = true
        window.contentView = container
        hostingView.sizingOptions = []
        if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor), hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor), hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        hostingView.rootView = FlowPanel(monitor: monitor, onSizeChange: { [weak self] in self?.requestSize($0) }, onShowHistory: { [weak self] in self?.showHistory() }, quit: quit)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.externalInteraction("outside.mouse") }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.keyCode == 53, self.presentationTarget == .panel || self.isVisible else { return false }
                self.request(.none, reason: "user.escape"); return true
            }
            return consumed ? nil : event
        }
        observe(NSApplication.didResignActiveNotification) { [weak self] _ in
            guard let self else { return }
            self.trace("app.resignActive", reason: "notification")
            if !NSApp.isActive { self.externalInteraction("app.resignActive") }
            else { self.scheduleReconciliation("stale.resignActive") }
        }
        observe(NSApplication.didBecomeActiveNotification) { [weak self] _ in self?.observed("app.becomeActive") }
        observe(NSApplication.didHideNotification) { [weak self] _ in self?.externalInteraction("app.hidden") }
        observe(NSApplication.willTerminateNotification) { [weak self] _ in
            guard let self else { return }
            self.terminating = true; self.presentationTarget = .none; self.requestGeneration &+= 1
            self.activationRequest = nil; self.focusRequest = nil; self.restoreRequest = nil
            self.trace("app.terminate", reason: "notification")
        }
        observe(NSWindow.didBecomeKeyNotification) { [weak self] notification in
            guard let self, let other = notification.object as? NSWindow else { return }
            if other !== self.window && other !== self.historyWindow?.window && other.isKeyWindow && other.styleMask.contains(.titled) {
                if self.presentationTarget == .panel { self.request(.none, reason: "other.titled.key") }
                else { self.activationRequest = nil; self.focusRequest = nil; self.restoreRequest = nil }
            }
            self.observed("window.key")
        }
        observe(NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            guard let self else { return }
            if self.lastScreen.map({ !NSScreen.screens.contains($0) }) == true { self.lastScreen = nil; self.lastAnchor = nil }
            self.placementDirty = true; self.observed("screen.changed")
        }
    }
    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in MainActor.assumeIsolated { handler(note) } })
    }
    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    func showHistory() {
        ensureHistory()
        request(.history, reason: "user.history", activate: true, restoreHistory: true)
    }
    private func ensureHistory() {
        guard historyWindow == nil else { return }
        historyWindow = HistoryWindowController(monitor: monitor, onPresent: { [weak self] in self?.showHistory() }, onClose: { [weak self] in
            self?.request(.none, reason: "user.history.close")
        }, onObservation: { [weak self] event, generation, internalClose in
            self?.trace("history." + event, reason: "lastHistoryOperation=\(generation), internalClose=\(internalClose)")
            self?.scheduleReconciliation("history." + event)
        })
    }
    func toggle(from button: NSStatusBarButton?) {
        if presentationTarget == .panel { request(.none, reason: "user.status.dismiss") }
        else { show(from: button) }
    }
    func reopen(from button: NSStatusBarButton?) {
        if presentationTarget == .history || historyWindow?.isPresented == true { showHistory() }
        else { show(from: button) }
    }
    func show(from button: NSStatusBarButton?) {
        if let button {
            lastAnchor = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
            lastScreen = button.window?.screen
        }
        placementDirty = true
        request(.panel, reason: "user.panel", activate: true)
    }
    func hide() { request(.none, reason: "user.dismiss") }
    private func externalInteraction(_ reason: String) {
        trace("external", reason: reason)
        if presentationTarget == .panel { request(.none, reason: reason) }
        else { activationRequest = nil; focusRequest = nil; restoreRequest = nil; scheduleReconciliation(reason) }
    }
    private func request(_ target: WindowPresentationTarget, reason: String, activate: Bool = false, restoreHistory: Bool = false) {
        guard !terminating else { return }
        requestGeneration &+= 1; presentationTarget = target; lastRequestReason = reason
        activationRequest = activate ? requestGeneration : nil
        focusRequest = activate ? requestGeneration : nil
        restoreRequest = restoreHistory ? requestGeneration : nil
        trace("request", reason: reason); scheduleReconciliation(reason)
    }
    private func observed(_ event: String) { trace(event, reason: "notification"); scheduleReconciliation(event) }
    private func scheduleReconciliation(_ reason: String) {
        guard !terminating, !reconciliationScheduled else { return }
        reconciliationScheduled = true
        let generation = requestGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            guard generation == self.requestGeneration else {
                self.trace("coordinator.stale", reason: reason); self.scheduleReconciliation("latest.generation"); return
            }
            self.reconcile(generation)
        }
    }
    private func reconcile(_ generation: UInt64) {
        guard !terminating, generation == requestGeneration else { return }
        guard !reconciling else { reconcileAgain = true; return }
        reconciling = true
        defer {
            reconciling = false
            if reconcileAgain { reconcileAgain = false; scheduleReconciliation("after.reentrancy") }
        }
        trace("coordinator.begin", reason: lastRequestReason)
        var changed = false
        if presentationTarget != .none, activationRequest == generation {
            activationRequest = nil
            if !NSApp.isActive { operation("app.activate") { NSApp.activate(ignoringOtherApps: true) } }
        }
        guard generation == requestGeneration else { scheduleReconciliation("newer.request"); return }
        switch presentationTarget {
        case .none:
            changed = hidePanelActual("target.none")
            if let historyWindow { changed = operation("history.suspend.none") { historyWindow.coordinatedSuspend(generation: generation) } || changed }
        case .panel:
            guard NSApp.isActive else {
                if focusRequest != generation { request(.none, reason: "inactive.panel") }
                return // A fresh explicit activation waits for didBecomeActive.
            }
            if let key = NSApp.keyWindow, key !== window, key !== historyWindow?.window, key.isVisible, key.styleMask.contains(.titled) {
                request(.none, reason: "priority.titled.window"); return
            }
            if let historyWindow { changed = operation("history.suspend.panel") { historyWindow.coordinatedSuspend(generation: generation) } || changed }
            guard generation == requestGeneration else { scheduleReconciliation("newer.after.close"); return }
            let wasVisible = window.isVisible
            if placementDirty || !wasVisible, let screen = lastScreen ?? NSScreen.main ?? NSScreen.screens.first {
                place(on: screen, anchor: lastAnchor); placementDirty = false
            }
            if !monitor.panelVisible { monitor.panelVisible = true }
            if !wasVisible || !window.isKeyWindow {
                operation("panel.makeKey") { window.makeKeyAndOrderFront(nil) }; changed = true
            }
            if !wasVisible { monitor.refresh() }
            if window.isKeyWindow { focusRequest = nil }
        case .history:
            changed = hidePanelActual("target.history")
            ensureHistory()
            guard let historyWindow else { return }
            if !NSApp.isActive { return } // A document may remain in background; never steal focus to compensate.
            let restore = restoreRequest == generation
            restoreRequest = nil
            changed = operation("history.present") { historyWindow.coordinatedPresent(generation: generation, restoreMinimized: restore, focus: focusRequest == generation) } || changed
            if historyWindow.window?.isKeyWindow == true { focusRequest = nil }
        }
        trace("coordinator.end", reason: lastRequestReason)
        if changed { recordLayout() }
    }
    @discardableResult private func hidePanelActual(_ reason: String) -> Bool {
        let changed = window.isVisible || monitor.panelVisible
        if window.isVisible { operation("panel.orderOut." + reason) { window.orderOut(nil) } }
        if monitor.panelVisible { monitor.panelVisible = false }
        return changed
    }
    @discardableResult private func operation<T>(_ reason: String, _ action: () -> T) -> T {
        operationDepth += 1; trace("operation.begin", reason: reason)
        defer { trace("operation.end", reason: reason); operationDepth -= 1 }
        return action()
    }
    private func trace(_ event: String, reason: String) {
        guard let traceURL else { return }
        let data: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime, "event": event, "reason": reason,
            "generation": requestGeneration, "target": presentationTarget.rawValue, "depth": operationDepth, "reconciling": reconciling,
            "active": NSApp.isActive, "hidesOnDeactivate": window.hidesOnDeactivate,
            "keyWindow": NSApp.keyWindow?.identifier?.rawValue ?? NSApp.keyWindow?.title ?? "none",
            "panelVisible": window.isVisible, "panelKey": window.isKeyWindow, "panelMonitorVisible": monitor.panelVisible,
            "historyVisible": historyWindow?.window?.isVisible ?? false, "historyMini": historyWindow?.window?.isMiniaturized ?? false,
            "historyKey": historyWindow?.window?.isKeyWindow ?? false]
        guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: traceURL.path) { _ = FileManager.default.createFile(atPath: traceURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: traceURL) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: bytes + Data([10])) } catch { }
    }
    private func place(on screen: NSScreen, anchor: CGRect?) {
        lastScreen = screen
        lastAnchor = anchor
        let safe = PanelPlacement.safeBounds(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
        let frame = PanelPlacement.frame(in: safe, anchor: anchor, desired: requestedSize)
        if window.frame != frame { operation("panel.frame") { window.setFrame(frame, display: true, animate: false) } }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func requestSize(_ size: CGSize) {
        guard size != requestedSize else { return }
        requestedSize = size
        guard !resizeScheduled else { return }
        resizeScheduled = true
        // Apply the measured size after SwiftUI finishes its current layout pass.
        // The native panel still owns its frame; intrinsic hosting constraints stay disabled.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard self.isVisible, let screen = self.window.screen ?? self.lastScreen else { return }
            self.place(on: screen, anchor: self.lastAnchor)
            self.recordLayout()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { request(.none, reason: "user.panel.close"); return true }
    func windowWillClose(_ notification: Notification) { observed("panel.willClose") }
    func windowDidBecomeKey(_ notification: Notification) { observed("panel.didBecomeKey") }
    func windowDidResignKey(_ notification: Notification) { observed("panel.didResignKey") }
    func windowDidChangeOcclusionState(_ notification: Notification) { observed("panel.occlusion") }
    func windowDidUpdate(_ notification: Notification) { observed("panel.update") }

    // A test run can record native bounds without relying on an offscreen preview.
    // Geometry, source freshness and readings are recorded only for this opt-in
    // diagnostic run, including while hidden, never device identity.
    func recordLayout(menuTitle: String? = nil) {
        guard let diagnosticURL, let screen = window.screen ?? lastScreen,
              let container = window.contentView else { return }
        container.layoutSubtreeIfNeeded()
        func rect(_ r: CGRect) -> [String: Double] {
            ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
        }
        let safe = PanelPlacement.safeBounds(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
        let left: CGRect? = screen.auxiliaryTopLeftArea
        let right: CGRect? = screen.auxiliaryTopRightArea
        let menuAreas = [left, right].compactMap { $0 }.filter { !$0.isEmpty }
        let data: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "screen": rect(screen.frame), "safeBounds": rect(safe), "window": rect(window.frame),
            "containerBounds": rect(container.bounds), "hostingFrame": rect(hostingView.frame), "hostingBounds": rect(hostingView.bounds),
            "windowInsideSafeBounds": safe.contains(window.frame),
            "hostingFillsContainer": hostingView.frame == container.bounds,
            "hostingOriginIsZero": hostingView.bounds.origin == .zero,
            "refreshInterval": monitor.refreshInterval,
            "sampleTimestamp": monitor.snapshot.timestamp.timeIntervalSince1970,
            "sampleCount": monitor.sampleCount,
            "menuTitle": menuTitle ?? "",
            "windowVisible": isVisible,
            "historyRequested": presentationTarget == .history,
            "presentationTarget": presentationTarget.rawValue, "requestGeneration": requestGeneration,
            "historyVisible": historyWindow?.window.map { $0.isVisible && !$0.isMiniaturized } ?? false,
            "historyMiniaturized": historyWindow?.window?.isMiniaturized ?? false,
            "historyKey": historyWindow?.window?.isKeyWindow ?? false,
            "requestedSize": ["width": requestedSize.width, "height": requestedSize.height],
            "batteryAmps": monitor.snapshot.batteryAmps as Any? ?? NSNull(),
            "inputAmps": monitor.snapshot.inputAmps as Any? ?? NSNull(),
            "systemWatts": monitor.snapshot.systemWatts as Any? ?? NSNull(),
            "cpuWatts": monitor.snapshot.cpuWatts as Any? ?? NSNull(),
            "gpuWatts": monitor.snapshot.gpuWatts as Any? ?? NSNull(),
            "displayWatts": monitor.snapshot.displayWatts as Any? ?? NSNull(),
            "wifiWatts": monitor.snapshot.wifiWatts as Any? ?? NSNull(),
            "fans": monitor.snapshot.fanSpeeds.map { ["id": $0.id, "rpm": $0.rpm] },
            "detailsExpanded": monitor.detailsExpanded,
            "detailSampleCount": monitor.detailSampleCount,
            "processPowerPhase": monitor.processPower.phase.rawValue,
            "processPowerRows": monitor.processPower.rows.map { ["name": $0.name, "watts": $0.watts, "processCount": $0.processCount] },
            "componentsUpdatedAt": monitor.snapshot.componentsUpdatedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "componentSampleDuration": monitor.snapshot.componentSampleDuration as Any? ?? NSNull(),
            "displayUpdatedAt": monitor.snapshot.displayUpdatedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "powerHistory": monitor.history.map { ["timestamp": $0.timestamp.timeIntervalSince1970, "watts": $0.watts as Any? ?? NSNull()] },
            "systemSource": monitor.snapshot.systemSource.rawValue,
            "systemUpdatedAt": monitor.snapshot.systemUpdatedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "batterySource": monitor.snapshot.batterySource.rawValue,
            "inputSource": monitor.snapshot.inputSource.rawValue,
            "batteryUpdatedAt": monitor.snapshot.batteryUpdatedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "inputUpdatedAt": monitor.snapshot.inputUpdatedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "menuTopAreas": menuAreas.map(rect),
            "menuAnchorIsUnobscured": lastAnchor.map { PanelPlacement.menuItemFits($0, screen: screen.frame, unobscuredTopAreas: menuAreas) } ?? false,
            "anchor": lastAnchor.map(rect) ?? [:], "timestamp": Date().timeIntervalSince1970
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: diagnosticURL, options: .atomic)
        }
    }
}
