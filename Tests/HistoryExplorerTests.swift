import Foundation

private actor ReadProbe {
    var summaries = 0
    var details = 0
    func summary() { summaries += 1 }
    func detail() { details += 1 }
    func counts() -> (Int, Int) { (summaries, details) }
}

@main
struct HistoryExplorerTests {
    static var count = 0
    static func check(_ value: Bool, _ message: String) { count += 1; precondition(value, message) }
    // Deliberately ignores task cancellation to model an in-flight SQLite read.
    static func delay(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
    static func result(_ start: Int64, _ end: Int64) -> HistorySummary {
        var s = HistorySummary(); let n = Int(end - start + 1)
        s.lower = start; s.upper = end; s.bucketWidth = end - start + 1; s.valid = n; s.recorded = n; s.peak = Double(n)
        s.buckets = [HistoryBucket(second: start, minimum: Double(n), maximum: Double(n), average: Double(n), valid: n, expected: n)]
        return s
    }
    static func row(_ second: Int64) -> HistorySecond {
        HistorySecond(second: second, watts: 20, cpu: 5, gpu: 2, display: 2, external: true, flow: "idle", estimated: false, source: "sensor", sensorTime: Double(second))
    }
    @MainActor static func main() async throws {
        let now: Int64 = 1_800_000_000
        check(HistoryNavigation.label(86400) == "24 小时", "range label identifies elapsed hours rather than a DST-dependent calendar day")
        var nav = HistoryNavigation(now: now)
        check(nav.span == 3600 && nav.end == now && nav.followsLatest, "default latest one-hour range")
        nav.select(now - 1000)
        check(!nav.followsLatest, "pointer inspection pauses latest-following")
        let inspected = nav.selected
        nav.zoom(0.5, now: now)
        check(nav.span == 1800 && nav.selected == inspected && nav.start <= inspected && nav.end >= inspected, "zoom is anchored to selected second")
        nav.zoom(0.00001, now: now)
        check(nav.span == 15, "zoom stops at fifteen seconds")
        nav.zoom(1_000_000, now: now)
        check(nav.span == 604800 && nav.start == nav.oldest, "zoom-out bounded to seven days")
        nav.chooseSpan(300, now: now)
        nav.pan(-1_000_000)
        check(nav.start == nav.oldest && !nav.canGoBack, "backwards pan clamps entire viewport")
        nav.pan(1_000_000)
        check(nav.end == now && !nav.canGoForward && !nav.followsLatest, "forward pan clamps without silently enabling live")
        nav.seek(now - 5000)
        let frozenStart = nav.start, frozenSelection = nav.selected
        nav.refresh(now: now + 500)
        check(nav.start == frozenStart && nav.selected == frozenSelection, "refresh does not jump away from old inspection")
        nav.step(1)
        check(nav.selected == frozenSelection + 1, "keyboard/step uses exact seconds")
        nav.seek(now + 1_000_000)
        check(nav.selected == nav.latest, "future exact-time request clamps to available time")
        nav.seek(now - 1_000_000)
        check(nav.selected == nav.oldest, "expired exact-time request clamps to rolling boundary")
        nav.center(on: now - 10000)
        check(abs(nav.center - (now - 10000)) <= 1, "overview center uses the same range state")
        check(nav.second(at: -2) == nav.start && nav.second(at: 2) == nav.end, "graph pointer clamps at both plot edges")
        check(nav.second(at: .nan) == nav.start, "invalid pointer fraction never creates invalid timestamps")
        nav.returnToLatest(now: now)
        check(nav.selected == now && nav.end == now && nav.followsLatest, "latest restores live semantics explicitly")
        nav.refresh(now: now + 100)
        check(nav.selected == now + 100 && nav.end == now + 100, "latest follows new time")
        nav.select(now)
        nav.refresh(now: now - 1000)
        check(nav.selected <= nav.latest && nav.end <= nav.latest, "backwards clock changes remain bounded")
        var seed: UInt64 = 1986
        for _ in 0..<1500 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let delta = Int64(seed % 1_200_001) - 600000
            switch seed % 6 {
            case 0: nav.pan(delta)
            case 1: nav.seek(now + delta)
            case 2: nav.zoom(seed % 2 == 0 ? 0.5 : 2, now: now)
            case 3: nav.chooseSpan(HistoryNavigation.presets[Int(seed % 5)], now: now)
            case 4: nav.center(on: now + delta)
            default: nav.step(delta)
            }
            precondition(nav.span >= 15 && nav.span <= 604800 && nav.start >= nav.oldest && nav.end <= nav.latest && nav.selected >= nav.start && nav.selected <= nav.end, "random interaction sequence escaped its time bounds")
        }
        check(true, "1500 mixed navigation actions maintain viewport and cursor bounds")
        var mean = HistorySummary(); mean.valid = 3
        mean.buckets = [HistoryBucket(second: now, minimum: 10, maximum: 10, average: 10, valid: 1, expected: 1), HistoryBucket(second: now + 1, minimum: 40, maximum: 40, average: 40, valid: 2, expected: 3)]
        check(mean.average == 30, "summary mean weights valid raw sample counts, including partial buckets")
        check(HistorySummary().average == nil, "empty mean remains missing rather than fabricated zero")

        let probe = ReadProbe()
        var time = now
        let model = HistoryExplorerModel(now: now, clock: { time }, summary: { start, end, budget in
            await probe.summary()
            await delay(budget == 600 && end - start + 1 == 3600 ? 0.3 : 0.015)
            return result(start, end)
        }, seconds: { second in
            await probe.detail(); await delay(second == now ? 0.3 : 0.015)
            return [row(second)]
        })
        model.setVisible(true)
        try await Task.sleep(nanoseconds: 25_000_000)
        model.chooseSpan(300)
        model.select(now - 20)
        try await Task.sleep(nanoseconds: 400_000_000)
        check(model.summary.average == 300, "cancelled old summary cannot overwrite a newer range")
        check(model.selectedRow?.second == now - 20, "cancelled old seconds cannot overwrite a newer cursor")
        check(model.overview.buckets.count == 1 && model.overview.bucketWidth == 604800, "overview query has independent state")
        let counts = await probe.counts()
        for i in 21...120 { model.select(now - Int64(i)) }
        try await Task.sleep(nanoseconds: 180_000_000)
        let afterDrag = await probe.counts()
        check(afterDrag.1 - counts.1 == 1, "100 cursor drag updates coalesce into one detail read")
        check(model.selectedRow?.second == now - 120, "final dragged second wins")
        let beforePan = await probe.counts()
        for i in 1...80 { model.center(on: now - 10000 - Int64(i)) }
        try await Task.sleep(nanoseconds: 220_000_000)
        let afterPan = await probe.counts()
        check(afterPan.0 - beforePan.0 == 1, "80 overview updates coalesce into one chart read")
        let oldEnd = model.navigation.end
        time = now + 1000
        model.reload()
        try await Task.sleep(nanoseconds: 60_000_000)
        check(model.navigation.end == oldEnd, "manual reload of past range does not jump to latest")
        model.latest()
        try await Task.sleep(nanoseconds: 220_000_000)
        check(model.navigation.followsLatest && model.navigation.end == time, "latest button synchronizes overview and viewport time")
        time += 5000
        model.seek(time)
        check(model.navigation.selected == time, "exact-time and step navigation use the current clock even after a long paused inspection")
        model.chooseSpan(86400)
        model.setVisible(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        check(!model.loading && !model.locating, "closing cancels queued query state")
        model.setVisible(true)
        try await Task.sleep(nanoseconds: 80_000_000)
        check(model.summary.average == 86400, "reopening resumes the chosen range rather than defaulting")
        model.setVisible(false)
        let broken = HistoryExplorerModel(now: now, summary: { _, _, _ in throw NSError(domain: "test", code: 1) }, seconds: { _ in throw NSError(domain: "detail-test", code: 2) })
        broken.setVisible(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        check(broken.error != nil && broken.detailError != nil && broken.selectedRow == nil, "read errors are explicit and cannot create a fake readout")
        broken.setVisible(false)
        print("PASS: \(count) history explorer checks + 1500 mixed actions — bounds / cursor / zoom / pan / latest / weighted mean / stale results / debouncing / visibility / errors")
    }
}
