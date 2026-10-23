import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windowController: FlowWindowController!
    private var iconOnlyForCrowding = false
    private var monitor: PowerMonitor!
    private var animationTimer: Timer?
    private var phase: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.currentflow.mac")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        monitor = PowerMonitor()
        windowController = FlowWindowController(monitor: monitor, quit: { NSApp.terminate(nil) })
        statusItem = NSStatusBar.system.statusItem(withLength: 92)
        statusItem.autosaveName = "CurrentFlowCompactStatus-v3"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("电流脉动。查看充电器和电池的实时电流、供电流向。")
        }
        monitor.didUpdate = { [weak self] in
            self?.updateStatus()
            self?.windowController.recordLayout(menuTitle: self?.statusItem.button?.title)
        }
        updateStatus()
        animationTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !UserDefaults.standard.bool(forKey: "reduceFlowMotion"), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      self.monitor.snapshot.available else { return }
                self.phase = (self.phase + 0.13).truncatingRemainder(dividingBy: 1)
                self.updateStatusImage()
            }
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
        if StartupPolicy.shouldShowPanel(force: CommandLine.arguments.contains("--show"),
                                         firstLaunch: !UserDefaults.standard.bool(forKey: "didShowWelcome"),
                                         preferred: UserDefaults.standard.bool(forKey: StartupPolicy.showOnLaunchKey)) {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.togglePopover() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.show(from: statusItem.button)
        return true
    }

    @objc private func togglePopover() {
        windowController.toggle(from: statusItem.button)
    }

    private func checkMenuClearance() {
        guard !iconOnlyForCrowding, let button = statusItem.button,
              let window = button.window, let screen = window.screen else { return }
        let item = window.convertToScreen(button.convert(button.bounds, to: nil))
        // The status-item window starts at a temporary origin before macOS lays
        // out the menu bar. Do not mistake that transient frame for the notch.
        let menuBandHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        guard !item.isEmpty, item.minY >= screen.frame.maxY - menuBandHeight - 2 else { return }
        let left: CGRect? = screen.auxiliaryTopLeftArea
        let right: CGRect? = screen.auxiliaryTopRightArea
        let areas = [left, right].compactMap { $0 }.filter { !$0.isEmpty }
        if !PanelPlacement.menuItemFits(item, screen: screen.frame, unobscuredTopAreas: areas) {
            iconOnlyForCrowding = true
            updateStatus()
        }
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        let s = monitor.snapshot
        let power = s.systemWatts.map { String(format: "%.1fW", $0) } ?? "—W"
        statusItem.length = iconOnlyForCrowding ? 28 : 92
        button.title = iconOnlyForCrowding ? "" : " \(power)"
        button.setAccessibilityLabel("电脑实时功耗：\(reading(s.systemWatts, unit: "瓦", digits: 1))。点击查看供电流向。")
        button.toolTip = "\(monitor.demoMode == nil ? "" : "【模拟演示 · 非实测】\n")\(s.status)\n充电器输入：\(s.externalConnected ? reading(s.inputAmps, unit: "A") : "未连接")\n电池：\(reading(s.batteryAmps, unit: "A"))\n电脑用电：\(reading(s.systemWatts, unit: "W", digits: 1))\n点击查看动态供电图"
        updateStatusImage()
        DispatchQueue.main.async { [weak self] in self?.checkMenuClearance() }
    }

    private func updateStatusImage() {
        guard let button = statusItem.button else { return }
        let s = monitor.snapshot
        let image = NSImage(size: NSSize(width: 26, height: 20), flipped: false) { [phase] _ in
            NSColor.labelColor.setStroke()
            let screen = NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: 22, height: 12), xRadius: 2, yRadius: 2)
            screen.lineWidth = 1.1; screen.stroke()
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 2, y: 5)); base.line(to: NSPoint(x: 0, y: 3))
            base.line(to: NSPoint(x: 26, y: 3)); base.line(to: NSPoint(x: 24, y: 5))
            base.lineWidth = 1.1; base.stroke()
            let battery = NSBezierPath(roundedRect: NSRect(x: 7, y: 9, width: 11, height: 5), xRadius: 1, yRadius: 1)
            battery.lineWidth = 0.9; battery.stroke()
            NSColor.labelColor.setFill()
            NSBezierPath(rect: NSRect(x: 18, y: 10.5, width: 1, height: 2)).fill()
            if s.flow == .charging || s.flow == .discharging {
                let x = s.flow == .charging ? 8 + phase * 8 : 16 - phase * 8
                NSBezierPath(ovalIn: NSRect(x: x - 1, y: 10.5, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        button.image = image
    }

    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
        monitor?.stop()
    }
}

@main
struct CurrentFlowMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--startup-status") {
            let status: [String: Any] = ["version": AppInfo.version, "status": SystemLoginItem().state.rawValue,
                                       "showPanelOnLaunch": UserDefaults.standard.bool(forKey: StartupPolicy.showOnLaunchKey)]
            if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        if CommandLine.arguments.contains("--snapshot") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(PowerReader.read()), let string = String(data: data, encoding: .utf8) {
                print(string)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            _ = NSApplication.shared
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let monitor = PowerMonitor()
                monitor.panelVisible = true
                for mode in 0..<4 {
                    monitor.selectDemo(mode)
                    monitor.history = (0..<60).map { i in
                        let base = monitor.snapshot.systemWatts ?? 0
                        return PowerSample(timestamp: Date().addingTimeInterval(Double(i) - 59), watts: max(0, base + sin(Double(i) * 0.3) * 3))
                    }
                    let renderer = ImageRenderer(content: FlowPanel(monitor: monitor, staticPreview: true, quit: {}))
                    renderer.scale = 2
                    guard let cgImage = renderer.cgImage else { throw NSError(domain: "Render", code: 1) }
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Render", code: 2) }
                    try data.write(to: output.appendingPathComponent("preview-\(mode).png"))
                }
                for mode in [0, 1] {
                    let file = output.appendingPathComponent(mode == 0 ? "flow-charging.gif" : "flow-discharging.gif")
                    guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString, 48, nil) else { throw NSError(domain: "GIF", code: 1) }
                    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                    for frame in 0..<48 {
                        let content = VStack(alignment: .leading, spacing: 8) {
                            Text(mode == 0 ? "充电动效演示 · 模拟数据" : "放电动效演示 · 模拟数据")
                                .font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
                            FlowDiagram(snapshot: .demo(mode), reduceMotion: false, paused: true, previewTime: Double(frame) / 16)
                        }.padding(16).background(FlowStyle.background).foregroundStyle(FlowStyle.ink).preferredColorScheme(.light)
                        let renderer = ImageRenderer(content: content)
                        renderer.scale = 1.5
                        guard let cgImage = renderer.cgImage else { throw NSError(domain: "GIF", code: 2) }
                        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 16]] as CFDictionary)
                    }
                    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "GIF", code: 3) }
                }
                print("Rendered 4 previews and 2 animated GIFs to \(output.path)")
            } catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
