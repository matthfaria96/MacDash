import AppKit
import CoreBluetooth
import CoreWLAN
import Darwin
import DiskArbitration
import Foundation
import IOBluetooth
import IOKit
import IOKit.ps
import SystemConfiguration

// Readers behind the menu bar panel. Each one is a plain function that is safe
// to call off the main thread; none of them asks for a permission.

// MARK: - Battery

struct BatteryStatus: Equatable, Sendable {
    var percent: Int
    var isCharging: Bool
    var isOnPower: Bool
    var isCharged: Bool
    /// Minutes until empty while discharging, or until full while charging.
    var minutesRemaining: Int?
    var cycleCount: Int?
    var designCycles: Int
    /// Today's full charge against the design capacity.
    var healthPercent: Int?
    var temperature: Double?
}

enum BatteryReader {
    /// Nil on Macs without a battery.
    static func read() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = charging ? description[kIOPSTimeToFullChargeKey] as? Int : description[kIOPSTimeToEmptyKey] as? Int
            var status = BatteryStatus(
                percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: charging,
                isOnPower: onPower,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil,
                cycleCount: nil,
                designCycles: 1000,
                healthPercent: nil,
                temperature: nil
            )
            readSmartBattery(into: &status)
            return status
        }
        return nil
    }

    private static func readSmartBattery(into status: inout BatteryStatus) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return }
        status.cycleCount = values["CycleCount"] as? Int
        if let design = values["DesignCycleCount9C"] as? Int, design > 0 { status.designCycles = design }
        let maximum = values["AppleRawMaxCapacity"] as? Int ?? values["NominalChargeCapacity"] as? Int
        if let maximum, let design = values["DesignCapacity"] as? Int, design > 0 {
            status.healthPercent = min(100, Int((Double(maximum) / Double(design) * 100).rounded()))
        }
        if let centi = values["Temperature"] as? Int, centi > 0 {
            status.temperature = Double(centi) / 100
        }
    }
}

// MARK: - Network

struct NetworkStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case wifi, ethernet, other, offline }
    enum SecurityRating: Equatable, Sendable { case strong, basic, weak, open }

    var kind: Kind
    var name: String
    var interface: String?
    var address: String?
    var security: String?
    var rating: SecurityRating?
    /// Bytes moved through the interface since the Mac started.
    var totalIn: UInt64 = 0
    var totalOut: UInt64 = 0
}

enum NetworkReader {
    static func read() -> NetworkStatus {
        guard let interface = primaryInterface() else {
            return NetworkStatus(kind: .offline, name: String(localized: "Not connected"))
        }
        let counters = byteCounters()[interface] ?? (0, 0)
        let address = ipv4Address(of: interface)
        if let wifi = CWWiFiClient.shared().interface(), wifi.interfaceName == interface {
            let security = describe(wifi.security())
            return NetworkStatus(
                kind: .wifi,
                name: wifi.ssid() ?? "Wi-Fi",
                interface: interface,
                address: address,
                security: security?.name,
                rating: security?.rating,
                totalIn: counters.0,
                totalOut: counters.1
            )
        }
        let name = displayName(of: interface)
        let kind: NetworkStatus.Kind = name.localizedCaseInsensitiveContains("ethernet") || name.localizedCaseInsensitiveContains("thunderbolt") ? .ethernet : .other
        return NetworkStatus(kind: kind, name: name, interface: interface, address: address, totalIn: counters.0, totalOut: counters.1)
    }

