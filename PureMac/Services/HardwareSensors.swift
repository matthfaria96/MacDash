import Foundation
import IOKit

// GPU load, disk activity, fans and system power. Adapted from Performance
// Monitor (MIT, https://github.com/inequitas/performancemonitor), whose SMC
// layout in turn follows Stats (MIT, https://github.com/exelban/stats). Every
// reader here is cheap enough to run on a timer: it keeps the IOKit handle it
// found and asks only for the one property it needs.

// MARK: - GPU

/// GPU utilization from the accelerator's `PerformanceStatistics`.
final class GPUUsageReader: @unchecked Sendable {
    /// The accelerator that answered last time. Matching services costs more
    /// than the read itself, so it's found once and kept; if a read fails it's
    /// dropped and found again.
    private var service: io_service_t = 0
    private let lock = NSLock()

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// 0...1, or nil when no GPU reports it.
    func read() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if service != 0, let value = Self.utilization(of: service) { return value }
        if service != 0 {
            IOObjectRelease(service)
            service = 0
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            if let value = Self.utilization(of: candidate) {
                service = candidate
                return value
            }
            IOObjectRelease(candidate)
        }
        return nil
    }

    private static func utilization(of service: io_service_t) -> Double? {
        guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
              let stats = property.takeRetainedValue() as? [String: Any] else { return nil }
        // Apple silicon reports a fraction; discrete GPUs a percentage.
        if let value = stats["GPU Core Utilization"] as? Double { return min(1, max(0, value)) }
        if let value = stats["Device Utilization %"] as? Int { return min(1, max(0, Double(value) / 100)) }
        return nil
    }
}

// MARK: - Disk activity

/// Bytes read and written per second across the Mac's block storage.
struct DiskActivityReader {
    private var previous: (read: UInt64, write: UInt64, at: UInt64)?

    mutating func read() -> (read: Double, write: Double)? {
        let totals = Self.totals()
        let now = DispatchTime.now().uptimeNanoseconds
        defer { previous = (totals.read, totals.write, now) }
        guard let previous, now > previous.at, totals.read >= previous.read, totals.write >= previous.write else { return nil }
        let seconds = Double(now - previous.at) / 1_000_000_000
        return (Double(totals.read - previous.read) / seconds, Double(totals.write - previous.write) / seconds)
    }

    private static func totals() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0),
                  let stats = property.takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? UInt64) ?? 0
            write &+= (stats["Bytes (Write)"] as? UInt64) ?? 0
        }
        return (read, write)
    }
}

// MARK: - SMC (fans and power)

struct FanReading: Identifiable, Equatable, Sendable {
    let id: Int
    let rpm: Int
    let minimum: Int
    let maximum: Int

    /// Where the fan sits between its idle and full speed, 0...1.
    var fraction: Double {
        guard maximum > minimum else { return 0 }
        return min(1, max(0, Double(rpm - minimum) / Double(maximum - minimum)))
    }
}

/// The kernel structure AppleSMC expects: 84 bytes with `data8` at offset 44.
/// The `keyInfo` sub-structure must keep its own padding, as in Stats.
private struct SMCKeyData {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Read-only access to the System Management Controller: fan speeds and the
/// whole system's power draw. Nothing is ever written.
final class SMCReader: @unchecked Sendable {
    static let shared = SMCReader()

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    let isAvailable: Bool

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { isAvailable = false; return }
        defer { IOObjectRelease(service) }
        isAvailable = IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func fans() -> [FanReading] {
        guard isAvailable, let count = read("FNum")?.bytes.first, count > 0 else { return [] }
        return (0..<Int(count)).compactMap { index in
            guard let rpm = rpm("F\(index)Ac") else { return nil }
            return FanReading(id: index, rpm: rpm, minimum: self.rpm("F\(index)Mn") ?? 0, maximum: self.rpm("F\(index)Mx") ?? 0)
        }
    }

    /// The whole Mac's power draw in watts (`PSTR`).
    func systemPowerWatts() -> Double? {
        guard isAvailable, let value = read("PSTR"), value.type == "flt ", value.bytes.count >= 4 else { return nil }
        let watts = Double(Self.float(value.bytes))
        return watts.isFinite && watts >= 0 && watts < 500 ? watts : nil
    }

    private func rpm(_ key: String) -> Int? {
        guard let value = read(key) else { return nil }
        switch value.type {
        case "flt ":
            guard value.bytes.count >= 4 else { return nil }
            return Int(Self.float(value.bytes).rounded())
        case "fpe2":
            guard value.bytes.count >= 2 else { return nil }
            return (Int(value.bytes[0]) << 6) | (Int(value.bytes[1]) >> 2)
        default:
            return nil
        }
    }

    private static func float(_ bytes: [UInt8]) -> Float {
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Float(bitPattern: bits)
    }

    private func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        lock.lock()
        defer { lock.unlock() }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = Self.fourCC(key)
        input.data8 = 9 // key info
        guard call(&input, &output) else { return nil }
        let size = output.keyInfo.dataSize
        let type = output.keyInfo.dataType
        guard size > 0 else { return nil }
        input.keyInfo.dataSize = size
        input.keyInfo.dataType = type
        input.data8 = 5 // read
        guard call(&input, &output) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(size, 32)))) }
        return (Self.string(type), bytes)
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> Bool {
        let size = MemoryLayout<SMCKeyData>.stride
        var outputSize = size
        let result = IOConnectCallStructMethod(connection, 2, &input, size, &output, &outputSize)
        return result == KERN_SUCCESS && output.result == 0
    }

    private static func fourCC(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        String(bytes: [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)], encoding: .ascii) ?? ""
    }
}
