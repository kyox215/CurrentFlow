import SwiftUI
import AppKit

private enum PanelRegion: Hashable { case content, footer }

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: [PanelRegion: CGFloat] = [:]
    static func reduce(value: inout [PanelRegion: CGFloat], nextValue: () -> [PanelRegion: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

enum FlowStyle {
    static let aqua = Color(red: 0.02, green: 0.56, blue: 0.37)
    static let blue = Color(red: 0.16, green: 0.40, blue: 0.84)
    static let amber = Color(red: 0.80, green: 0.43, blue: 0.09)
    static let ink = Color(red: 0.13, green: 0.17, blue: 0.22)
    static let muted = Color(red: 0.45, green: 0.49, blue: 0.55)
    static let background = Color.white
    static let surface = Color(red: 0.96, green: 0.97, blue: 0.985)
    static let line = Color(red: 0.86, green: 0.89, blue: 0.92)
}

struct FlowPanel: View {
    @ObservedObject var monitor: PowerMonitor
    @State private var showDetails = false
    @State private var showCustomInterval = false
    @State private var customInterval = "1"
    @State private var invalidInterval = false
    @AppStorage("reduceFlowMotion") private var reduceMotion = false
    @AppStorage(StartupPolicy.showOnLaunchKey) private var showOnLaunch = false
    @StateObject private var startup = StartupSettings()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var staticPreview = false
    var onSizeChange: (CGSize) -> Void = { _ in }
    let quit: () -> Void

    private var s: PowerSnapshot { monitor.snapshot }
    private var batteryColor: Color { s.flow == .discharging ? FlowStyle.amber : FlowStyle.aqua }

    var body: some View {
        Group {
            if staticPreview {
                VStack(spacing: 0) {
                    mainContent(width: PanelPlacement.preferredSize.width)
                    Spacer(minLength: 0)
                    footer
                }.frame(width: PanelPlacement.preferredSize.width, height: PanelPlacement.preferredSize.height)
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                mainContent(width: geometry.size.width).id("top")
                            }
                            .onChange(of: showCustomInterval) { visible in
                                if visible { proxy.scrollTo("top", anchor: .top) }
                            }
                            .onChange(of: showDetails) { _ in proxy.scrollTo("top", anchor: .top) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        footer
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .foregroundStyle(FlowStyle.ink)
        .background(FlowStyle.background)
        .preferredColorScheme(.light)
        .tint(FlowStyle.blue)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FlowStyle.line.opacity(0.75)))
        .onPreferenceChange(PanelHeightKey.self) { heights in
            guard let content = heights[.content], let footer = heights[.footer] else { return }
            onSizeChange(PanelPlacement.sizeForContent(contentHeight: content, footerHeight: footer))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in startup.refresh() }
        .alert("开机自启设置", isPresented: Binding(get: { startup.notice != nil }, set: { if !$0 { startup.notice = nil } })) {
            if startup.state == .requiresApproval {
                Button("打开系统设置") { startup.openSystemSettings() }
            }
            Button("知道了", role: .cancel) { startup.notice = nil }
        } message: { Text(startup.notice ?? "") }
    }

    private func mainContent(width: CGFloat) -> some View {
        let diagramWidth = max(1, width - 24)
        let scale = min(1, diagramWidth / FlowDiagram.designSize.width)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path").foregroundStyle(FlowStyle.aqua)
                Text("电流脉动").font(.system(size: 13, weight: .semibold))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    HStack(spacing: 4) {
                        Circle().fill(s.liveCurrents && monitor.demoMode == nil ? FlowStyle.aqua : FlowStyle.amber).frame(width: 4, height: 4)
                        Text(monitor.demoMode == nil ? s.freshnessLabel(at: timeline.date, interval: monitor.refreshInterval) : "演示 · 非实测")
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(FlowStyle.muted)
                    }
                }
            }.frame(height: 22)

            HStack {
                Text(s.status).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 5)
                if let percent = s.percent {
                    Image(systemName: s.flow == .charging ? "battery.100percent.bolt" : "battery.75percent")
                    Text(String(format: "%.0f%%", percent)).monospacedDigit()
                }
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(batteryColor)

            if showCustomInterval { customRefreshRow }

            FlowDiagram(snapshot: s, reduceMotion: reduceMotion || systemReduceMotion, paused: !monitor.panelVisible)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: diagramWidth, height: FlowDiagram.designSize.height * scale, alignment: .topLeading)
                .clipped()

            if let error = s.error {
                Text(error).font(.system(size: 10)).foregroundStyle(FlowStyle.amber).fixedSize(horizontal: false, vertical: true)
            }
            if showDetails { details }
        }
        .padding(12).frame(width: width, alignment: .topLeading)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightKey.self, value: [.content: geometry.size.height])
        })
    }

    private var customRefreshRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("刷新间隔").font(.system(size: 10))
                TextField("秒", text: $customInterval)
                    .font(.system(size: 11)).textFieldStyle(.roundedBorder).frame(width: 67)
                    .onSubmit(applyCustomInterval)
                Text("秒").font(.system(size: 10)).foregroundStyle(FlowStyle.muted)
                Spacer(minLength: 0)
                Button("保存", action: applyCustomInterval).buttonStyle(.borderedProminent).controlSize(.mini)
                Button { showCustomInterval = false; invalidInterval = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 9)).help("取消自定义刷新间隔")
            }
            Text(invalidInterval ? "请输入 0.5–300 秒之间的数字" : "支持 0.5–300 秒，设置会自动记住")
                .font(.system(size: 9)).foregroundStyle(invalidInterval ? FlowStyle.amber : FlowStyle.muted)
        }.padding(9).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 9))
    }

    private func applyCustomInterval() {
        guard let interval = RefreshPolicy.parse(customInterval) else { invalidInterval = true; return }
        monitor.setRefreshInterval(interval)
        invalidInterval = false
        showCustomInterval = false
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("整机功耗 · W").font(.system(size: 10, weight: .medium))
                if s.systemEstimated { Text("估算").font(.system(size: 9)) }
                Spacer()
                Text("近 1 分钟").font(.system(size: 9))
            }
            SystemPowerChart(values: monitor.history).frame(height: 50)
            detailRow("电源功率上限", reading(s.adapterRatedWatts, unit: "W", digits: 0))
            if s.systemSource == .systemCache && monitor.demoMode == nil {
                Label("部分读数来自系统缓存", systemImage: "clock")
                    .font(.system(size: 9)).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 9)).foregroundStyle(FlowStyle.muted)
            .padding(10).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            FlowStyle.line.opacity(0.7).frame(height: 0.5)
            HStack(spacing: 12) {
                if staticPreview {
                    Label("刷新 " + RefreshPolicy.label(monitor.refreshInterval), systemImage: "arrow.clockwise")
                    Spacer()
                    Text("详情")
                    Image(systemName: "gearshape")
                } else {
                    Menu {
                        ForEach(RefreshPolicy.presets, id: \.self) { interval in
                            Button {
                                monitor.setRefreshInterval(interval)
                                showCustomInterval = false
                            } label: {
                                if interval == monitor.refreshInterval {
                                    Label(RefreshPolicy.label(interval), systemImage: "checkmark")
                                } else { Text(RefreshPolicy.label(interval)) }
                            }
                        }
                        Divider()
                        Button("立即刷新") { monitor.refresh() }
                        Button("自定义…") {
                            customInterval = String(format: "%g", monitor.refreshInterval)
                            invalidInterval = false
                            showCustomInterval = true
                        }
                    } label: {
                        Label("刷新 " + RefreshPolicy.label(monitor.refreshInterval), systemImage: "arrow.clockwise")
                    }.menuStyle(.borderlessButton).fixedSize().help("调整电流数据刷新间隔")
                    Spacer(minLength: 0)
                    Button { showDetails.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(showDetails ? "收起" : "详情")
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.system(size: 8))
                        }
                    }.buttonStyle(.plain)
                        .accessibilityValue(showDetails ? "已展开" : "已收起")
                        .help(showDetails ? "收起功耗趋势" : "展开整机功耗趋势和电源功率上限")
                    Menu {
                        Toggle(startup.menuTitle, isOn: Binding(get: { startup.registered }, set: { startup.setEnabled($0) }))
                        Toggle("启动时展开面板", isOn: $showOnLaunch)
                        Button(startup.state == .requiresApproval ? "在系统设置中允许…" : "系统登录项设置…") { startup.openSystemSettings() }
                        Divider()
                        Toggle("流动动效", isOn: Binding(get: { !reduceMotion }, set: { reduceMotion = !$0 }))
                        Divider()
                        Button("实时硬件数据") { monitor.selectDemo(nil) }
                        Menu("演示") {
                            Button("边用边充") { monitor.selectDemo(0) }
                            Button("电池供电") { monitor.selectDemo(1) }
                            Button("电池待机") { monitor.selectDemo(2) }
                            Button("共同供电") { monitor.selectDemo(3) }
                        }
                        Divider()
                        Button("关于电流脉动 \(AppInfo.version)") { AppInfo.showAbout() }
                        Button("退出电流脉动", action: quit)
                    } label: { Image(systemName: "gearshape") }
                        .menuStyle(.borderlessButton).fixedSize().help("设置与退出")
                }
            }
            .font(.system(size: 10)).foregroundStyle(FlowStyle.muted)
            .padding(.horizontal, 14).padding(.vertical, 11)
        }.background(FlowStyle.background)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightKey.self, value: [.footer: geometry.size.height])
            })
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(minLength: 4); Text(value).monospacedDigit() }
    }
}

