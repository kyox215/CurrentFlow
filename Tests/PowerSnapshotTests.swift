import Foundation

@main
struct PowerSnapshotTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fatalError("FAIL: \(message)") }
    }
    static func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }
    static func main() {
        let charging = PowerSnapshot.demo(0)
        check(charging.flow == .charging, "正电流表示充电")
        check(near(charging.batteryWatts, 29.76), "电池端 V×I")
        check(near(charging.inputAmps, 2.6), "实际输入电流来自遥测")
        check(near(charging.adapterToComputer, 22.24), "输入减去电池充电功率得到电脑支路估算")
        let discharge = PowerSnapshot.demo(1)
        check(discharge.flow == .discharging, "负电流表示放电")
        check(discharge.inputWatts == 0 && discharge.inputAmps == 0, "拔电忽略残留的充电器遥测")
        check(discharge.adapterToComputer == nil, "未接电源时无电源分流")
        check(PowerSnapshot.demo(2).flow == .idle, "零电流有效，表示待机")
        check(PowerSnapshot.demo(3).status == "电源 + 电池共同供电", "插电放电为电池补充供电")
        check(near(PowerSnapshot.signedCurrent(NSNumber(value: UInt64.max - 1102)), -1103), "无符号 64 位负数解码")
        check(near(PowerSnapshot.signedCurrent(NSNumber(value: UInt32.max - 1102)), -1103), "无符号 32 位负数解码")
        check(PowerSnapshot.signedCurrent(999999) == nil, "不显示异常巨额电流")
        var base: [String: Any] = ["BatteryInstalled": true, "ExternalConnected": true,
                                  "Voltage": 12000, "Amperage": -1000,
                                  "AdapterDetails": ["Current": 5000, "Watts": 100, "AdapterVoltage": 20000]]
        let noTelemetry = PowerSnapshot.parse(base)
        check(noTelemetry.inputAmps == nil && noTelemetry.inputWatts == nil, "不能把协商上限当成实际输入")
        check(noTelemetry.systemWatts == nil, "外接输入未知时不伪造系统功耗")
        base["PowerTelemetryData"] = ["SystemVoltageIn": 20000, "SystemPowerIn": 40000]
        let fallback = PowerSnapshot.parse(base)
        check(near(fallback.inputAmps, 2) && fallback.inputAmpsEstimated, "缺电流时使用实测 W/V 并注明推算")
        check(near(fallback.systemWatts, 52) && fallback.systemEstimated, "电池放电参与功率平衡")
        base["ExternalConnected"] = false
        base["PowerTelemetryData"] = [:] as [String: Any]
        check(near(PowerSnapshot.parse(base).systemWatts, 12), "纯电池模式的 V×I 回退")
        base["InstantAmperage"] = 999999
        check(near(PowerSnapshot.parse(base).batteryAmps, -1), "瞬时值无效时回退平均电流")
        base["InstantAmperage"] = 0
        check(PowerSnapshot.parse(base).batteryAmps == 0, "瞬时零电流不回退为放电")
        check(!PowerSnapshot.parse([:]).available, "不可读数据不表示正常读数")
        base["CurrentCapacity"] = 4200
        base["MaxCapacity"] = 6000
        check(near(PowerSnapshot.parse(base).percent, 70), "旧款容量 mAh 换算百分比")
        base["BatteryInstalled"] = false
        check(PowerSnapshot.parse(base).batteryAmps == nil, "无电池机器不显示电池电流")
        base["ExternalConnected"] = true
        base["PowerTelemetryData"] = ["SystemCurrentIn": 2000, "SystemVoltageIn": 20000]
        let vi = PowerSnapshot.parse(base)
        check(near(vi.inputWatts, 40) && vi.inputWattsEstimated, "输入功率可由实测 V×I 得到并标注")
        check(near(vi.adapterToComputer, 40), "无电池时全部电源功率给电脑")
        print("PASS: \(count) checks — charging / discharge / idle / supplement / missing values / signed currents")
    }
}
