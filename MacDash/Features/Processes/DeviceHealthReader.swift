import DiskArbitration
import Foundation
import IOKit

// What the Health card knows about each disk and the backup. Everything here
// only reads: IOKit's counters and the drive's own wear log, `diskutil info`
// and `tmutil`. Nothing asks for an administrator password, and without Full
// Disk Access nothing touches a protected file or a disk's contents, so
// macOS never shows a permission prompt.

// MARK: - Facts

/// The drive's own wear log (NVMe SMART / Health Information, NVMe 1.0c §5.10.1.2),
/// as Apple's `NVMeSMARTLibExternal.h` lays it out.
struct NVMeWear: Equatable, Sendable {
    var criticalWarning: UInt8
    var temperatureCelsius: Int?
    /// Spare cells left for worn-out ones, in percent.
    var availableSpare: Int
    /// Below this spare the drive itself considers it worn out.
    var spareThreshold: Int
    /// Share of its rated life the drive has used, in percent. Can pass 100.
    var percentUsed: Int
    var bytesWritten: UInt64
    var powerOnHours: UInt64
    /// Data the drive couldn't read back intact.
    var mediaErrors: UInt64

    init(criticalWarning: UInt8 = 0, temperatureCelsius: Int? = nil, availableSpare: Int = 100, spareThreshold: Int = 10,
         percentUsed: Int = 0, bytesWritten: UInt64 = 0, powerOnHours: UInt64 = 0, mediaErrors: UInt64 = 0) {
        self.criticalWarning = criticalWarning
        self.temperatureCelsius = temperatureCelsius
        self.availableSpare = availableSpare
        self.spareThreshold = spareThreshold
        self.percentUsed = percentUsed
        self.bytesWritten = bytesWritten
        self.powerOnHours = powerOnHours
        self.mediaErrors = mediaErrors
    }

    /// Parses the 512-byte log page. Multi-byte fields are little-endian.
    init?(log: [UInt8]) {
        guard log.count >= 512 else { return nil }
        func value(_ offset: Int, _ width: Int) -> UInt64 {
            (0..<width).reduce(UInt64(0)) { $0 | UInt64(log[offset + $1]) << (8 * UInt64($1)) }
        }
        let kelvin = Int(value(1, 2))
        self.init(
            criticalWarning: log[0],
            temperatureCelsius: kelvin > 0 ? kelvin - 273 : nil,
            availableSpare: Int(log[3]),
            spareThreshold: Int(log[4]),
            percentUsed: Int(log[5]),
            // Data units are thousands of 512-byte blocks.
            bytesWritten: value(48, 8) &* 512_000,
            powerOnHours: value(128, 8),
            mediaErrors: value(160, 8)
        )
    }
}

/// The verdict a drive gives Disk Utility.
enum SMARTVerdict: Equatable, Sendable {
    case verified, failing, unavailable
}

struct DriveVolume: Equatable, Sendable {
    let name: String
    let path: String
    let total: Int64
    let available: Int64
    /// Whether Time Machine leaves it out; nil when that couldn't be checked.
    var excludedFromBackup: Bool?
}

/// One physical disk: internal, or plugged in by USB, Thunderbolt or a dock.
struct DriveFacts: Identifiable, Equatable, Sendable {
    /// BSD name of the whole disk, such as "disk4".
    let id: String
    let model: String
    let isInternal: Bool
    /// As IOKit names it: "USB", "Thunderbolt", "Apple Fabric", "PCI-Express", "SATA"…
    let interconnect: String
    let capacity: Int64
    var wear: NVMeWear?
    var smart: SMARTVerdict = .unavailable
    /// Counted by macOS since the disk was connected (or since startup).
    var readErrors: UInt64 = 0
    var writeErrors: UInt64 = 0
    var retries: UInt64 = 0
    var volumes: [DriveVolume] = []
    var isBackupDisk = false

    var errors: UInt64 { readErrors &+ writeErrors }
}

struct BackupFacts: Equatable, Sendable {
    struct Destination: Equatable, Sendable {
        let name: String
        let mountPoint: String?
    }

    var destinations: [Destination] = []
    var lastBackup: Date?
    /// Whether the last backup and the excluded disks could be looked at,
    /// which needs Full Disk Access.
    var checkedDetails = false
}

