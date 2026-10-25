import Foundation
import IOKit
import Darwin

struct ComponentEnergy {
    let group: String
    let name: String
    let unit: String
    let value: Int64
}

struct ComponentPowerReading: Sendable {
    var cpuWatts: Double?
    var gpuWatts: Double?
    var sampledAt: Date?
    var duration: TimeInterval?
}

enum ComponentPowerPolicy {
    static func watts(energy: Int64, unit: String, seconds: TimeInterval) -> Double? {
        guard energy >= 0, seconds.isFinite, seconds >= 0.1, seconds <= 310 else { return nil }
        let scale: Double
        switch unit {
        case "J": scale = 1
        case "mJ": scale = 1e3
        case "uJ", "µJ", "μJ": scale = 1e6
        case "nJ": scale = 1e9
        default: return nil
        }
        let value = Double(energy) / scale / seconds
        return value.isFinite && (0...1000).contains(value) ? value : nil
    }

    static func decode(_ counters: [ComponentEnergy], seconds: TimeInterval,
                       at date: Date, allowLegacyCPU: Bool) -> ComponentPowerReading {
        func power(_ name: String, legacy: Bool) -> Double? {
            // Aggregate reports only: adding core reports would count energy twice.
            for group in legacy ? ["CLPC", "Energy Model"] : ["CLPC"] {
                let matches = counters.filter { $0.group == group && $0.name == name }
                guard matches.count == 1, let counter = matches.first else { continue }
                if let value = watts(energy: counter.value, unit: counter.unit, seconds: seconds) { return value }
            }
            return nil
        }
        let cpu = power("CPU Energy", legacy: allowLegacyCPU)
        let gpu = power("GPU Energy", legacy: true)
        return ComponentPowerReading(cpuWatts: cpu, gpuWatts: gpu,
                                     sampledAt: cpu != nil || gpu != nil ? date : nil,
                                     duration: cpu != nil || gpu != nil ? seconds : nil)
    }

    // macmon's read-only macOS 27.0/27.0.1 aggregate energy catalog.
    // These are report IDs, not power-control properties. See THIRD_PARTY_NOTICES.txt.
    static func clpcIDs(bundle: String, version: OperatingSystemVersion) -> [(UInt64, String)] {
        guard version.majorVersion == 27, version.minorVersion == 0,
              (0...1).contains(version.patchVersion) else { return [] }
        let keys: [String: (UInt32, UInt32)] = [
            "AppleT6000CLPCv3": (0x47479059, 0x4519bf1e),
            "AppleT6002CLPC": (0xb501816b, 0x9e2c3e8b),
            "AppleT6020CLPC": (0xe301cd75, 0x8f34cc7a),
            "AppleT6022CLPC": (0x76f5fd21, 0x90624499),
            "AppleT6030CLPC": (0xbe03a01a, 0x472d6c9c),
            "AppleT6031CLPC": (0xd81e0084, 0x1085f98b),
            "AppleT6032CLPC": (0xf4a21308, 0x85e80513),
            "AppleT6041CLPC": (0x263cf1f0, 0x22e4cf59),
            "AppleT6050CLPC": (0xd3ab60bb, 0x27cd4ce5),
            "AppleT6050dCLPC": (0x18b3010e, 0xedeca11a),
            "AppleT8103CLPCv3": (0x2cdd31f2, 0x21becf42),
            "AppleT8112CLPC": (0xb5435137, 0x638d9d52),
            "AppleT8122CLPC": (0x54b51c99, 0xce2dd9dc),
            "AppleT8132CLPC": (0x4a854d94, 0x3b3e3b79),
            "AppleT8140CLPC": (0x9bf54436, 0xef70589c),
            "AppleT8142CLPC": (0x43708744, 0x6a010933),
            "AppleT8152CLPC": (0x485d4bfc, 0x11784654)
        ]
        let prefix = "com.apple.driver."
        guard bundle.hasPrefix(prefix), let pair = keys[String(bundle.dropFirst(prefix.count))] else { return [] }
        return [((UInt64(16) << 32) | UInt64(pair.0), "CPU Energy"),
                ((UInt64(25) << 32) | UInt64(pair.1), "GPU Energy")]
    }
}

// Dynamically loaded because IOReport is not a stable public SDK. Missing
// symbols/channels yield unavailable readings; no root helper or subprocess.
private final class IOReportAPI {
    typealias CopyAll = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    typealias Sample = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Integer = @convention(c) (CFDictionary, Int32) -> Int64

