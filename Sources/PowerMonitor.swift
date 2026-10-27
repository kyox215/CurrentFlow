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
    let historyStore: HistoryStore?
    @Published private(set) var historyError: String?
    private var historyActivity: NSObjectProtocol?
    private var historyTimer: Timer?
    private var historyTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var sleeping = false
    private var pendingDisplay = false
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
    private var shouldSampleDetails: Bool { !stopped && !sleeping && panelVisible && detailsExpanded && demoMode == nil }

    init(defaults: UserDefaults = .standard,
         observeSystem: Bool = true,
         historyStore: HistoryStore? = nil,
         readSource: (@Sendable () -> PowerSnapshot)? = nil,
         processSource: @escaping @Sendable () -> ProcessEnergyBatch = { ProcessPowerReader.shared.read() }) {
        self.historyStore = historyStore ?? (observeSystem ? HistoryStore(url: HistoryStore.defaultURL) : nil)
        self.defaults = defaults
        self.readSource = readSource
        self.processSource = processSource
        if observeSystem, self.historyStore != nil {
            historyActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Record local power history once per second")
        }
        refreshInterval = RefreshPolicy.restored((defaults.object(forKey: RefreshPolicy.key) as? NSNumber)?.doubleValue)
        refresh()
        scheduleTimer()
        guard observeSystem else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = false
                if let store = self.historyStore { Task { await store.breakContinuity() } }
                self.history.removeAll()
                self.reconcileDetails()
                self.scheduleTimer()
                self.refresh()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = true
                self.reconcileDetails()
                self.generation += 1
                self.readTask?.cancel(); self.readTask = nil
                self.readPending = false; self.pendingDisplay = false
                if let store = self.historyStore { Task { await store.breakContinuity() } }
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
        historyTimer?.invalidate()
        historyTimer = nil
        if refreshInterval > 1, historyStore != nil {
            let sampler = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(updateDisplay: false) }
            }
            sampler.tolerance = 0.02
            historyTimer = sampler
            RunLoop.main.add(sampler, forMode: .common)
        }
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

    func refresh(updateDisplay: Bool = true) {
        guard !stopped, !sleeping else { return }
        if let mode = demoMode {
            if let store = historyStore, historyTask == nil {
                historyTask = Task { [weak self] in
                    do { try await store.prune(now: Int64(Date().timeIntervalSince1970)); self?.historyError = nil }
                    catch { self?.historyError = error.localizedDescription }
                    self?.historyTask = nil
                }
            }
            if updateDisplay { apply(.demo(mode)) }
            return
        }
        // Never overlap IOKit calls or let a slow sensor read block the UI.
        guard readTask == nil else { readPending = true; pendingDisplay = pendingDisplay || updateDisplay; return }
        let currentGeneration = generation
        let source = readSource
        let includeDetails = shouldSampleDetails
        readTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { source?() ?? PowerReader.read(includeDetails: includeDetails) }.value
            guard !Task.isCancelled, let self, !self.stopped, self.generation == currentGeneration else { return }
            self.readTask = nil
            self.persist(result)
            if updateDisplay || self.pendingDisplay { self.apply(result) }
            let displayPending = self.pendingDisplay
            self.pendingDisplay = false
            if self.readPending {
                self.readPending = false
                self.refresh(updateDisplay: displayPending)
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

    private func persist(_ reading: PowerSnapshot) {
        guard demoMode == nil, let store = historyStore, historyTask == nil else { return }
        let record = HistoryRecord(reading)
        let uptime = ProcessInfo.processInfo.systemUptime
        historyTask = Task { [weak self] in
            do { try await store.record(record, uptime: uptime); self?.historyError = nil }
            catch { self?.historyError = error.localizedDescription }
            self?.historyTask = nil
        }
    }

    func flushHistory() async { await historyTask?.value }

    func selectDemo(_ value: Int?) {
        generation += 1
        readTask?.cancel()
        readTask = nil
        readPending = false
        if let store = historyStore { Task { await store.breakContinuity() } }
        demoMode = value
        reconcileDetails()
        history.removeAll()
        refresh()
    }

    func stop() {
        stopped = true
        if let historyActivity { ProcessInfo.processInfo.endActivity(historyActivity) }
        historyActivity = nil
        historyTimer?.invalidate(); historyTimer = nil
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
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        wakeObserver = nil
        activeObserver = nil
    }
}