struct DeviceHealthFacts: Equatable, Sendable {
    var drives: [DriveFacts]
    var backup: BackupFacts
}

// MARK: - Reading

enum DeviceHealthReader {
    /// Slow (a few `diskutil` and `tmutil` calls): run it off the main thread.
    static func read() -> DeviceHealthFacts {
        var backup = BackupFacts(destinations: TimeMachineReader.destinations())
        var drives = physicalDrives()
        for (bsd, volume) in mountedVolumes() {
            guard let index = drives.firstIndex(where: { $0.id == bsd }) else { continue }
            drives[index].volumes.append(volume)
            if backup.destinations.contains(where: { $0.mountPoint == volume.path }) {
                drives[index].isBackupDisk = true
            }
        }
        if !backup.destinations.isEmpty, FullDiskAccessManager.shared.hasFullDiskAccess {
            backup.checkedDetails = true
            let paths = drives.filter { !$0.isInternal && !$0.isBackupDisk }.flatMap { $0.volumes.map(\.path) }
            let excluded = TimeMachineReader.exclusions(of: paths)
            for d in drives.indices {
                for v in drives[d].volumes.indices {
                    drives[d].volumes[v].excludedFromBackup = excluded[drives[d].volumes[v].path]
                }
            }
            // Only a destination that's mounted: asking about one that isn't
            // can make Time Machine go and mount it.
            if backup.destinations.contains(where: { $0.mountPoint != nil }) {
                backup.lastBackup = TimeMachineReader.latestBackup()
            }
        }
        return DeviceHealthFacts(drives: drives.sorted { ($0.isInternal ? 0 : 1, $0.id) < ($1.isInternal ? 0 : 1, $1.id) }, backup: backup)
    }

