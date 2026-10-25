import AppKit
import Combine
import IOKit.ps

@MainActor
final class PowerMonitor: ObservableObject {
    @Published var snapshot = PowerSnapshot()
    @Published var history: [PowerSample] = []
    @Published private(set) var refreshInterval: TimeInterval
    @Published var demoMode: Int? = nil
    @Published var panelVisible = false {
        didSet {
            if panelVisible != oldValue { reconcileDetails(); if panelVisible { refresh() } }
        }
    }
    @Published private(set) var detailsExpanded = false
    @Published private(set) var processPower = ProcessPowerSnapshot()
    @Published private(set) var detailSampleCount = 0
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
    private let readSource: (@Sendable () -> PowerSnapshot)?
    private let processSource: @Sendable () -> ProcessEnergyBatch
    private var detailTimer: Timer?
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = 0
    private var processBaseline: ProcessEnergyBatch?
    private var shouldSampleDetails: Bool { !stopped && panelVisible && detailsExpanded && demoMode == nil }

    init(defaults: UserDefaults = .standard,
         observeSystem: Bool = true,
         readSource: (@Sendable () -> PowerSnapshot)? = nil,
         processSource: @escaping @Sendable () -> ProcessEnergyBatch = { ProcessPowerReader.shared.read() }) {
        self.defaults = defaults
        self.readSource = readSource
        self.processSource = processSource
        refreshInterval = RefreshPolicy.restored((defaults.object(forKey: RefreshPolicy.key) as? NSNumber)?.doubleValue)
        refresh()
        scheduleTimer()
        guard observeSystem else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.history.removeAll()
                self.reconcileDetails()
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
        let includeDetails = shouldSampleDetails
        readTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { source?() ?? PowerReader.read(includeDetails: includeDetails) }.value
            guard !Task.isCancelled, let self, !self.stopped, self.generation == currentGeneration else { return }
            self.readTask = nil
            self.apply(result)
            if self.readPending {
                self.readPending = false
                self.refresh()
            }
        }
    }

    func setDetailsExpanded(_ expanded: Bool) {
        guard !stopped, expanded != detailsExpanded else { return }
        detailsExpanded = expanded
        reconcileDetails()
        refresh()
    }

    private func reconcileDetails() {
        detailGeneration += 1
        detailTimer?.invalidate()
        detailTimer = nil
        processBaseline = nil
        if demoMode != nil, detailsExpanded {
            processPower = .preview()
        } else {
            processPower = ProcessPowerSnapshot(phase: shouldSampleDetails ? .sampling : .idle)
        }
        guard shouldSampleDetails else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDetails() }
        }
        timer.tolerance = 0.1
        detailTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshDetails()
    }

    private func refreshDetails() {
        // Keep the in-flight slot through close/reopen. Detached reads cannot
        // be interrupted safely, and a second scan must not overlap them.
        guard shouldSampleDetails, detailTask == nil else { return }
        let revision = detailGeneration, source = processSource
        detailTask = Task { [weak self] in
            let batch = await Task.detached(priority: .utility) { source() }.value
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.detailTask = nil
            guard self.shouldSampleDetails else { return }
            guard self.detailGeneration == revision else { self.refreshDetails(); return }
            self.processPower = ProcessPowerPolicy.sample(previous: self.processBaseline, current: batch)
            self.processBaseline = batch.available ? batch : nil
            self.detailSampleCount += 1
            self.didUpdate?()
        }
    }

    private func apply(_ reading: PowerSnapshot) {
        snapshot = reading
        sampleCount += 1
        let now = Date()
        history = PowerHistory.recent(history, at: now)
        // Re-reading one cached hardware revision must not create fake samples.
        let updated = demoMode != nil || reading.systemWatts == nil ? reading.timestamp : reading.systemUpdatedAt
        if let updated, updated <= now, now.timeIntervalSince(updated) <= 60,
           history.last.map({ $0.timestamp < updated }) ?? true {
            history.append(PowerSample(timestamp: updated, watts: reading.systemWatts))
        }
        didUpdate?()
    }

    func selectDemo(_ value: Int?) {
        generation += 1
        readTask?.cancel()
        readTask = nil
        readPending = false
        demoMode = value
        reconcileDetails()
        history.removeAll()
        refresh()
    }

    func stop() {
        stopped = true
        generation += 1
        detailGeneration += 1
        detailTimer?.invalidate()
        detailTimer = nil
        detailTask?.cancel()
        detailTask = nil
        processBaseline = nil
        processPower = ProcessPowerSnapshot()
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