    /// The interface macOS routes traffic through right now.
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MacTidy" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return value["PrimaryInterface"] as? String
    }

    /// 64-bit byte counters per interface, so totals don't wrap at 4 GB.
    static func byteCounters() -> [String: (UInt64, UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }
        var result: [String: (UInt64, UInt64)] = [:]
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.load(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        result[String(cString: name)] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    private static func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == interface,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    private static func displayName(of interface: String) -> String {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for item in all where SCNetworkInterfaceGetBSDName(item) as String? == interface {
            if let name = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? { return name }
        }
        return interface
    }

    private static func describe(_ security: CWSecurity) -> (name: String, rating: NetworkStatus.SecurityRating)? {
        switch security {
        case .none: return (String(localized: "No password"), .open)
        case .WEP, .dynamicWEP: return ("WEP", .weak)
        case .wpaPersonal, .wpaPersonalMixed: return ("WPA Personal", .weak)
        case .wpa2Personal: return ("WPA2 Personal", .basic)
        case .personal: return ("WPA/WPA2 Personal", .basic)
        case .wpa3Transition: return ("WPA2/WPA3 Personal", .strong)
        case .wpa3Personal: return ("WPA3 Personal", .strong)
        case .wpaEnterprise, .wpaEnterpriseMixed: return ("WPA Enterprise", .basic)
        case .wpa2Enterprise, .enterprise: return ("WPA2 Enterprise", .strong)
        case .wpa3Enterprise: return ("WPA3 Enterprise", .strong)
        default: return nil
        }
    }
}

// MARK: - Connected devices

struct BluetoothDevice: Identifiable, Equatable, Sendable {
    var id: String { address.isEmpty ? name : address }
    let name: String
    let address: String
    let kind: String
    /// Lowest of the device's batteries, so AirPods show the emptier bud.
    let battery: Int?

    /// The kind in words, for the device list.
    var kindLabel: String {
        switch kind.lowercased() {
        case "headphones", "headset": return String(localized: "Headphones")
        case "keyboard": return String(localized: "Keyboard")
        case "mouse": return String(localized: "Mouse")
        case "trackpad": return String(localized: "Trackpad")
        case "gamepad": return String(localized: "Game controller")
        case "speaker": return String(localized: "Speaker")
        default: return "Bluetooth"
        }
    }

    var symbol: String {
        switch kind.lowercased() {
        case "headphones", "headset": return name.localizedCaseInsensitiveContains("airpods") ? "airpodspro" : "headphones"
        case "keyboard": return "keyboard"
        case "mouse": return "computermouse"
        case "trackpad": return "rectangle.and.hand.point.up.left"
        case "gamepad": return "gamecontroller"
        case "speaker": return "hifispeaker"
        case "phone": return "iphone"
        default: return "wave.3.right"
        }
    }
}

enum BluetoothReader {
    /// Connected devices with their batteries, from System Information.
    static func connected() -> [BluetoothDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [BluetoothDevice] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let fields = value as? [String: Any] else { continue }
                    let levels = ["device_batteryLevelMain", "device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevel"]
                        .compactMap { (fields[$0] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
                    devices.append(BluetoothDevice(
                        name: name,
                        address: fields["device_address"] as? String ?? "",
                        kind: fields["device_minorType"] as? String ?? "",
                        battery: levels.min()
                    ))
                }
            }
        }
        // System Information often leaves batteries out. Fill the gaps the
        // way Control Center does: classic devices from IOBluetooth, Bluetooth
        // LE ones (keyboards, mice) from their standard Battery Service.
        if devices.contains(where: { $0.battery == nil }) {
            var found = AccessoryBatteryReader.classic()
            if devices.contains(where: { $0.battery == nil && found[$0.name] == nil }) {
                found.merge(LowEnergyBatteryReader.read()) { current, _ in current }
            }
            devices = devices.map { device in
                guard device.battery == nil, let level = found[device.name] else { return device }
                return BluetoothDevice(name: device.name, address: device.address, kind: device.kind, battery: level)
            }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The last battery level classic Bluetooth devices (headphones, speakers)
/// reported, as IOBluetooth keeps it. The lowest part wins, as for AirPods.
enum AccessoryBatteryReader {
    static func classic() -> [String: Int] {
        let keys = ["batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight"]
        var result: [String: Int] = [:]
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] where device.isConnected() {
            let levels = keys.compactMap { key -> Int? in
                guard device.responds(to: NSSelectorFromString(key)),
                      let level = (device.value(forKey: key) as? NSNumber)?.intValue, (1...100).contains(level) else { return nil }
                return level
            }
            if let name = device.name, let lowest = levels.min() { result[name] = lowest }
        }
        return result
    }
}

/// Reads the standard Battery Service (0x180F) of connected Bluetooth LE
/// devices, which is where keyboards and mice such as Logitech's report
/// their charge. Blocks for at most `timeout`; call it off the main thread.
/// The first use asks for Bluetooth permission.
final class LowEnergyBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: "180F")
    private static let level = CBUUID(string: "2A19")

    private let queue = DispatchQueue(label: "MacFresh.LowEnergyBattery")
    private let done = DispatchSemaphore(value: 0)
    private var central: CBCentralManager?
    private var peripherals: [CBPeripheral] = []
    private var pending: Set<UUID> = []
    private var levels: [String: Int] = [:]
    private var finished = false

    static func read(timeout: TimeInterval = 4) -> [String: Int] {
        guard CBManager.authorization != .denied, CBManager.authorization != .restricted else { return [:] }
        return LowEnergyBatteryReader().run(timeout: timeout)
    }

    private func run(timeout: TimeInterval) -> [String: Int] {
        queue.sync {
            central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        _ = done.wait(timeout: .now() + timeout)
        return queue.sync {
            finish()
            return levels
        }
    }

    /// Runs on `queue`.
    private func finish() {
        guard !finished else { return }
        finished = true
        peripherals.forEach { central?.cancelPeripheralConnection($0) }
        central?.delegate = nil
        done.signal()
    }

    private func complete(_ peripheral: CBPeripheral) {
        pending.remove(peripheral.identifier)
        if pending.isEmpty { finish() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            peripherals = central.retrieveConnectedPeripherals(withServices: [Self.service])
            pending = Set(peripherals.map(\.identifier))
            guard !peripherals.isEmpty else { return finish() }
            for peripheral in peripherals {
                peripheral.delegate = self
                central.connect(peripheral)
            }
        case .unknown, .resetting:
            break
        default:
            finish()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        complete(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return complete(peripheral) }
        peripheral.discoverCharacteristics([Self.level], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.level }) else { return complete(peripheral) }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let byte = characteristic.value?.first, byte <= 100, let name = peripheral.name {
            levels[name] = Int(byte)
        }
        complete(peripheral)
    }
}

struct ExternalDrive: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    let isReadOnly: Bool
    let isDiskImage: Bool
}