    /// Every real disk the block storage layer knows, disk images left out.
    static func physicalDrives() -> [DriveFacts] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var drives: [DriveFacts] = []
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            let link = searchUp(driver, "Protocol Characteristics") as? [String: Any] ?? [:]
            let interconnect = link["Physical Interconnect"] as? String ?? ""
            guard interconnect != "Virtual Interface", let media = wholeMedia(of: driver) else { continue }
            let device = searchUp(driver, "Device Characteristics") as? [String: Any] ?? [:]
            let model = (device["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let stats = property(driver, "Statistics") as? [String: Any] ?? [:]
            func count(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            drives.append(DriveFacts(
                id: media.bsd,
                model: model.isEmpty ? media.bsd : model,
                isInternal: (link["Physical Interconnect Location"] as? String) == "Internal",
                interconnect: interconnect,
                capacity: media.size,
                wear: nvmeWear(above: driver),
                smart: smartVerdict(media.bsd),
                readErrors: count("Errors (Read)"),
                writeErrors: count("Errors (Write)"),
                retries: count("Retries (Read)") &+ count("Retries (Write)")
            ))
        }
        return drives
    }

    /// Mounted volumes with the physical disk each one lives on, found by
    /// walking up from the volume past APFS containers and partitions.
    static func mountedVolumes() -> [(bsd: String, volume: DriveVolume)] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal != false, values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0,
                  let bsd = physicalDisk(of: url, session: session) else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            return (bsd, DriveVolume(name: values.volumeLocalizedName ?? url.lastPathComponent, path: url.path,
                                     total: Int64(total), available: available))
        }
    }

    private static func physicalDisk(of url: URL, session: DASession) -> String? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return nil }
        var entry = DADiskCopyIOMedia(disk)
        var top: String?
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOMedia") != 0, (property(entry, "Whole") as? Bool) == true,
               let bsd = property(entry, "BSD Name") as? String {
                top = bsd
            }
            var parent: io_registry_entry_t = 0
            let found = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(entry)
            entry = found ? parent : 0
        }
        return top
    }

    private static func wholeMedia(of driver: io_registry_entry_t) -> (bsd: String, size: Int64)? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOMedia") != 0, let bsd = property(child, "BSD Name") as? String {
                return (bsd, (property(child, "Size") as? NSNumber)?.int64Value ?? 0)
            }
        }
        return nil
    }

    // MARK: NVMe wear

    private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                                                          0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)!
    private static let smartUserClientID = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
                                                                          0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)!
    private static let smartInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
                                                                         0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)!

    /// The start of `IONVMeSMARTInterface`, up to `SMARTReadData`.
    private struct SMARTInterface {
        var reserved: UnsafeMutableRawPointer?
        var queryInterface: @convention(c) (UnsafeMutableRawPointer?, REFIID, UnsafeMutablePointer<LPVOID?>?) -> HRESULT
        var addRef: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
        var release: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
        var version: UInt16
        var revision: UInt16
        var readData: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
    }

    /// The wear log of the NVMe device a block driver sits on, when the
    /// device offers it ("NVMe SMART Capable"). Readable without root.
    private static func nvmeWear(above driver: io_registry_entry_t) -> NVMeWear? {
        var entry: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &entry) == KERN_SUCCESS else { return nil }
        for _ in 0..<3 {
            if (property(entry, "NVMe SMART Capable") as? Bool) == true {
                defer { IOObjectRelease(entry) }
                return readWear(entry)
            }
            var parent: io_registry_entry_t = 0
            let found = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(entry)
            guard found else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }

    private static func readWear(_ service: io_service_t) -> NVMeWear? {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, smartUserClientID, plugInInterfaceID, &plugIn, &score) == KERN_SUCCESS,
              let plugIn, let table = plugIn.pointee else { return nil }
        defer { IODestroyPlugInInterface(plugIn) }
        var pointer: LPVOID?
        guard table.pointee.QueryInterface(plugIn, CFUUIDGetUUIDBytes(smartInterfaceID), &pointer) == 0, let pointer else { return nil }
        let interface = pointer.assumingMemoryBound(to: UnsafeMutablePointer<SMARTInterface>.self)
        defer { _ = interface.pointee.pointee.release(pointer) }
        var log = [UInt8](repeating: 0, count: 512)
        let result = log.withUnsafeMutableBytes { interface.pointee.pointee.readData(pointer, $0.baseAddress) }
        return result == kIOReturnSuccess ? NVMeWear(log: log) : nil
    }

    // MARK: SMART verdict

    private static func smartVerdict(_ bsd: String) -> SMARTVerdict {
        guard let data = Command.output("/usr/sbin/diskutil", ["info", "-plist", bsd]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let status = (plist["SMARTStatus"] as? String)?.lowercased() else { return .unavailable }
        switch status {
        case "verified": return .verified
        case "failing": return .failing
        default: return .unavailable
        }
    }

    // MARK: IOKit helpers

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func searchUp(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
}

// MARK: - Time Machine

enum TimeMachineReader {
    /// Configured destinations. Asks backupd; reads no file.
    static func destinations() -> [BackupFacts.Destination] {
        Command.output("/usr/bin/tmutil", ["destinationinfo", "-X"]).map(parseDestinations) ?? []
    }

    static func parseDestinations(_ data: Data) -> [BackupFacts.Destination] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let list = plist["Destinations"] as? [[String: Any]] else { return [] }
        return list.map {
            BackupFacts.Destination(name: $0["Name"] as? String ?? "Time Machine",
                                    mountPoint: ($0["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Which of these paths Time Machine leaves out. Needs Full Disk Access.
    static func exclusions(of paths: [String]) -> [String: Bool] {
        guard !paths.isEmpty else { return [:] }
        return Command.output("/usr/bin/tmutil", ["isexcluded", "-X"] + paths).map(parseExclusions) ?? [:]
    }

    static func parseExclusions(_ data: Data) -> [String: Bool] {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [:] }
        return list.reduce(into: [:]) { result, item in
            guard let path = item["Path"] as? String else { return }
            result[path] = (item["IsExcluded"] as? NSNumber)?.boolValue ?? false
        }
    }

    /// When the newest backup on a mounted destination was made. Needs Full Disk Access.
    static func latestBackup() -> Date? {
        Command.output("/usr/bin/tmutil", ["latestbackup"])
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(parseBackupDate)
    }

    /// Backups are named after their date: `…/2026-11-14-103000.backup`.
    static func parseBackupDate(_ output: String) -> Date? {
        guard let range = output.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: [.regularExpression, .backwards]) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(output[range]))
    }
}

// MARK: - Running a tool

private enum Command {
    /// A tool's standard output when it exits cleanly. Stopped after a few
    /// seconds, so a stuck tool never holds the card up.
    static func output(_ tool: String, _ arguments: [String], timeout: TimeInterval = 8) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
