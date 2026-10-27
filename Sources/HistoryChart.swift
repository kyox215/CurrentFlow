import SwiftUI

/// Bounded aggregate drawing. Incomplete buckets are isolated envelopes, never
/// connected through missing seconds; no interpolation is used for readouts.
private enum HistoryDrawing {
    static func draw(_ summary: HistorySummary, context: GraphicsContext, plot: CGRect,
                     start: Int64, end: Int64, axes: Bool) {
        let ceiling = max(5, ceil(summary.peak * 1.12 / 5) * 5)
        let width = max(1, summary.bucketWidth)
        func x(_ time: Int64) -> Double { plot.minX + Double(time - start) / Double(max(1, end - start)) * plot.width }
        func y(_ watts: Double) -> Double { plot.maxY - watts / ceiling * plot.height }
        if axes {
            for i in 0...4 {
                let watts = ceiling * Double(i) / 4
                var grid = Path(); grid.move(to: CGPoint(x: plot.minX, y: y(watts))); grid.addLine(to: CGPoint(x: plot.maxX, y: y(watts)))
                context.stroke(grid, with: .color(.secondary.opacity(0.13)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
                context.draw(Text(String(format: "%.0f", watts)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: plot.minX - 10, y: y(watts)), anchor: .trailing)
            }
            context.draw(Text("W").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary), at: CGPoint(x: plot.minX - 10, y: plot.minY - 13), anchor: .trailing)
        }
        // Render gaps including completely absent buckets. This loop is bounded
        // by the aggregation width, not by the 604800 underlying raw seconds.
        let byTime = Dictionary(uniqueKeysWithValues: summary.buckets.map { ($0.second, $0) })
        let lower = summary.lower > 0 ? summary.lower : start
        if summary.buckets.isEmpty {
            context.fill(Path(plot), with: .color(Color.orange.opacity(0.025)))
        } else if summary.bucketWidth > 0, summary.upper >= lower {
            for time in stride(from: lower, through: min(end, summary.upper), by: Int(width)) {
                let bucket = byTime[time]
                if bucket?.complete != true {
                    let left = max(plot.minX, x(time)), right = min(plot.maxX, x(min(end, time + width)))
                    let rect = CGRect(x: left, y: plot.minY, width: max(1, right - left), height: plot.height)
                    context.fill(Path(rect), with: .color(Color.orange.opacity((bucket?.valid ?? 0) > 0 ? 0.06 : 0.035)))
                }
            }
        }
        var segment: [CGPoint] = []
        var previousTime: Int64?
        func flush() {
            guard segment.count > 1 else { segment.removeAll(keepingCapacity: true); return }
            var line = Path(); line.addLines(segment)
            if axes {
                var area = line
                area.addLine(to: CGPoint(x: segment.last!.x, y: plot.maxY))
                area.addLine(to: CGPoint(x: segment.first!.x, y: plot.maxY)); area.closeSubpath()
                context.fill(area, with: .color(.accentColor.opacity(0.07)))
            }
            context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: axes ? 1.7 : 1.1, lineJoin: .round))
            segment.removeAll(keepingCapacity: true)
        }
        for bucket in summary.buckets where bucket.second >= start && bucket.second <= end {
            guard let low = bucket.minimum, let high = bucket.maximum, let average = bucket.average else { flush(); previousTime = nil; continue }
            let point = CGPoint(x: x(bucket.second), y: y(average))
            let color: Color = bucket.complete ? .accentColor : .orange
            var envelope = Path(); envelope.move(to: CGPoint(x: point.x, y: y(low))); envelope.addLine(to: CGPoint(x: point.x, y: y(high)))
            context.stroke(envelope, with: .color(color.opacity(0.3)), lineWidth: 1)
            if bucket.complete {
                if previousTime.map({ bucket.second - $0 != width }) ?? true { flush() }
                segment.append(point)
            } else { flush() }
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.2, y: point.y - 1.2, width: 2.4, height: 2.4)), with: .color(color))
            previousTime = bucket.complete ? bucket.second : nil
        }
        flush()
    }
}

