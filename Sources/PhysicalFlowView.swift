import SwiftUI

// Three physical nodes share a junction: DC input, system board and battery.
struct FlowDiagram: View {
    static let designSize = CGSize(width: 396, height: 184)
    let snapshot: PowerSnapshot
    let reduceMotion: Bool
    var paused = false
    var previewTime: Double? = nil

    private var batteryColor: Color { snapshot.flow == .discharging ? FlowStyle.amber : FlowStyle.aqua }
    private var batteryActive: Bool { snapshot.flow == .charging || snapshot.flow == .discharging }
    private var inputRoute: [CGPoint] { points([(122, 94), (170, 94)]) }
    private var supplyRoute: [CGPoint] { points([(170, 94), (170, 42), (220, 42)]) }
    private var batteryRoute: [CGPoint] { points([(170, 94), (170, 142), (212, 142)]) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            hardware
            TimelineView(.animation(minimumInterval: 1 / 30.0, paused: paused || reduceMotion)) { timeline in
                Canvas { context, _ in
                    let time = reduceMotion ? 0 : (previewTime ?? timeline.date.timeIntervalSinceReferenceDate)
                    drawFlow(&context, inputRoute, power: snapshot.inputWatts,
                             active: snapshot.externalConnected, color: FlowStyle.blue, time: time)
                    drawFlow(&context, supplyRoute, power: snapshot.adapterToComputer,
                             active: snapshot.externalConnected, color: FlowStyle.blue, time: time)
                    let charging = snapshot.externalConnected && snapshot.flow == .charging
                    let discharging = snapshot.flow == .discharging
                    drawFlow(&context, discharging ? Array(batteryRoute.reversed()) : batteryRoute,
                             power: snapshot.batteryWatts.map(abs), active: charging || discharging,
                             color: batteryColor, time: time + 0.3)
                    if discharging {
                        let route = snapshot.externalConnected
                            ? points([(170, 94), (176, 94), (176, 48), (220, 48)])
                            : supplyRoute
                        drawFlow(&context, route, power: snapshot.batteryWatts.map(abs),
                                 active: true, color: FlowStyle.amber, time: time + 0.7)
                    }
                    context.fill(Path(ellipseIn: CGRect(x: 166, y: 90, width: 8, height: 8)),
                                 with: .color(snapshot.externalConnected ? FlowStyle.blue : (discharging ? FlowStyle.amber : FlowStyle.muted)))
                }
            }

            powerSource
            mainboard
            battery
        }
        .frame(width: Self.designSize.width, height: Self.designSize.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("三节点供电图：左侧电源、右上主板、右下电池。\(snapshot.status)。主板节点显示整机用电 \(reading(snapshot.systemWatts, unit: "瓦", digits: 1))。电源输入 \(reading(snapshot.inputWatts, unit: "瓦", digits: 1))。\(batteryDirection) \(reading(snapshot.batteryWatts, unit: "瓦", digits: 1, magnitude: true))。辅助读数：电源 \(reading(snapshot.inputAmps, unit: "安培"))、\(reading(snapshot.inputVolts, unit: "伏特"))；电池 \(reading(snapshot.batteryAmps, unit: "安培", magnitude: true))、\(reading(snapshot.batteryVolts, unit: "伏特"))。")
    }