enum ExternalDriveReader {
    static func mounted() -> [ExternalDrive] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey,
            .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsLocalKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true, values.volumeIsRootFileSystem != true,
                  values.volumeIsLocal != false, !url.path.hasPrefix("/System/") else { return nil }
            let external = values.volumeIsInternal == false || values.volumeIsEjectable == true || values.volumeIsRemovable == true
            guard external else { return nil }
            return ExternalDrive(
                url: url,
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                total: Int64(values.volumeTotalCapacity ?? 0),
                available: Int64(values.volumeAvailableCapacity ?? 0),
                isReadOnly: values.volumeIsReadOnly ?? false,
                isDiskImage: isDiskImage(url)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Disk Arbitration names the device model of a mounted .dmg "Disk Image";
    /// volume flags alone can't tell it from a USB drive.
    private static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        return (description[kDADiskDescriptionDeviceModelKey as String] as? String)?
            .trimmingCharacters(in: .whitespaces) == "Disk Image"
    }

    static func eject(_ drive: ExternalDrive) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            (try? NSWorkspace.shared.unmountAndEjectDevice(at: drive.url)) != nil
        }.value
    }
}

// MARK: - Startup disk

struct StartupDiskStatus: Equatable, Sendable {
    var name: String
    var total: Int64
    var available: Int64
    var purgeable: Int64
    var used: Int64 { max(0, total - available) }
}

enum StartupDiskReader {
    static func read() -> StartupDiskStatus? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ]), let total = values.volumeTotalCapacity else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        return StartupDiskStatus(
            name: values.volumeLocalizedName ?? "Macintosh HD",
            total: Int64(total),
            available: important,
            purgeable: max(0, important - plain)
        )
    }

    /// The drive's own SMART verdict, as Disk Utility shows it.
    enum Health: Equatable, Sendable { case verified, failing, unknown }

    static func health() -> Health {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unknown }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let smart = plist["SMARTStatus"] as? String else { return .unknown }
        switch smart.lowercased() {
        case "verified": return .verified
        case "failing": return .failing
        default: return .unknown
        }
    }

    /// Allocated size of a folder, counting each file once.
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    /// Empties the user's Trash. Items that can't be removed stay.
    static func emptyTrash() async -> Int64 {
        await Task.detached(priority: .userInitiated) { () -> Int64 in
            let before = size(of: trashURL)
            let items = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)) ?? []
            for item in items { try? FileManager.default.removeItem(at: item) }
            return max(0, before - size(of: trashURL))
        }.value
    }
}

// MARK: - System

enum SystemLoadReader {
    /// macOS's memory pressure as a percentage, the figure Activity Monitor
    /// graphs: 100 minus the share of memory still available.
    static func memoryPressurePercent() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return max(0, min(100, 100 - Int(level)))
    }
}