@MainActor
struct HistoryPowerChart: View {
    @ObservedObject var model: HistoryExplorerModel
    private func plot(_ size: CGSize) -> CGRect { CGRect(x: 42, y: 18, width: max(1, size.width - 56), height: max(1, size.height - 49)) }
    private func select(_ point: CGPoint, size: CGSize) {
        let box = plot(size)
        model.select(model.navigation.second(at: (point.x - box.minX) / box.width))
    }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let box = plot(size), nav = model.navigation
                HistoryDrawing.draw(model.summary, context: context, plot: box, start: nav.start, end: nav.end, axes: true)
                let formatter = DateFormatter(); formatter.dateFormat = nav.span <= 900 ? "HH:mm:ss" : (nav.span <= 86400 ? "HH:mm" : "MM-dd HH:mm")
                for i in 0...4 {
                    let time = nav.start + (nav.span - 1) * Int64(i) / 4
                    let label = formatter.string(from: Date(timeIntervalSince1970: Double(time)))
                    let anchor: UnitPoint = i == 0 ? .leading : (i == 4 ? .trailing : .center)
                    context.draw(Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: box.minX + Double(i) / 4 * box.width, y: box.maxY + 18), anchor: anchor)
                }
                let cursorX = box.minX + Double(nav.selected - nav.start) / Double(max(1, nav.span - 1)) * box.width
                var cursor = Path(); cursor.move(to: CGPoint(x: cursorX, y: box.minY)); cursor.addLine(to: CGPoint(x: cursorX, y: box.maxY))
                context.stroke(cursor, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                if !model.loading, model.summary.valid > 0, let watts = model.selectedRow?.watts {
                    let ceiling = max(5, ceil(model.summary.peak * 1.12 / 5) * 5)
                    let point = CGPoint(x: cursorX, y: box.maxY - min(ceiling, watts) / ceiling * box.height)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.accentColor))
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(Color(nsColor: .controlBackgroundColor)), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase, plot(geometry.size).contains(point) { select(point, size: geometry.size) }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { select($0.location, size: geometry.size) })
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: model.step(-1)
            case .right: model.step(1)
            case .up: model.zoom(0.5)
            case .down: model.zoom(2)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("功耗曲线，游标 " + HistoryTime.label(model.navigation.selected))
        .accessibilityValue(precisePowerReading(model.selectedRow?.watts))
        .accessibilityHint("鼠标悬停或拖动定位。聚焦后左右方向键逐秒移动，上下方向键缩放。")
        .accessibilityAction(named: Text("前一秒")) { model.step(-1) }
        .accessibilityAction(named: Text("后一秒")) { model.step(1) }
        .accessibilityAction(named: Text("放大")) { model.zoom(0.5) }
        .accessibilityAction(named: Text("缩小")) { model.zoom(2) }
    }
}

@MainActor
struct HistoryOverview: View {
    @ObservedObject var model: HistoryExplorerModel
    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                Canvas { context, size in
                    let box = CGRect(x: 1, y: 2, width: size.width - 2, height: size.height - 4)
                    HistoryDrawing.draw(model.overview, context: context, plot: box, start: model.overviewStart, end: model.overviewEnd, axes: false)
                    let overviewStart = model.overviewStart
                    func x(_ second: Int64) -> Double { Double(second - overviewStart) / Double(HistoryNavigation.retention - 1) * size.width }
                    let left = max(0, x(model.navigation.start)), right = min(size.width, x(model.navigation.end))
                    let window = CGRect(x: left, y: 0, width: max(3, right - left), height: size.height)
                    context.fill(Path(roundedRect: window, cornerRadius: 4), with: .color(.accentColor.opacity(0.12)))
                    context.stroke(Path(roundedRect: window, cornerRadius: 4), with: .color(.accentColor), lineWidth: 1.5)
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                    model.center(on: model.overviewStart + Int64((Double(HistoryNavigation.retention - 1) * fraction).rounded()))
                })
            }.frame(height: 24)
            if model.navigation.span < HistoryNavigation.retention {
                Slider(value: Binding(get: { Double(model.navigation.center) }, set: { model.center(on: Int64($0.rounded())) }),
                       in: Double(model.navigation.oldest + (model.navigation.span - 1) / 2)...Double(model.navigation.latest - model.navigation.span / 2))
                    .controlSize(.mini).accessibilityLabel("移动历史时间窗口")
            } else { Color.clear.frame(height: 16).accessibilityHidden(true) }

        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("最近七天概览。拖动蓝色窗口或使用滑块浏览。")
    }
}