    let handle: UnsafeMutableRawPointer
    let copyAll: CopyAll
    let group: GetString
    let name: GetString
    let unit: GetString
    let subscribe: Subscribe
    let sample: Sample
    let delta: Delta
    let integer: Integer

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copy = symbol("IOReportCopyAllChannels", CopyAll.self),
              let group = symbol("IOReportChannelGetGroup", GetString.self),
              let name = symbol("IOReportChannelGetChannelName", GetString.self),
              let unit = symbol("IOReportChannelGetUnitLabel", GetString.self),
              let subscribe = symbol("IOReportCreateSubscription", Subscribe.self),
              let sample = symbol("IOReportCreateSamples", Sample.self),
              let delta = symbol("IOReportCreateSamplesDelta", Delta.self),
              let integer = symbol("IOReportSimpleGetIntegerValue", Integer.self) else {
            dlclose(handle); return nil
        }
        self.handle = handle; self.copyAll = copy; self.group = group
        self.name = name; self.unit = unit; self.subscribe = subscribe
        self.sample = sample; self.delta = delta; self.integer = integer
    }
    deinit { dlclose(handle) }

    func text(_ getter: GetString, _ item: CFDictionary) -> String {
        (getter(item)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func items(_ report: CFDictionary) -> [CFMutableDictionary] {
        // IOReport getters cache metadata in their input. Swift value-type
        // dictionaries are immutable bridges; always give the library mutable CF.
        ((report as NSDictionary)["IOReportChannels"] as? [[String: Any]] ?? [])
            .compactMap { CFDictionaryCreateMutableCopy(nil, 0, $0 as CFDictionary) }
    }
}

final class ComponentPowerReader {
    private var api: IOReportAPI?
    private var subscription: CFTypeRef?
    private var channels: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime: TimeInterval?
    private var previousWallTime: Date?
    private var lastAttempt = Date.distantPast
    private var version: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }
    deinit { reset() }

    // Called by LivePowerReader under its existing serialization lock.
    func read() -> ComponentPowerReading {
        if subscription == nil, Date().timeIntervalSince(lastAttempt) >= 30 { connect() }
        guard let api, let subscription, let channels else { return ComponentPowerReading() }
        guard let next = api.sample(subscription, channels, nil)?.takeRetainedValue() else {
            reset(); return ComponentPowerReading()
        }
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        defer { previous = next; previousTime = uptime; previousWallTime = now }
        guard let previous, let previousTime, let previousWallTime else { return ComponentPowerReading() }
        let seconds = uptime - previousTime, wallSeconds = now.timeIntervalSince(previousWallTime)
        // Reset after sleep, a clock discontinuity, or a long gap; never present
        // an overnight average as a fresh instantaneous reading.
        guard seconds >= 0.1, seconds <= 310, abs(wallSeconds - seconds) < 2,
              let delta = api.delta(previous, next, nil)?.takeRetainedValue() else { return ComponentPowerReading() }
        let counters = api.items(delta).map { item in
            ComponentEnergy(group: api.text(api.group, item), name: api.text(api.name, item),
                            unit: api.text(api.unit, item), value: api.integer(item, 0))
        }
        return ComponentPowerPolicy.decode(counters, seconds: seconds, at: now,
                                           allowLegacyCPU: version.majorVersion < 27)
    }

    private func reset() {
        previous = nil; previousTime = nil; previousWallTime = nil
        channels = nil; subscription = nil; api = nil
    }

    private func connect() {
        lastAttempt = Date()
        reset()
        guard let api = IOReportAPI(), let all = api.copyAll(0, 0)?.takeRetainedValue(),
              let request = CFDictionaryCreateMutableCopy(nil, 0, all) else { return }
        var selected = api.items(all).filter { item in
            api.text(api.group, item) == "Energy Model" &&
            ["CPU Energy", "GPU Energy"].contains(api.text(api.name, item))
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var driver: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &driver) == KERN_SUCCESS,
               let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                for (id, name) in ComponentPowerPolicy.clpcIDs(bundle: bundle, version: version) {
                    let item: [String: Any] = [
                        "DriverID": driver, "DriverName": "AppleCLPC", "IOReportGroupName": "CLPC",
                        "IOReportSubGroupName": "Energy Counters",
                        "IOReportChannelInfo": ["IOReportChannelUnit": (Int64(3) << 56) | (Int64(118) << 32)],
                        "LegendChannel": [id, Int64(1) | (Int64(2) << 16) | (Int64(1) << 32), name]
                    ]
                    if let mutable = CFDictionaryCreateMutableCopy(nil, 0, item as CFDictionary) { selected.append(mutable) }
                }
            }
        }
        guard !selected.isEmpty else { return }
        let key = "IOReportChannels" as CFString, array = selected as CFArray
        CFDictionarySetValue(request, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(array).toOpaque())
        var subscribed: Unmanaged<CFMutableDictionary>?
        let subscription = api.subscribe(nil, request, &subscribed, 0, nil)?.takeRetainedValue()
        let channels = subscribed?.takeRetainedValue()
        guard let subscription, let channels else { return }
        self.api = api; self.subscription = subscription; self.channels = channels
    }
}
