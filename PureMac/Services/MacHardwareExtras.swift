import AppKit
import Darwin
import Foundation
import IOKit
import SwiftUI

/// Extra facts for the Smart Care "Your Mac" panel: clock speed, Homebrew
/// package counts, displays and the die temperature.
struct MacHardwareExtras: Sendable {
    struct Display: Identifiable, Sendable {
        let id: Int
        let name: String
        let resolution: String
        let refreshHz: Int
        let isRetina: Bool

        var summary: String {
            var parts = [resolution]
            if isRetina { parts.append("Retina") }
            if refreshHz > 0 { parts.append("\(refreshHz) Hz") }
            return parts.joined(separator: " · ")
        }
    }

    let performanceGHz: Double?
    let efficiencyGHz: Double?
    let brewFormulae: Int?
    let brewCasks: Int?
    let language: String

    static func load() -> MacHardwareExtras {
        let (formulae, casks) = brewCounts()
        return MacHardwareExtras(
            performanceGHz: maxGHz(property: "voltage-states5-sram") ?? intelGHz(),
            efficiencyGHz: maxGHz(property: "voltage-states1-sram"),
            brewFormulae: formulae,
            brewCasks: casks,
            language: languageName()
        )
    }

    @MainActor
    static func displays() -> [Display] {
        NSScreen.screens.enumerated().map { index, screen in
            Display(
                id: index,
                name: screen.localizedName,
                resolution: "\(Int(screen.frame.width))×\(Int(screen.frame.height))",
                refreshHz: screen.maximumFramesPerSecond,
                isRetina: screen.backingScaleFactor >= 2
            )
        }
    }

    // MARK: Clock speed

    /// Apple silicon doesn't publish a clock through sysctl. The power manager
    /// lists each core cluster's frequency steps in the I/O Registry; the last
    /// step is the maximum. Older chips store hertz, newer ones kilohertz.
    private static func maxGHz(property key: String) -> Double? {
        let matching = IOServiceMatching("AppleARMIODevice")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            guard String(cString: name) == "pmgr",
                  let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
                  data.count >= 8, data.count % 8 == 0
            else { continue }
            let last = data.count - 8
            let value = data.subdata(in: last..<last + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard value > 0 else { return nil }
            return Double(value) > 100_000_000 ? Double(value) / 1e9 : Double(value) / 1e6
        }
        return nil
    }

    private static func intelGHz() -> Double? {
        var hertz: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.cpufrequency_max", &hertz, &size, nil, 0) == 0, hertz > 0 else { return nil }
        return Double(hertz) / 1e9
    }

    // MARK: Packages and language

    private static func brewCounts() -> (Int?, Int?) {
        let fileManager = FileManager.default
        for prefix in ["/opt/homebrew", "/usr/local"] {
            guard fileManager.fileExists(atPath: "\(prefix)/bin/brew") else { continue }
            func count(_ folder: String) -> Int {
                ((try? fileManager.contentsOfDirectory(atPath: "\(prefix)/\(folder)")) ?? []).filter { !$0.hasPrefix(".") }.count
            }
            return (count("Cellar"), count("Caskroom"))
        }
        return (nil, nil)
    }

    private static func languageName() -> String {
        guard let identifier = Locale.preferredLanguages.first else { return "—" }
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

extension DieTemperature {
    /// How the temperature shows in a meter: text, bar fill and color. Yellow
    /// while normal, orange or red only when the Mac runs hot. Without a
    /// sensor it falls back to macOS's thermal state.
    static func display(_ temperature: Double?, thermalState: ProcessInfo.ThermalState) -> (text: String, fraction: Double, tint: Color) {
        if let temperature {
            return (
                "\(Int(temperature.rounded())) °C",
                max(0.04, min(1, (temperature - 20) / 80)),
                temperature < 80 ? Tint.yellow : (temperature < 92 ? Tint.orange : Tint.red)
            )
        }
        switch thermalState {
        case .nominal: return (String(localized: "Normal"), 0.25, Tint.yellow)
        case .fair: return (String(localized: "Warm"), 0.55, Tint.orange)
        default: return (String(localized: "Running hot"), 0.9, Tint.red)
        }
    }
}

/// Reads the CPU die temperature from the HID sensors Apple silicon exposes.
/// These calls are not public API, so every symbol is looked up at run time and
/// the caller falls back to macOS's thermal state when anything is missing.
enum DieTemperature {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEvent: Int64 = 15

    /// Average of the CPU die sensors, in °C. Nil when no sensor can be read.
    static func read() -> Double? {
        let readings = sensors()
        let die = readings.filter { $0.product.localizedCaseInsensitiveContains("tdie") }.map(\.value)
        let chosen = die.isEmpty ? readings.map(\.value) : die
        guard !chosen.isEmpty else { return nil }
        return chosen.reduce(0, +) / Double(chosen.count)
    }

    /// Average of the internal SSD's NAND sensors, in °C.
    static func readStorage() -> Double? {
        let nand = sensors().filter { $0.product.localizedCaseInsensitiveContains("NAND") }.map(\.value)
        guard !nand.isEmpty else { return nil }
        return nand.reduce(0, +) / Double(nand.count)
    }

    /// Every temperature sensor with a plausible reading, by product name.
    static func sensors() -> [(product: String, value: Double)] {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate").map({ unsafeBitCast($0, to: CreateClient.self) }),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching").map({ unsafeBitCast($0, to: SetMatching.self) }),
              let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices").map({ unsafeBitCast($0, to: CopyServices.self) }),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent").map({ unsafeBitCast($0, to: CopyEvent.self) }),
              let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty").map({ unsafeBitCast($0, to: CopyProperty.self) }),
              let floatValue = dlsym(handle, "IOHIDEventGetFloatValue").map({ unsafeBitCast($0, to: FloatValue.self) }),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return [] }

        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }

        var readings: [(product: String, value: Double)] = []
        for service in services {
            guard let event = copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = floatValue(event, Int32(temperatureEvent << 16))
            guard value > 5, value < 130 else { continue }
            let product = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            readings.append((product, value))
        }
        return readings
    }
}
