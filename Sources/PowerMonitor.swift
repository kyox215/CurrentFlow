import AppKit
import Combine
import IOKit.ps

@MainActor
final class PowerMonitor: ObservableObject {
    @Published var snapshot = PowerSnapshot()
    @Published var history: [PowerSample] = []
    @Published private(set) var refreshInterval: TimeInterval
    @Published var demoMode: Int? = nil
    @Published var panelVisible = false
    @Published private(set) var sampleCount = 0
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var powerSourceNotification: CFRunLoopSource?
    private var readTask: Task<Void, Never>?
    private var readPending = false
    private var generation = 0
    private var stopped = false
    var didUpdate: (() -> Void)?
    private let defaults: UserDefaults
    private let readSource: @Sendable () -> PowerSnapshot

    init(defaults: UserDefaults = .standard,
         observeSystem: Bool = true,
         readSource: @escaping @Sendable () -> PowerSnapshot = { PowerReader.read() }) {
        self.defaults = defaults
        self.readSource = readSource
        refreshInterval = RefreshPolicy.restored((defaults.object(forKey: RefreshPolicy.key) as? NSNumber)?.doubleValue)
        refresh()
        scheduleTimer()
        guard observeSystem else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.history.removeAll()
                self.scheduleTimer()
                self.refresh()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSourceNotification = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(pointer).takeUnretainedValue().refresh()
            }
        }, context)?.takeRetainedValue()
        if let source = powerSourceNotification { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = min(0.1, refreshInterval * 0.05)
        RunLoop.main.add(timer!, forMode: .common)
    }

    @discardableResult
    func setRefreshInterval(_ interval: TimeInterval) -> Bool {
        guard !stopped, RefreshPolicy.isValid(interval) else { return false }
        guard interval != refreshInterval else { return true }
        refreshInterval = interval
        defaults.set(interval, forKey: RefreshPolicy.key)
        scheduleTimer()
        refresh()
        return true
    }

    func refresh() {
        guard !stopped else { return }
        if let mode = demoMode { apply(.demo(mode)); return }
        // Never overlap IOKit calls or let a slow sensor read block the UI.
        guard readTask == nil else { readPending = true; return }
        let currentGeneration = generation
        let source = readSource
        readTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { source() }.value
            guard !Task.isCancelled, let self, !self.stopped, self.generation == currentGeneration else { return }
            self.readTask = nil
            self.apply(result)
            if self.readPending {
                self.readPending = false
                self.refresh()
            }
        }
    }

    private func apply(_ reading: PowerSnapshot) {
        snapshot = reading
        sampleCount += 1
        let now = Date()
        history = PowerHistory.recent(history, at: now)
        // Re-reading one cached hardware revision must not create fake samples.
        if let updated = reading.batteryUpdatedAt,
           history.last?.timestamp != updated, now.timeIntervalSince(updated) <= 60 {
            history.append(PowerSample(timestamp: updated, amps: reading.batteryAmps))
        }
        didUpdate?()
    }

    func selectDemo(_ value: Int?) {
        generation += 1
        readTask?.cancel()
        readTask = nil
        readPending = false
        demoMode = value
        history.removeAll()
        refresh()
    }

    func stop() {
        stopped = true
        generation += 1
        timer?.invalidate()
        timer = nil
        readTask?.cancel()
        readTask = nil
        readPending = false
        if let source = powerSourceNotification {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        powerSourceNotification = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        wakeObserver = nil
        activeObserver = nil
    }
}
