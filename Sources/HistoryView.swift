import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let onPresent: (() -> Void)?
    private let onClose: (() -> Void)?
    private let onObservation: (String, UInt64, Bool) -> Void
    private var programmaticCloseDepth = 0
    private var operationGeneration: UInt64 = 0
    private var documentPresented = false
    let explorer: HistoryExplorerModel

    init(monitor: PowerMonitor, onPresent: (() -> Void)? = nil, onClose: (() -> Void)? = nil,
         onObservation: @escaping (String, UInt64, Bool) -> Void = { _, _, _ in }) {
        self.onPresent = onPresent; self.onClose = onClose; self.onObservation = onObservation
        explorer = HistoryExplorerModel(store: monitor.historyStore)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(720, (NSScreen.main?.visibleFrame.width ?? 1100) - 60), height: min(600, (NSScreen.main?.visibleFrame.height ?? 930) - 60)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "功耗历史 · 最近 7 天"
        window.minSize = NSSize(width: 600, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryView(monitor: monitor, model: explorer))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Public calls express intent. Managed windows are ordered only by the coordinator.
    func present() {
        if let onPresent { onPresent(); return }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        _ = coordinatedPresent(generation: operationGeneration &+ 1, restoreMinimized: true, focus: true)
    }
    func suspend() {
        if let onClose { onClose(); return }
        _ = coordinatedSuspend(generation: operationGeneration &+ 1)
    }
    @discardableResult
    func coordinatedPresent(generation: UInt64, restoreMinimized: Bool, focus: Bool) -> Bool {
        guard let window else { return false }
        operationGeneration = generation; documentPresented = true
        var changed = false
        if window.isMiniaturized {
            explorer.setVisible(false)
            guard restoreMinimized else { return false }
            observe("program.restore.begin"); window.deminiaturize(nil); changed = true
        }
        if !window.isVisible {
            observe("program.orderFront.begin"); window.orderFront(nil); changed = true
        }
        if focus && NSApp.isActive && !window.isKeyWindow && !window.isMiniaturized {
            observe("program.makeKey.begin"); window.makeKeyAndOrderFront(nil); changed = true
        }
        explorer.setVisible(window.isVisible && !window.isMiniaturized)
        return changed
    }
    @discardableResult
    func coordinatedSuspend(generation: UInt64) -> Bool {
        guard let window else { return false }
        operationGeneration = generation; documentPresented = false
        explorer.setVisible(false)
        guard window.isVisible || window.isMiniaturized else { return false }
        programmaticCloseDepth += 1
        defer { programmaticCloseDepth -= 1 }
        observe("program.close.begin")
        window.close()
        observe("program.close.end")
        return true
    }
    var isPresented: Bool { documentPresented }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        observe("shouldClose")
        if programmaticCloseDepth == 0 {
            documentPresented = false
            onClose?() // Genuine red button / performClose, never a late willClose.
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        explorer.setVisible(false)
        observe("willClose") // Cleanup/observation only; does not rewrite a newer intent.
    }
    func windowDidMiniaturize(_ notification: Notification) { explorer.setVisible(false); observe("didMiniaturize") }
    func windowDidDeminiaturize(_ notification: Notification) {
        explorer.setVisible(window?.isVisible == true && window?.isMiniaturized != true)
        observe("didDeminiaturize")
    }
    func windowDidBecomeKey(_ notification: Notification) { observe("didBecomeKey") }
    func windowDidResignKey(_ notification: Notification) { observe("didResignKey") }
    func windowDidChangeOcclusionState(_ notification: Notification) { observe("occlusion") }
    func windowDidUpdate(_ notification: Notification) { observe("update") }
    private func observe(_ event: String) { onObservation(event, operationGeneration, programmaticCloseDepth > 0) }
}

