import Foundation

@main struct ComponentPowerTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1; precondition(condition(), message)
    }
    static func near(_ value: Double?, _ expected: Double) -> Bool {
        value.map { abs($0 - expected) < 0.0001 } ?? false
    }
    static func main() {
        check(near(ComponentPowerPolicy.watts(energy: 1250, unit: "mJ", seconds: 0.5), 2.5), "毫焦/实际采样秒数换算 W")
        check(near(ComponentPowerPolicy.watts(energy: 4_000_000, unit: "uJ", seconds: 2), 2), "微焦换算 W")
        check(near(ComponentPowerPolicy.watts(energy: 700_000_000, unit: "nJ", seconds: 0.7), 1), "CLPC 纳焦换算 W")
        check(near(ComponentPowerPolicy.watts(energy: 1_000_000, unit: "µJ", seconds: 1), 1), "支持微焦 Unicode 单位")
        check(ComponentPowerPolicy.watts(energy: 0, unit: "nJ", seconds: 1) == 0, "有效计数器的真实零值可显示")
        check(ComponentPowerPolicy.watts(energy: -1, unit: "nJ", seconds: 1) == nil, "计数器回退/重置不变成负功率")
        check(ComponentPowerPolicy.watts(energy: 100, unit: "mW", seconds: 1) == nil, "功率单位不能误当能量单位")
        for seconds in [0.0, -1, 0.01, 311, .nan, .infinity] {
            check(ComponentPowerPolicy.watts(energy: 1, unit: "J", seconds: seconds) == nil, "过短、休眠长间隔或无效时长不能伪造功率")
        }
        check(ComponentPowerPolicy.watts(energy: Int64.max, unit: "nJ", seconds: 1) == nil, "拒绝异常溢出读数")
        let now = Date()
        let legacyCPU = ComponentEnergy(group: "Energy Model", name: "CPU Energy", unit: "mJ", value: 0)
        let legacyGPU = ComponentEnergy(group: "Energy Model", name: "GPU Energy", unit: "mJ", value: 500)
        let cpu = ComponentEnergy(group: "CLPC", name: "CPU Energy", unit: "nJ", value: 5_000_000_000)
        let gpu = ComponentEnergy(group: "CLPC", name: "GPU Energy", unit: "nJ", value: 300_000_000)
        let result = ComponentPowerPolicy.decode([legacyCPU, legacyGPU, cpu, gpu], seconds: 1, at: now, allowLegacyCPU: false)
        check(near(result.cpuWatts, 5) && near(result.gpuWatts, 0.3), "27.0 旧 CPU 恒零时优先使用新 CLPC 聚合计数，不重复相加")
        check(result.sampledAt == now && result.duration == 1, "保留分项独立采样时刻和区间")
        let unsupported = ComponentPowerPolicy.decode([legacyCPU, legacyGPU], seconds: 1, at: now, allowLegacyCPU: false)
        check(unsupported.cpuWatts == nil && near(unsupported.gpuWatts, 0.5), "新系统无可用 CPU 入口时显示缺失，不能把占位零当有效读数")
        let old = ComponentPowerPolicy.decode([legacyCPU, legacyGPU], seconds: 1, at: now, allowLegacyCPU: true)
        check(old.cpuWatts == 0, "旧系统允许使用 Energy Model 聚合报告")
        let core = ComponentEnergy(group: "Energy Model", name: "PCPU0", unit: "mJ", value: 3000)
        let coreOnly = ComponentPowerPolicy.decode([core], seconds: 1, at: now, allowLegacyCPU: true)
        check(coreOnly.cpuWatts == nil && coreOnly.sampledAt == nil, "不将某个核心冒充完整 CPU，也不伪造采样时间")
        let duplicate = ComponentPowerPolicy.decode([cpu, cpu], seconds: 1, at: now, allowLegacyCPU: false)
        check(duplicate.cpuWatts == nil, "重复聚合报告不重复计算，也不任意选取")
        let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
        let ids = ComponentPowerPolicy.clpcIDs(bundle: "com.apple.driver.AppleT6050CLPC", version: version)
        check(ids.map(\.0) == [0x00000010d3ab60bb, 0x0000001927cd4ce5], "M5 Pro 使用已核实的 CPU/GPU 报告 ID")
        check(ComponentPowerPolicy.clpcIDs(bundle: "com.apple.driver.Unknown", version: version).isEmpty, "未知驱动不能套用其他芯片 ID")
        for v in [OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                  OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0),
                  OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0),
                  OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 2)] {
            check(ComponentPowerPolicy.clpcIDs(bundle: "com.apple.driver.AppleT6050CLPC", version: v).isEmpty, "未知系统版本不猜测私有报告兼容性")
        }
        print("PASS: \(count) component power checks — units / intervals / aggregate counters / macOS 27 fallback / compatibility")
    }
}
