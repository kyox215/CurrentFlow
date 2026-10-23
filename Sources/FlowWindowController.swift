import AppKit
import SwiftUI

@MainActor
private final class FlowWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FlowWindowController: NSObject, NSWindowDelegate {
    let window: NSPanel
    private let monitor: PowerMonitor
    private let hostingView: NSHostingView<FlowPanel>
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var lastAnchor: CGRect?
    private var lastScreen: NSScreen?
    private var requestedSize = PanelPlacement.preferredSize
    private var resizeScheduled = false
    private let diagnosticURL: URL?
    var isVisible: Bool { window.isVisible }

    init(monitor: PowerMonitor, quit: @escaping () -> Void) {
        self.monitor = monitor
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--ui-probe"), arguments.count > i + 1 {
            diagnosticURL = URL(fileURLWithPath: arguments[i + 1])
        } else { diagnosticURL = nil }
        window = FlowWindow(contentRect: CGRect(origin: .zero, size: PanelPlacement.preferredSize),
                            styleMask: [.borderless], backing: .buffered, defer: false)
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
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.animationBehavior = .none

        let container = NSView(frame: CGRect(origin: .zero, size: PanelPlacement.preferredSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        window.contentView = container

        // The native panel owns the size. SwiftUI cannot change window min/max
        // constraints or recenter itself when the disclosure content changes.
        hostingView.sizingOptions = []
        if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        hostingView.rootView = FlowPanel(monitor: monitor, onSizeChange: { [weak self] size in
            self?.requestSize(size)
        }, quit: quit)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                if event.keyCode == 53, self?.isVisible == true { self?.hide(); return true }
                return false
            }
            return consume ? nil : event
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                // The display may have been removed; use a currently connected one.
                let screen = NSScreen.screens.first { $0 == self.lastScreen } ?? NSScreen.main
                if let screen { self.place(on: screen, anchor: nil) }
            }
        }
    }

    func toggle(from button: NSStatusBarButton?) {
        if isVisible { hide() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton?) {
        let anchor = button.flatMap { view in view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } }
        guard let screen = button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        monitor.panelVisible = true
        monitor.refresh()
        place(on: screen, anchor: anchor)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        recordLayout()
    }

    private func place(on screen: NSScreen, anchor: CGRect?) {
        lastScreen = screen
        lastAnchor = anchor
        let safe = PanelPlacement.safeBounds(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
        window.setFrame(PanelPlacement.frame(in: safe, anchor: anchor, desired: requestedSize), display: true, animate: false)
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

    func hide() {
        window.orderOut(nil)
        monitor.panelVisible = false
    }

    func windowWillClose(_ notification: Notification) { monitor.panelVisible = false }

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
            "requestedSize": ["width": requestedSize.width, "height": requestedSize.height],
            "batteryAmps": monitor.snapshot.batteryAmps as Any? ?? NSNull(),
            "inputAmps": monitor.snapshot.inputAmps as Any? ?? NSNull(),
            "systemWatts": monitor.snapshot.systemWatts as Any? ?? NSNull(),
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