@MainActor
struct HistoryView: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var model: HistoryExplorerModel
    var demonstration = false
    @State private var showExact = false
    @State private var showHelp = false
    @State private var showTable = false
    @State private var exactTime = ""
    @State private var timeError: String?
    private var nav: HistoryNavigation { model.navigation }
    @State private var showOverview = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 540
            VStack(alignment: .leading, spacing: 8) {
                header
                ranges
                if let error = model.error ?? monitor.historyError {
                    HStack(spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle").lineLimit(1).help(error)
                        Spacer(minLength: 0)
                        Button("重试") { model.reload() }
                    }.font(.system(size: 12)).foregroundStyle(.orange)
                }
                metrics
                HStack {
                    Text("整机功率").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(rangeLabel).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .help(HistoryTime.label(nav.start) + " — " + HistoryTime.label(nav.end))
                    if model.loading { ProgressView().controlSize(.mini) }
                }
                ZStack {
                    HistoryPowerChart(model: model)
                    if !model.loading && model.summary.valid == 0 {
                        VStack(spacing: 4) {
                            Text(model.error == nil ? "这个时段暂无有效记录" : "暂时无法显示曲线")
                                .font(.system(size: 14, weight: .medium))
                            Text(model.error == nil ? "浏览概览，或回到最新时段" : "请查看上方提示并重试")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .allowsHitTesting(false)
                    }
                }.frame(minHeight: 90, maxHeight: .infinity)
                chartTools
                selectedCard
                if !compact { overview }
                HStack {
                    Label("本机保存 · 每秒记录 · 保留 7 天", systemImage: "internaldrive")
                    Spacer()
                    if compact {
                        Button("7 天概览") { showOverview = true }
                            .popover(isPresented: $showOverview) { overview.frame(width: 480).padding(16) }
                    } else {
                        Text("缺口不补零").help("浅橙底为缺口；细线为区间最小至最大值，蓝线为完整区间均值。")
                    }
                }.font(.system(size: 12)).foregroundStyle(.secondary).controlSize(.small)
            }.padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 600, minHeight: 468)
    }
    private var header: some View {
        HStack(spacing: 8) {
            Text("功耗历史").font(.system(size: 16, weight: .semibold))
            if demonstration { Text("合成演示").font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Button {
                exactTime = HistoryTime.label(nav.selected); timeError = nil; showExact = true
            } label: { Label("定位", systemImage: "calendar.badge.clock") }
                .help("输入含 UTC 偏移的时间，精确定位到秒")
                .popover(isPresented: $showExact) { exactPopover }
            Button { showTable = true } label: { Label("明细", systemImage: "tablecells") }
                .popover(isPresented: $showTable) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("游标附近逐秒明细").font(.headline)
                        Text(HistoryTime.label(nav.selected)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        secondTable
                        Text("未记录或无效值显示为 —，不以零瓦补齐。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(16)
                }
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                .accessibilityLabel("读数与操作说明")
                .popover(isPresented: $showHelp) { helpPopover }
        }.controlSize(.small)
    }
    private var ranges: some View {
        HStack(spacing: 8) {
            Picker("时间范围", selection: Binding(get: { nav.span }, set: { model.chooseSpan($0) })) {
                ForEach(HistoryNavigation.presets, id: \.self) { span in
                    Text(HistoryNavigation.label(span)).tag(span)
                }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("历史时间范围")
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新当前时段，不改变旧时段的位置").accessibilityLabel("刷新当前时段")
            Button { model.latest() } label: {
                Label(nav.followsLatest ? "最新" : "回到最新", systemImage: nav.followsLatest ? "dot.radiowaves.left.and.right" : "arrow.right.to.line")
            }.help(nav.followsLatest ? "正在跟随最新记录" : "回到最新时段")
        }.controlSize(.small)
    }
    private var metrics: some View {
        HStack(spacing: 16) {
            summaryValue("平均", value: model.summary.average.map { String(format: "%.1f W", $0) } ?? "—")
            summaryValue("峰值", value: model.summary.valid > 0 ? String(format: "%.1f W", model.summary.peak) : "—")
            summaryValue("已覆盖耗电", value: model.summary.valid > 0 ? String(format: "≈ %.3f %@", model.summary.wattHours >= 1000 ? model.summary.wattHours / 1000 : model.summary.wattHours, model.summary.wattHours >= 1000 ? "kWh" : "Wh") : "—")
                .help("有效样本积分 \(duration(model.summary.integratedSeconds))；不跨缺口。只代表已覆盖部分。")
            summaryValue("覆盖", value: String(format: "%.1f%%", model.coverage * 100))
                .help("\(model.summary.valid.formatted()) / \(nav.span.formatted()) 秒有效")
        }.padding(.vertical, 8).padding(.horizontal, 12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
    private func summaryValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var chartTools: some View {
        HStack(spacing: 8) {
            Button { model.pan(-max(1, nav.span / 2)) } label: { Image(systemName: "chevron.left") }
                .disabled(!nav.canGoBack).help("前移半个时段").accessibilityLabel("前移时段")
            Button { model.pan(max(1, nav.span / 2)) } label: { Image(systemName: "chevron.right") }
                .disabled(!nav.canGoForward).help("后移半个时段").accessibilityLabel("后移时段")
            Text("拖动曲线查看每秒读数").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button { model.zoom(2) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(!nav.canZoomOut).help("围绕游标缩小").accessibilityLabel("缩小时间范围")
            Button { model.zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(!nav.canZoomIn).help("围绕游标放大").accessibilityLabel("放大时间范围")
        }.controlSize(.small)
    }
    private var selectedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(HistoryTime.label(nav.selected)).font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel("游标时间 " + HistoryTime.label(nav.selected))
                if model.locating { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("前一秒").accessibilityLabel("前一秒").disabled(nav.selected <= nav.oldest)
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .help("后一秒").accessibilityLabel("后一秒").disabled(nav.selected >= nav.latest)
            }.controlSize(.mini)
            HStack(spacing: 16) {
                selectedValue("整机", watts: model.selectedRow?.watts, estimated: model.selectedRow?.estimated ?? false, accent: true)
                selectedValue("CPU · 估算", watts: model.selectedRow?.cpu, estimated: true)
                selectedValue("GPU · 估算", watts: model.selectedRow?.gpu, estimated: true)
                selectedValue("内置背光", watts: model.selectedRow?.display)
            }
            HStack(spacing: 8) {
                if let row = model.selectedRow {
                    Text(row.external ? "外接供电" : "电池供电")
                    Text(BatteryFlow(rawValue: row.flow)?.title ?? "状态未知")
                    Spacer(minLength: 0)
                    Text(row.source == "sensor" ? "直接采样" : "系统缓存")
                    if row.watts == nil { Text("功率缺失或过期").foregroundStyle(.orange) }
                    if let time = row.sensorTime {
                        Text("源 " + shortTime(Int64(time))).help(HistoryTime.label(Int64(time)))
                    }
                } else {
                    Text(model.locating ? "正在读取这一秒…" : "这一秒未记录，不以零瓦补齐")
                    Spacer()
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            if let error = model.detailError { Text(error).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(1).help(error) }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
    private func selectedValue(_ label: String, watts: Double?, estimated: Bool = false, accent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(precisePowerReading(watts, estimated: estimated))
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(accent ? Color.accentColor : Color.primary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var overview: some View {
        HStack(spacing: 12) {
            Text("7 天").font(.system(size: 12)).foregroundStyle(.secondary)
            HistoryOverview(model: model)
        }.help("拖动概览或滑块浏览最近七天。浅橙底为缺口，不跨缺口连接曲线。")
    }
    private var secondTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow { Text("时间"); Text("整机 W"); Text("CPU ≈W"); Text("GPU ≈W"); Text("背光 W") }.font(.system(size: 12, weight: .semibold))
            ForEach(max(nav.oldest, nav.selected - 5)...min(nav.latest, nav.selected + 5), id: \.self) { second in
                let row = model.rows.first { $0.second == second }
                GridRow {
                    Text(shortTime(second)); Text(precisePowerReading(row?.watts, estimated: row?.estimated ?? false))
                    Text(precisePowerReading(row?.cpu)); Text(precisePowerReading(row?.gpu)); Text(precisePowerReading(row?.display))
                }.font(.system(size: 12, design: .monospaced)).foregroundStyle(second == nav.selected ? Color.accentColor : Color.primary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var exactPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("精确定位到秒").font(.headline)
            Text("含 UTC 偏移，夏令时重复小时也能区分。").font(.caption).foregroundStyle(.secondary)
            TextField("yyyy-MM-dd HH:mm:ss +0100", text: $exactTime).textFieldStyle(.roundedBorder).frame(width: 290).onSubmit(locate)
            if let timeError { Text(timeError).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("定位", action: locate).keyboardShortcut(.defaultAction) }
        }.padding(18)
    }
    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("读懂这张图").font(.headline)
            Text("悬停或拖动曲线查看某秒；放大、缩小围绕游标，前移、后移移动半个窗口。概览与滑块可浏览七天。聚焦曲线后，左右方向键逐秒移动，上下方向键缩放。")
            Text("每秒最多一条原始记录。时间分辨率不等于传感器精度；CPU/GPU 为系统模型的区间平均估算，背光仅含内置屏。分项不能相加当作整机总量。")
            Text("W 是功率；Wh 是连续有效样本按实际时间积分的耗电。休眠、退出、跳秒、无效值和调时均中断积分。总量仅代表已覆盖部分，1 kWh = 1000 Wh。")
            Text("浅橙底表示缺口；不跨缺口连接曲线，不伪造零值。选中卡保留直接采样 / 系统缓存 / 估算来源，源时间可悬停查看完整时间。")
        }.font(.system(size: 12)).frame(width: 350).padding(20)
    }
    private func locate() {
        guard let date = HistoryTime.parse(exactTime) else { timeError = "格式不正确，请保留日期、秒和 UTC 偏移。"; return }
        model.seek(Int64(date.timeIntervalSince1970)); showExact = false
    }
    private var rangeLabel: String {
        let f = DateFormatter(); f.dateFormat = nav.span > 86400 ? "MM-dd HH:mm" : "MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: Double(nav.start))) + " — " + f.string(from: Date(timeIntervalSince1970: Double(nav.end)))
    }
    private func shortTime(_ second: Int64) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date(timeIntervalSince1970: Double(second))) }
    private func duration(_ seconds: Double) -> String { seconds >= 3600 ? String(format: "%.1f 小时", seconds / 3600) : (seconds >= 60 ? String(format: "%.1f 分钟", seconds / 60) : String(format: "%.1f 秒", seconds)) }
}

