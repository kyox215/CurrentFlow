import Foundation
import IOKit
import IOKit.ps

enum PowerReader {
    private static let live = LivePowerReader()

    static func read(includeDetails: Bool = false) -> PowerSnapshot {
        live.read(includeDetails: includeDetails)
    }

    fileprivate static func readRegistry() -> PowerSnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            var result = PowerSnapshot()
            result.error = "系统未提供 AppleSmartBattery 数据。台式 Mac 或访问受限时，部分数据不可用。"
            return result
        }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        let code = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard code == KERN_SUCCESS, let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            var result = PowerSnapshot()
            result.error = "电源数据读取失败（\(code)），正在等待下次采样。"
            return result
        }
        return PowerSnapshot.parse(dictionary)
    }
}

// CLI reads and background application samples share a serialized, reusable
// connection. No driver properties or power settings are written.
private final class LivePowerReader: @unchecked Sendable {
    private let lock = NSLock()
    private var sensors: LiveSensorConnection?
    private var lastOpenAttempt = Date.distantPast
    private let components = ComponentPowerReader()

    func read(includeDetails: Bool) -> PowerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let cached = PowerReader.readRegistry()
        if sensors == nil, Date().timeIntervalSince(lastOpenAttempt) >= 10 {
            lastOpenAttempt = Date()
            sensors = LiveSensorConnection()
        }
        let readings = sensors?.readValues(includeDetails: includeDetails) ?? LiveSensorReadings()
        if sensors?.broken == true { sensors = nil; lastOpenAttempt = .distantPast }
        var external: Bool?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            if type == "AC Power" { external = true }
            else if type == "Battery Power" { external = false }
        }
        var result = PowerFusion.merge(cached, live: readings, external: external, at: Date())
        let parts = components.read()
        result.cpuWatts = parts.cpuWatts
        result.gpuWatts = parts.gpuWatts
        result.componentsUpdatedAt = parts.sampledAt
        result.componentSampleDuration = parts.duration
        return result
    }
}