    private var powerSource: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").foregroundStyle(snapshot.externalConnected ? FlowStyle.blue : FlowStyle.muted)
                Text("电源")
            }.font(.system(size: 12, weight: .medium))
            Text(snapshot.externalConnected ? reading(snapshot.inputWatts, unit: "W", digits: 1) : "未接入")
                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(snapshot.externalConnected ? FlowStyle.blue : FlowStyle.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(snapshot.externalConnected ? (snapshot.inputAmpsEstimated ? "≈" : "") + reading(snapshot.inputAmps, unit: "A") + " · " + reading(snapshot.inputVolts, unit: "V") : "电源未连接")
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(FlowStyle.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
            if snapshot.externalConnected && snapshot.inputWattsEstimated {
                Text("功率推算").font(.system(size: 8)).foregroundStyle(FlowStyle.muted)
            }
        }
        .padding(.horizontal, 8).frame(width: 114, height: 104)
        .position(x: 65, y: 94)
    }

    private var mainboard: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 27, weight: .light)).foregroundStyle(FlowStyle.blue.opacity(0.8))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("主板 · 整机用电").font(.system(size: 10, weight: .medium)).foregroundStyle(FlowStyle.muted)
                Text(reading(snapshot.systemWatts, unit: "W", digits: 1))
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                if snapshot.systemEstimated {
                    Text("估算").font(.system(size: 8)).foregroundStyle(FlowStyle.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).frame(width: 168, height: 76)
        .position(x: 304, y: 42)
    }

    private var battery: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12).fill(FlowStyle.background)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 9)
                    .fill(batteryColor.opacity(batteryActive ? 0.10 : 0.05))
                    .frame(width: max(0, geometry.size.width * (snapshot.percent ?? 0) / 100))
            }.padding(3)
            HStack(spacing: 0) {
                ForEach(0..<3) { _ in
                    Spacer()
                    Rectangle().fill(FlowStyle.line.opacity(0.35)).frame(width: 1).padding(.vertical, 5)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("电池").font(.system(size: 11, weight: .medium))
                    Text(snapshot.percent.map { String(format: "%.0f%%", $0) } ?? "—")
                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(FlowStyle.muted)
                    Spacer(minLength: 2)
                    Image(systemName: !batteryActive ? "pause.fill" : (snapshot.flow == .discharging ? "arrow.up" : "arrow.down"))
                        .font(.system(size: 8))
                    Text(batteryState).font(.system(size: 9, weight: .medium))
                }.foregroundStyle(batteryColor)
                Text(reading(snapshot.batteryWatts, unit: "W", digits: 1, magnitude: true))
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(batteryColor).lineLimit(1).minimumScaleFactor(0.7)
                Text(reading(snapshot.batteryAmps, unit: "A", magnitude: true) + " · " + reading(snapshot.batteryVolts, unit: "V"))
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(FlowStyle.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.horizontal, 10)
        }
        .frame(width: 168, height: 76)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(batteryColor.opacity(0.65), lineWidth: 1.5))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(batteryColor.opacity(0.65))
                .frame(width: 8, height: 18).offset(x: -7)
        }
        .position(x: 304, y: 142)
    }

    private var batteryState: String {
        switch snapshot.flow {
        case .charging: return snapshot.externalConnected ? "充电" : "未知"
        case .discharging: return "放电"
        case .idle: return "待机"
        case .unknown: return "未知"
        }
    }

    private var batteryDirection: String {
        if snapshot.flow == .discharging { return "电池向主板供电" }
        if snapshot.flow == .charging && snapshot.externalConnected { return "电源充入电池" }
        return snapshot.flow == .idle ? "电池待机" : "电池读数未知"
    }

    private var hardware: some View {
        Canvas { context, _ in
            let source = Path(roundedRect: CGRect(x: 8, y: 42, width: 114, height: 104), cornerRadius: 14)
            context.fill(source, with: .color(FlowStyle.blue.opacity(snapshot.externalConnected ? 0.035 : 0.015)))
            context.stroke(source, with: .color(FlowStyle.blue.opacity(snapshot.externalConnected ? 0.25 : 0.12)), lineWidth: 1)

            let board = Path(roundedRect: CGRect(x: 220, y: 4, width: 168, height: 76), cornerRadius: 12)
            context.fill(board, with: .linearGradient(Gradient(colors: [Color.white, FlowStyle.surface]),
                startPoint: CGPoint(x: 220, y: 4), endPoint: CGPoint(x: 388, y: 80)))
            context.stroke(board, with: .color(FlowStyle.line), lineWidth: 1)
            var traces = Path()
            traces.move(to: CGPoint(x: 239, y: 24))
            traces.addLines(points([(239, 15), (266, 15), (270, 11)]))
            traces.move(to: CGPoint(x: 239, y: 60))
            traces.addLines(points([(239, 69), (260, 69), (264, 73)]))
            context.stroke(traces, with: .color(FlowStyle.blue.opacity(0.15)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            for p in points([(226, 10), (382, 10), (226, 74), (382, 74)]) {
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 1.4, y: p.y - 1.4, width: 2.8, height: 2.8)),
                               with: .color(FlowStyle.line), lineWidth: 0.7)
            }
        }
    }

    private func points(_ values: [(Double, Double)]) -> [CGPoint] { values.map { CGPoint(x: $0.0, y: $0.1) } }

    private func drawFlow(_ context: inout GraphicsContext, _ route: [CGPoint], power: Double?, active: Bool, color: Color, time: Double) {
        let flowing = active && (power ?? 0) > 0.1
        var path = Path()
        path.addLines(route)
        context.stroke(path, with: .color(flowing ? color.opacity(0.06) : FlowStyle.line.opacity(0.15)), style: StrokeStyle(lineWidth: flowing ? 11 : 3, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(flowing ? color.opacity(0.35) : FlowStyle.line), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: flowing ? [] : [3, 5]))
        guard flowing else { return }
        // Use arc length so particles have consistent speed on horizontal and vertical wires.
        let count = max(2, Int(length(route) / 26))
        let speed = (24 + min(power ?? 0, 100) * 0.6) / max(1, length(route))
        if !reduceMotion {
            for i in 0..<count {
                let t = (time * speed + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                for trail in (0...4).reversed() {
                    let q = point(max(0, t - Double(trail) * 0.012), route)
                    let radius = trail == 0 ? 3.0 : 2.0
                    context.fill(Path(ellipseIn: CGRect(x: q.x - radius, y: q.y - radius, width: radius * 2, height: radius * 2)), with: .color(color.opacity(1 - Double(trail) * 0.19)))
                }
            }
        }
        for t in [0.35, 0.77] {
            let tip = point(t, route), behind = point(t - 0.025, route)
            let angle = atan2(tip.y - behind.y, tip.x - behind.x)
            var arrow = Path()
            arrow.move(to: CGPoint(x: tip.x - 7 * cos(angle - .pi / 5), y: tip.y - 7 * sin(angle - .pi / 5)))
            arrow.addLine(to: tip)
            arrow.addLine(to: CGPoint(x: tip.x - 7 * cos(angle + .pi / 5), y: tip.y - 7 * sin(angle + .pi / 5)))
            context.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func length(_ route: [CGPoint]) -> Double {
        zip(route, route.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    private func point(_ t: Double, _ route: [CGPoint]) -> CGPoint {
        var distance = min(1, max(0, t)) * length(route)
        for (a, b) in zip(route, route.dropFirst()) {
            let segment = hypot(b.x - a.x, b.y - a.y)
            if distance <= segment {
                let ratio = distance / max(0.001, segment)
                return CGPoint(x: a.x + (b.x - a.x) * ratio, y: a.y + (b.y - a.y) * ratio)
            }
            distance -= segment
        }
        return route.last ?? .zero
    }
}
