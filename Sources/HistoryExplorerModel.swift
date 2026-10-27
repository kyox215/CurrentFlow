import Foundation
import Combine

@MainActor
final class HistoryExplorerModel: ObservableObject {
    typealias SummaryLoader = @Sendable (Int64, Int64, Int) async throws -> HistorySummary
    typealias SecondsLoader = @Sendable (Int64) async throws -> [HistorySecond]
    @Published private(set) var navigation: HistoryNavigation
    @Published private(set) var summary = HistorySummary()
    @Published private(set) var overview = HistorySummary()
    @Published private(set) var overviewEnd: Int64
    @Published private(set) var rows: [HistorySecond] = []
    @Published private(set) var loading = false
    @Published private(set) var locating = false
    @Published private(set) var error: String?
    @Published private(set) var detailError: String?
    private let loadSummary: SummaryLoader
    private let loadSeconds: SecondsLoader
    private let clock: () -> Int64
    private var summaryTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var summaryRevision = 0, detailRevision = 0, overviewRevision = 0
    private var active = false
    var selectedRow: HistorySecond? { rows.first { $0.second == navigation.selected } }
    var coverage: Double { min(1, Double(summary.valid) / Double(navigation.span)) }
    var overviewStart: Int64 { overviewEnd - HistoryNavigation.retention + 1 }

    convenience init(store: HistoryStore?) {
        self.init(summary: { start, end, count in
            guard let store else { throw NSError(domain: "History", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前未启用历史存储"]) }
            return try await store.summary(from: start, through: end, maxBuckets: count)
        }, seconds: { second in
            guard let store else { return [] }
            return try await store.seconds(around: second)
        })
    }
    init(now: Int64? = nil, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
         summary: @escaping SummaryLoader, seconds: @escaping SecondsLoader) {
        let current = now ?? clock()
        navigation = HistoryNavigation(now: current); overviewEnd = current
        self.clock = clock; loadSummary = summary; loadSeconds = seconds
    }
    func setVisible(_ visible: Bool) {
        guard visible != active else { return }
        active = visible
        if visible {
            reload()
            liveTask = Task { [weak self] in
                var ticks = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                    guard let self, self.active else { break }
                    if self.navigation.followsLatest {
                        ticks += 1
                        self.navigation.refresh(now: self.clock())
                        self.requestSummary(debounce: false)
                        self.requestSeconds(debounce: false)
                        if ticks % 6 == 0 { self.requestOverview() }
                    }
                }
            }
        } else {
            liveTask?.cancel(); liveTask = nil
            summaryTask?.cancel(); detailTask?.cancel(); overviewTask?.cancel()
            summaryRevision += 1; detailRevision += 1; overviewRevision += 1
            loading = false; locating = false
        }
    }
    func reload() {
        navigation.refresh(now: clock())
        requestSummary(debounce: false); requestSeconds(debounce: false); requestOverview()
    }
    func chooseSpan(_ span: Int64) { change { $0.chooseSpan(span, now: clock()) } }
    func zoom(_ factor: Double) { change { $0.zoom(factor, now: clock()) } }
    func pan(_ delta: Int64) { change { $0.pan(delta) } }
    func center(on second: Int64) { change { $0.center(on: second) } }
    func latest() { change { $0.returnToLatest(now: clock()) }; requestOverview() }
    func seek(_ second: Int64) { change { $0.seek(second) } }
    func step(_ delta: Int64) { change { $0.step(delta) } }
    func select(_ second: Int64) {
        let value = min(navigation.end, max(navigation.start, second))
        guard value != navigation.selected || navigation.followsLatest else { return }
        navigation.select(value); requestSeconds()
    }
    private func change(_ edit: (inout HistoryNavigation) -> Void) {
        let before = navigation
        var next = navigation; next.refresh(now: clock()); edit(&next); navigation = next
        if before.start != next.start || before.end != next.end { summary = HistorySummary(); requestSummary() }
        if before.selected != next.selected { requestSeconds() }
    }
    private func requestSummary(debounce: Bool = true) {
        summaryRevision += 1; let revision = summaryRevision
        summaryTask?.cancel(); loading = true; error = nil
        let start = navigation.start, end = navigation.end, loader = loadSummary
        summaryTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 140_000_000) }
                try Task.checkCancellation()
                let result = try await loader(start, end, 600)
                guard let self, !Task.isCancelled, self.summaryRevision == revision,
                      self.navigation.start == start, self.navigation.end == end else { return }
                self.summary = result; self.loading = false
            } catch {
                guard let self, !Task.isCancelled, self.summaryRevision == revision else { return }
                self.error = error.localizedDescription; self.loading = false
            }
        }
    }
    private func requestSeconds(debounce: Bool = true) {
        detailRevision += 1; let revision = detailRevision
        detailTask?.cancel(); locating = true; detailError = nil
        let second = navigation.selected, loader = loadSeconds
        detailTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 90_000_000) }
                try Task.checkCancellation()
                let result = try await loader(second)
                guard let self, !Task.isCancelled, self.detailRevision == revision,
                      self.navigation.selected == second else { return }
                self.rows = result; self.locating = false
            } catch {
                guard let self, !Task.isCancelled, self.detailRevision == revision else { return }
                self.rows = []; self.detailError = error.localizedDescription; self.locating = false
            }
        }
    }
    private func requestOverview() {
        overviewRevision += 1; let revision = overviewRevision
        overviewTask?.cancel()
        let end = clock(), start = end - HistoryNavigation.retention + 1, loader = loadSummary
        overviewTask = Task { [weak self] in
            do {
                let result = try await loader(start, end, 280)
                guard let self, !Task.isCancelled, self.overviewRevision == revision else { return }
                self.overviewEnd = end; self.overview = result
            } catch {
                guard let self, !Task.isCancelled, self.overviewRevision == revision else { return }
                // Keep an explicit read error instead of displaying a fabricated overview.
                self.error = error.localizedDescription
            }
        }
    }
}