struct SystemPowerChart: View {
    let values: [PowerSample]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let samples = PowerHistory.recent(values, at: timeline.date)
            let scale = PowerHistory.upperBound(for: samples)
            HStack(spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(String(format: "%.0f W", scale))
                    Spacer()
                    Text("0")
                }.font(.system(size: 8)).monospacedDigit().frame(width: 30)
                Canvas { context, size in
                    func x(_ sample: PowerSample) -> Double { max(0, 1 - timeline.date.timeIntervalSince(sample.timestamp) / 60) * (size.width - 4) + 2 }
                    func y(_ value: Double) -> Double { size.height - 3 - value / scale * (size.height - 6) }
                    for level in [0.0, scale / 2, scale] {
                        var grid = Path()
                        grid.move(to: CGPoint(x: 0, y: y(level)))
                        grid.addLine(to: CGPoint(x: size.width, y: y(level)))
                        context.stroke(grid, with: .color(FlowStyle.line), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                    }
                    for i in samples.indices where i > 0 {
                        guard let a = samples[i - 1].watts, let b = samples[i].watts else { continue }
                        var segment = Path()
                        segment.move(to: CGPoint(x: x(samples[i - 1]), y: y(a)))
                        segment.addLine(to: CGPoint(x: x(samples[i]), y: y(b)))
                        context.stroke(segment, with: .color(FlowStyle.blue), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    }
                    if let last = samples.last, let watts = last.watts {
                        context.fill(Path(ellipseIn: CGRect(x: x(last) - 2, y: y(watts) - 2, width: 4, height: 4)), with: .color(FlowStyle.blue))
                    }
                }.overlay {
                    if !samples.contains(where: { $0.watts != nil }) {
                        Text("等待功耗采样…").font(.system(size: 9))
                    }
                }
            }
        }.accessibilityLabel("整机功耗最近一分钟趋势，单位瓦。")
    }
}
