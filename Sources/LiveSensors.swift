import Foundation
import IOKit

struct SensorValue {
    let type: String
    let bytes: [UInt8]
}

enum SensorDecoder {
    static func number(_ value: SensorValue, littleEndian: Bool) -> Double? {
        let b = value.bytes
        let type = value.type
        var decoded: Double?
        if type == "flt ", b.count == 4 {
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            decoded = Double(Float(bitPattern: bits))
        } else if b.count == 2 {
            let bits = littleEndian ? UInt16(b[0]) | UInt16(b[1]) << 8 : UInt16(b[0]) << 8 | UInt16(b[1])
            if type == "si16" { decoded = Double(Int16(bitPattern: bits)) }
            else if type == "ui16" { decoded = Double(bits) }
            else if type.hasPrefix("sp"), let fractional = Int(String(type.suffix(1)), radix: 16) {
                decoded = Double(Int16(bitPattern: bits)) / pow(2, Double(fractional))
            } else if type.hasPrefix("fp"), let fractional = Int(String(type.suffix(1)), radix: 16) {
                decoded = Double(bits) / pow(2, Double(fractional))
            }
        }
        return decoded.flatMap { $0.isFinite ? $0 : nil }
    }
}

struct LiveSensorReadings: Sendable {
    var batteryAmps: Double?
    var batteryVolts: Double?
    var inputAmps: Double?
    var inputVolts: Double?
    var inputWatts: Double?
    var systemWatts: Double?

    static func decode(_ values: [String: SensorValue], littleEndian: Bool) -> LiveSensorReadings {
        func valid(_ key: String, range: ClosedRange<Double>, scale: Double = 1) -> Double? {
            guard let raw = values[key], let value = SensorDecoder.number(raw, littleEndian: littleEndian) else { return nil }
            let result = value / scale
            return range.contains(result) ? result : nil
        }
        return LiveSensorReadings(
            batteryAmps: values["B0AC"]?.type == "si16" ? valid("B0AC", range: -30...30, scale: 1000) : nil,
            batteryVolts: values["B0AV"]?.type == "ui16" ? valid("B0AV", range: 5...30, scale: 1000) : nil,
            inputAmps: valid("ID0R", range: 0...30),
            inputVolts: valid("VD0R", range: 0...60),
            inputWatts: valid("PDTR", range: 0...1000),
            systemWatts: valid("PSTR", range: 0...1000)
        )
    }
}

// Only key-info (9) and read-bytes (5) commands exist in this implementation.
// There is no SMC write command and no charge/fan/power-control path.
final class LiveSensorConnection {
    private var connection: io_connect_t = 0
    private var metadata: [String: (UInt32, String)] = [:]
    private var missingKeys = Set<String>()
    private(set) var broken = false
    static let keys = ["B0AC", "B0AV", "ID0R", "VD0R", "PDTR", "PSTR"]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func exchange(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var size = 80
        let result = input.withUnsafeBytes { request in
            output.withUnsafeMutableBytes { response in
                IOConnectCallStructMethod(connection, 2, request.baseAddress, input.count, response.baseAddress, &size)
            }
        }
        guard result == KERN_SUCCESS else { broken = true; return nil }
        guard size == 80, output[40] == 0 else { return nil }
        return output
    }

    private func read(_ key: String) -> SensorValue? {
        guard Self.keys.contains(key), !missingKeys.contains(key) else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        let identifier = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        input.withUnsafeMutableBytes { $0.storeBytes(of: identifier, as: UInt32.self) }
        if metadata[key] == nil {
            input[42] = 9
            guard let info = exchange(input) else { missingKeys.insert(key); return nil }
            let size = info.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
            let type = info.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) }
            let text = String(bytes: [UInt8((type >> 24) & 255), UInt8((type >> 16) & 255), UInt8((type >> 8) & 255), UInt8(type & 255)], encoding: .ascii)
            guard size > 0, size <= 32, let text else { missingKeys.insert(key); return nil }
            metadata[key] = (size, text)
        }
        guard let (size, type) = metadata[key] else { return nil }
        input[42] = 5
        input.withUnsafeMutableBytes { $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self) }
        guard let output = exchange(input) else { return nil }
        return SensorValue(type: type, bytes: Array(output[48..<(48 + Int(size))]))
    }

    func readValues() -> LiveSensorReadings {
        var values: [String: SensorValue] = [:]
        for key in Self.keys { values[key] = read(key) }
        #if arch(arm64)
        return .decode(values, littleEndian: true)
        #else
        return .decode(values, littleEndian: false)
        #endif
    }
}

enum PowerFusion {
    static func merge(_ cached: PowerSnapshot, live: LiveSensorReadings, external: Bool?, at date: Date) -> PowerSnapshot {
        var s = cached
        if let external { s.externalConnected = external }
        s.timestamp = date
        if s.batteryInstalled, let volts = live.batteryVolts, let amps = live.batteryAmps,
           cached.batteryVolts.map({ abs($0 - volts) < 2 }) ?? true {
            s.batteryAmps = amps
            s.batteryVolts = volts
            s.batteryWatts = amps * volts
            s.batterySource = .sensor
            s.batteryUpdatedAt = date
        }
        if s.externalConnected {
            if let amps = live.inputAmps, let volts = live.inputVolts, volts > 0 {
                s.inputAmps = amps
                s.inputVolts = volts
                s.inputWatts = live.inputWatts ?? (amps * volts)
                s.inputAmpsEstimated = false
                s.inputWattsEstimated = live.inputWatts == nil
                s.inputSource = .sensor
                s.inputUpdatedAt = date
            }
        } else {
            // Power-source events are authoritative; never retain DC input after unplug.
            s.inputAmps = 0
            s.inputVolts = nil
            s.inputWatts = 0
            s.adapterRatedWatts = nil
        }
        if let power = live.systemWatts {
            s.systemWatts = power
            s.systemEstimated = false
            s.systemSource = .sensor
            s.systemUpdatedAt = date
        } else if s.batterySource == .sensor, (!s.externalConnected || s.inputSource == .sensor),
                  let input = s.inputWatts, let battery = s.batteryWatts, input - battery >= 0 {
            s.systemWatts = input - battery
            s.systemEstimated = true
            s.systemSource = .sensor
            s.systemUpdatedAt = date
        }
        return s
    }
}
