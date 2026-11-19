import Darwin
import Foundation
import IOKit

/// Who this Mac is: name, model, chip, memory, cores and macOS. Read once,
/// from sysctl and the I/O Registry, without asking for any permission.
struct MacSystemInfo {
    let computerName: String
    let hardwareModel: String
    /// What Apple calls it, year included: "Mac mini (2024)". Falls back to
    /// the family when the registry doesn't say.
    let modelName: String
    let productFamily: String
    let symbol: String
    let chip: String
    let memory: String
    let coreSummary: String
    let osVersion: String
    let osVersionWithBuild: String
    /// "26B131".
    let osBuild: String?

    static let current = MacSystemInfo()

    private init() {
        computerName = DemoMode.isActive ? DemoMode.computerName : Host.current().localizedName ?? String(localized: "This Mac")
        let model = Self.sysctlString("hw.model") ?? String(localized: "Unknown")
        hardwareModel = model
        let lower = model.lowercased()
        let name = computerName.lowercased()
        // Apple silicon models are "MacNN,N"; the registry has the real name.
        let registryName = Self.registryProductName()
        let families = ["MacBook Pro", "MacBook Air", "Mac mini", "Mac Studio", "Mac Pro", "iMac", "MacBook"]
        if let registryName, let known = families.first(where: { registryName.hasPrefix($0) }) {
            productFamily = known
        } else if let known = families.first(where: { name.contains($0.lowercased()) }) {
            productFamily = known
        } else if lower.hasPrefix("macbookpro") { productFamily = "MacBook Pro" }
        else if lower.hasPrefix("macbookair") { productFamily = "MacBook Air" }
        else if lower.hasPrefix("macbook") { productFamily = "MacBook" }
        else if lower.hasPrefix("macmini") { productFamily = "Mac mini" }
        else if lower.hasPrefix("macstudio") { productFamily = "Mac Studio" }
        else if lower.hasPrefix("macpro") { productFamily = "Mac Pro" }
        else if lower.hasPrefix("imac") { productFamily = "iMac" }
        else { productFamily = "Mac" }
        modelName = registryName ?? productFamily
        switch productFamily {
        case "Mac mini": symbol = "macmini"
        case "Mac Studio": symbol = "macstudio"
        case "Mac Pro": symbol = "macpro.gen3"
        case let family where family.hasPrefix("MacBook"): symbol = "laptopcomputer"
        default: symbol = "desktopcomputer"
        }

        if let name = Self.sysctlString("machdep.cpu.brand_string"), !name.isEmpty {
            chip = name.replacingOccurrences(of: "  ", with: " ")
        } else {
            chip = String(localized: "Apple silicon")
        }
        memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: ProcessInfo.processInfo.physicalMemory), countStyle: .memory)

        let total = ProcessInfo.processInfo.processorCount
        if let performance = Self.sysctlInt("hw.perflevel0.physicalcpu"),
           let efficiency = Self.sysctlInt("hw.perflevel1.physicalcpu"), efficiency > 0 {
            coreSummary = "\(total) (\(performance)P + \(efficiency)E)"
        } else {
            coreSummary = "\(total)"
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let short = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        osBuild = Self.sysctlString("kern.osversion")
        osVersionWithBuild = osBuild.map { "\(short) (\($0))" } ?? short
    }

    static var uptimeText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: ProcessInfo.processInfo.systemUptime) ?? "—"
    }

    /// "Mac mini (2024)" from the device tree's product node, when present.
    private static func registryProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
