import Foundation

@main
struct LiveSensorTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        precondition(condition(), message)
    }
    static func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.001 } ?? false }
    static func float(_ value: Float) -> SensorValue {
        let bits = value.bitPattern
        return SensorValue(type: "flt ", bytes: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
    }
    static func main() {
        let current = SensorValue(type: "si16", bytes: [0xa3, 0x0d])
        let voltage = SensorValue(type: "ui16", bytes: [0xbd, 0x30])
        check(near(SensorDecoder.number(current, littleEndian: true), 3491), "Apple Silicon 电池电流使用小端有符号毫安")
        check(near(SensorDecoder.number(voltage, littleEndian: true), 12477), "Apple Silicon 电池电压使用小端毫伏")
        check(near(SensorDecoder.number(SensorValue(type: "si16", bytes: [0x24, 0xfa]), littleEndian: true), -1500), "小端负放电电流")
        check(near(SensorDecoder.number(SensorValue(type: "si16", bytes: [0xfa, 0x24]), littleEndian: false), -1500), "Intel 大端解码")
        check(near(SensorDecoder.number(float(4.25), littleEndian: true), 4.25), "浮点输入电流")
        check(SensorDecoder.number(float(.nan), littleEndian: true) == nil, "拒绝 NaN")
        check(SensorDecoder.number(float(.infinity), littleEndian: true) == nil, "拒绝无限值")
        check(SensorDecoder.number(SensorValue(type: "si16", bytes: []), littleEndian: true) == nil, "短数据不越界")
        check(near(SensorDecoder.number(SensorValue(type: "sp78", bytes: [0xfe, 0x80]), littleEndian: false), -1.5), "有符号定点数")
        check(near(SensorDecoder.number(SensorValue(type: "fp88", bytes: [1, 128]), littleEndian: false), 1.5), "无符号定点数")
        let decoded = LiveSensorReadings.decode(["B0AC": current, "B0AV": voltage, "ID0R": float(4.3), "VD0R": float(19.7), "PDTR": float(84.71), "PSTR": float(34)], littleEndian: true)
        check(near(decoded.batteryAmps, 3.491) && near(decoded.batteryVolts, 12.477), "正确转换毫安和毫伏")
        check(near(decoded.inputAmps, 4.3) && near(decoded.systemWatts, 34), "电源电流与系统功耗")
        let invalid = LiveSensorReadings.decode(["B0AC": float(3), "B0AV": SensorValue(type: "ui16", bytes: [0xff, 0xff]), "ID0R": float(-1)], littleEndian: true)
        check(invalid.batteryAmps == nil, "未知电池字段类型不能错误标为实时")
        check(invalid.batteryVolts == nil && invalid.inputAmps == nil, "范围与电压校验")
        check(near(LiveSensorReadings.decode(["PDBR": float(1.1)], littleEndian: true).displayWatts, 1.1), "PDBR 屏幕背光读取")
        check(near(LiveSensorReadings.decode(["PBwo": float(2.3), "PDBR": float(1.1)], littleEndian: true).displayWatts, 2.3), "新背光传感器优先，不与旧传感器相加")
        check(LiveSensorReadings.decode(["PBwo": float(.nan), "PDBR": float(-1)], littleEndian: true).displayWatts == nil, "无效背光读数显示缺失")
        check(LiveSensorReadings.decode(["PDBR": float(0)], littleEndian: true).displayWatts == 0, "背光关闭可显示真实零 W")
        let details = LiveSensorReadings.decode(["wiPm": float(0.033), "F0Ac": float(2319), "F1Ac": float(2502)], littleEndian: true)
        check(near(details.wifiWatts, 0.033), "Wi-Fi 小功耗读数保留精度")
        check(details.fanSpeeds.map(\.rpm) == [2319, 2502], "两只风扇使用实际 RPM，不生成假瓦数")
        let secondFan = LiveSensorReadings.decode(["F1Ac": float(0)], littleEndian: true)
        check(secondFan.fanSpeeds.first?.id == 1 && secondFan.fanSpeeds.first?.rpm == 0, "单只风扇缺失不改变另一只的编号，零转速有效")
        let invalidDetails = LiveSensorReadings.decode(["wiPm": float(-1), "F0Ac": float(.infinity), "F1Ac": float(30000)], littleEndian: true)
        check(invalidDetails.wifiWatts == nil && invalidDetails.fanSpeeds.isEmpty, "拒绝无效 Wi-Fi 和风扇值")
        let now = Date()
        let cached = PowerSnapshot.demo(0)
        let live = PowerFusion.merge(cached, live: decoded, external: true, at: now)
        check(near(live.batteryAmps, 3.491) && near(live.inputAmps, 4.3), "新传感器读数替换缓存电流")
        check(near(live.systemWatts, 34) && !live.systemEstimated, "新系统功率替换缓存功率")
        check(live.liveCurrents && live.batterySource == .sensor && live.inputSource == .sensor, "数据来源可确认")
        check(live.batteryUpdatedAt == now && live.inputUpdatedAt == now, "使用传感器读取时刻")
        check(live.freshnessLabel(at: now, interval: 1).hasPrefix("采样"), "展示实际采样时间")
        check(live.freshnessLabel(at: now.addingTimeInterval(20), interval: 1).contains("20 秒未采样"), "停采样会显示超时，不继续宣称实时")
        check(live.systemUpdatedAt == now, "直接整机功耗使用自己的采样时间")
        let backlight = PowerFusion.merge(cached, live: LiveSensorReadings(displayWatts: 1.1), external: true, at: now)
        check(near(backlight.displayWatts, 1.1) && backlight.displayUpdatedAt == now, "背光有自己的采样时间")
        let noBacklight = PowerFusion.merge(backlight, live: LiveSensorReadings(), external: true, at: now)
        check(noBacklight.displayWatts == nil && noBacklight.displayUpdatedAt == nil, "背光读取失败不保留旧值冒充实时")
        let liveDetails = PowerFusion.merge(cached, live: details, external: true, at: now)
        check(near(liveDetails.wifiWatts, 0.033) && liveDetails.detailSensorsUpdatedAt == now, "详情传感器使用独立采样时刻")
        let noDetails = PowerFusion.merge(liveDetails, live: LiveSensorReadings(), external: true, at: now)
        check(noDetails.wifiWatts == nil && noDetails.fanSpeeds.isEmpty && noDetails.detailSensorsUpdatedAt == nil, "不读取详情时清除旧详情硬件值")
        let fallback = PowerFusion.merge(cached, live: LiveSensorReadings(), external: true, at: now)
        check(!fallback.liveCurrents && fallback.batterySource == .systemCache, "传感器不可用明确回退缓存")
        check(fallback.freshnessLabel(at: now, interval: 1) == "系统缓存", "未知缓存时间不伪造刚更新")
        let partial = PowerFusion.merge(cached, live: LiveSensorReadings(inputAmps: 2, inputVolts: 20), external: true, at: now)
        check(!partial.liveCurrents, "部分传感器可用不能把所有值都标成实时")
        check(near(partial.inputWatts, 40) && partial.inputWattsEstimated, "缺输入功率时才使用 V×I")
        let unplugged = PowerFusion.merge(cached, live: LiveSensorReadings(batteryAmps: -1.5, batteryVolts: 12.4, inputAmps: 4, inputVolts: 20), external: false, at: now)
        check(unplugged.flow == .discharging && unplugged.inputAmps == 0 && unplugged.inputWatts == 0, "拔电后不保留电源残留值")
        check(unplugged.adapterRatedWatts == nil && unplugged.inputVolts == nil, "清理断开电源信息")
        check(near(unplugged.systemWatts, 18.6) && unplugged.systemEstimated, "可用电池端推算功耗")
        check(unplugged.systemUpdatedAt == now, "实时推算功耗记录当前测量时刻")
        let badVoltage = PowerFusion.merge(cached, live: LiveSensorReadings(batteryAmps: 5, batteryVolts: 25), external: true, at: now)
        check(badVoltage.batterySource == .systemCache, "不可信电池电压不能覆盖正确缓存")
        let stamp = Date().addingTimeInterval(-45)
        let old = PowerSnapshot.parse(["BatteryInstalled": true, "Voltage": 12400, "Amperage": 1000, "UpdateTime": stamp.timeIntervalSince1970])
        check(old.batteryUpdatedAt.map { abs($0.timeIntervalSince(stamp)) < 0.000001 } ?? false, "记录驱动实际更新时间，允许浮点转换的微秒误差")
        check(old.systemUpdatedAt.map { abs($0.timeIntervalSince(stamp)) < 0.000001 } ?? false, "系统缓存功耗保留驱动更新时间")
        var staleSystem = cached
        staleSystem.systemUpdatedAt = stamp
        let liveBatteryOnly = PowerFusion.merge(staleSystem, live: LiveSensorReadings(batteryAmps: 0, batteryVolts: 12.4), external: true, at: now)
        check(liveBatteryOnly.systemUpdatedAt == stamp && liveBatteryOnly.batteryUpdatedAt == now, "电池实时读取不能刷新缓存整机功耗的时间")
        check(old.freshnessLabel(at: Date(), interval: 0.5).hasPrefix("缓存"), "高频读缓存仍显示缓存状态")
        print("PASS: \(count) live sensor checks — endian / signs / limits / fusion / fallback / freshness / disconnect")
    }
}
