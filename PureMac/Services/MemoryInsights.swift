import AppKit
import Darwin
import SwiftUI

// Memory breakdown, per-app footprint and the plain-language diagnosis are
// adapted from Kitesail (MIT, https://github.com/jaysahastrabudhe/kitesail).

/// macOS's own memory pressure level, as Activity Monitor shows it.
enum MemoryPressure: Int32, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .warning: return String(localized: "Elevated")
        case .critical: return String(localized: "Critical")
        }
    }

    var tint: Color {
        switch self {
        case .normal: return Tint.green
        case .warning: return Tint.yellow
        case .critical: return Tint.red
        }
    }
}

/// The same buckets Activity Monitor shows.
struct MemorySnapshot: Sendable, Equatable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: MemoryPressure

    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }
}

/// Physical footprint of one app with all of its helper processes.
struct MemoryAppGroup: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let appPath: String?
    var bytes: UInt64
    var pids: [pid_t]
    /// Cumulative CPU time of the group's processes, in nanoseconds.
    var cpuNanos: UInt64 = 0
    /// The same, process by process, so a helper that just started doesn't
    /// read as a spike of all the time it has ever used.
    var pidNanos: [pid_t: UInt64] = [:]
    /// Some processes had no earlier reading, so the CPU share counts only
    /// the measured ones.
    var cpuIsPartial = false
    /// Share of the Mac's total CPU capacity since the previous sample.
    var cpuFraction: Double?
    var family: BackgroundFamily?

    /// Apps outside /System can be quit; Finder, Dock and daemons are left alone.
    var isQuittable: Bool {
        guard let appPath else { return false }
        return !appPath.hasPrefix("/System/") && appPath != Bundle.main.bundlePath
    }
}

/// Well-known macOS services, named for what they do rather than their
/// process names, and grouped so Spotlight's many workers count as one.
enum BackgroundFamily: String, Sendable, CaseIterable {
    case spotlight, webContent, iCloud, photos, timeMachine, windowServer, softwareUpdate, virtualMachine

    static func matching(processName name: String) -> BackgroundFamily? {
        switch name {
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd", "mdsync", "Spotlight":
            return .spotlight
        case let name where name.hasPrefix("com.apple.WebKit."):
            return .webContent
        case "bird", "cloudd", "fileproviderd", "nsurlsessiond", "CloudDocsFileProvider":
            return .iCloud
        case "photoanalysisd", "mediaanalysisd", "photolibraryd", "mediaanalysisd-access":
            return .photos
        case "backupd", "backupd-helper":
            return .timeMachine
        case "WindowServer":
            return .windowServer
        case "softwareupdated", "com.apple.MobileSoftwareUpdate.UpdateBrainService", "mobileassetd":
            return .softwareUpdate
        case "com.apple.Virtualization.VirtualMachine":
            return .virtualMachine
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .spotlight: return "Spotlight"
        case .webContent: return String(localized: "Web pages")
        case .iCloud: return "iCloud"
        case .photos: return String(localized: "Photos analysis")
        case .timeMachine: return "Time Machine"
        case .windowServer: return String(localized: "Screen drawing")
        case .softwareUpdate: return String(localized: "Software Update")
        case .virtualMachine: return String(localized: "Virtual machine")
        }
    }

    var detail: String {
        switch self {
        case .spotlight: return String(localized: "Indexing files so search stays fast")
        case .webContent: return String(localized: "Tabs in Safari and apps that show web content")
        case .iCloud: return String(localized: "Syncing files and data with iCloud")
        case .photos: return String(localized: "Finding faces, objects and text in your library")
        case .timeMachine: return String(localized: "Backing up your Mac")
        case .windowServer: return String(localized: "Draws everything you see on screen")
        case .softwareUpdate: return String(localized: "Downloading or preparing a macOS update")
        case .virtualMachine: return String(localized: "A virtual machine running on this Mac")
        }
    }

    var symbol: String {
        switch self {
        case .spotlight: return "magnifyingglass"
        case .webContent: return "safari"
        case .iCloud: return "icloud"
        case .photos: return "photo.on.rectangle"
        case .timeMachine: return "clock.arrow.circlepath"
        case .windowServer: return "display"
        case .softwareUpdate: return "arrow.down.circle"
        case .virtualMachine: return "server.rack"
        }
    }
}

enum MemoryReader {
    static let gib: UInt64 = 1_073_741_824

    static func snapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        return MemorySnapshot(
            total: ProcessInfo.processInfo.physicalMemory,
            app: (internalPages - min(purgeable, internalPages)) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            pressure: MemoryPressure(rawValue: level) ?? .normal
        )
    }

    /// Physical footprint and CPU time rolled up to the owning .app, so 30
    /// Chrome helpers count as "Google Chrome", or to a known macOS service.
    /// Other users' processes aren't readable without root, so they're skipped.
    static func groups() -> [MemoryAppGroup] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)   // rusage CPU times are Mach ticks on Apple silicon
        var groups: [String: MemoryAppGroup] = [:]

        for pid in pids.prefix(max(0, found)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
            guard ok, info.ri_phys_footprint > 0 else { continue }
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = length > 0 ? String(cString: pathBuffer) : ""
            let owner = identity(path: path, pid: pid)
            let app = owner.app
            var (key, name) = (owner.key, owner.name)
            var family: BackgroundFamily?
            if app == nil, let match = BackgroundFamily.matching(processName: name) {
                family = match
                key = "family:\(match.rawValue)"
                name = match.title
            }
            let ticks = info.ri_user_time &+ info.ri_system_time
            let nanos = ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
            groups[key, default: MemoryAppGroup(id: key, name: name, appPath: app, bytes: 0, pids: [], family: family)].bytes += info.ri_phys_footprint
            groups[key]?.pids.append(pid)
            groups[key]?.cpuNanos &+= nanos
            groups[key]?.pidNanos[pid] = nanos
        }
        return groups.values.sorted { $0.bytes > $1.bytes }
    }

    static func identity(path: String, pid: pid_t) -> (key: String, name: String, app: String?) {
        if let range = path.range(of: ".app/") {
            let app = String(path[..<range.lowerBound]) + ".app"
            return (app, FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: ""), app)
        }
        if !path.isEmpty { return (path, (path as NSString).lastPathComponent, nil) }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        return ("pid-\(name)", name.isEmpty ? "pid \(pid)" : name, nil)
    }
}

/// Total CPU load since the previous reading, split into user and system time.
struct CPULoadReader {
    private var previous: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    mutating func read() -> (user: Double, system: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let now = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { previous = now }
        guard let previous else { return nil }
        let user = Double((now.user &- previous.user) &+ (now.nice &- previous.nice))
        let system = Double(now.system &- previous.system)
        let total = user + system + Double(now.idle &- previous.idle)
        guard total > 0 else { return nil }
        return (min(1, user / total), min(1, system / total))
    }
}

struct MemoryInsight: Identifiable, Equatable {
    enum Tone { case good, warn, bad }
    let id: String
    let symbol: String
    let title: String
    let body: String
    let tone: Tone

    var tint: Color {
        switch tone {
        case .good: return Tint.green
        case .warn: return Tint.yellow
        case .bad: return Tint.red
        }
    }
}

/// Turns raw numbers into "should I quit something, and what?"
enum MemoryDiagnosis {
    static func insights(_ s: MemorySnapshot, top: [MemoryAppGroup], cpu: Double?, temperature: Double?) -> [MemoryInsight] {
        var out: [MemoryInsight] = []
        let mib: UInt64 = 1_048_576
        switch s.pressure {
        case .normal where s.swapUsed > 256 * mib:
            out.append(MemoryInsight(
                id: "pressure", symbol: "checkmark.seal", title: String(localized: "Pressure is normal right now"),
                body: String(format: String(localized: "But %@ was pushed to disk earlier and is still there. Quitting the app that grew largest lets it drain."), formatMemory(s.swapUsed)),
                tone: .warn
            ))
        case .normal:
            out.append(MemoryInsight(
                id: "pressure", symbol: "checkmark.seal.fill", title: String(localized: "Memory pressure is normal"),
                body: String(format: String(localized: "Every app is being served from RAM, so quitting apps won't make your Mac faster. Unused RAM is wasted RAM, and the %@ of file cache is handed back the instant an app needs it."), formatMemory(s.cached)),
                tone: .good
            ))
        case .warning:
            out.append(MemoryInsight(
                id: "pressure", symbol: "exclamationmark.triangle.fill", title: String(localized: "Memory is getting tight"),
                body: String(format: String(localized: "macOS is compressing %@ to make room and is close to swapping. Quitting one heavy app below brings pressure back to normal."), formatMemory(s.compressed)),
                tone: .warn
            ))
        case .critical:
            out.append(MemoryInsight(
                id: "pressure", symbol: "flame.fill", title: String(localized: "Your Mac is out of memory"),
                body: String(localized: "Apps are being pushed out to the SSD, which is why switching windows and typing feel slow. Quit the heaviest app below, starting with ones you aren't using."),
                tone: .bad
            ))
        }

        if s.swapUsed > 256 * mib {
            out.append(MemoryInsight(
                id: "swap", symbol: "arrow.left.arrow.right.circle.fill",
                title: String(format: String(localized: "%@ swapped to disk"), formatMemory(s.swapUsed)),
                body: String(localized: "That much app memory lives on the SSD instead of RAM, so apps stall for a moment when you return to them. Swap only shrinks after pressure drops: quit what grew large, or restart to clear it fully."),
                tone: .warn
            ))
        }

        if s.total > 0, Double(s.compressed) / Double(s.total) > 0.15 {
            out.append(MemoryInsight(
                id: "compression", symbol: "rectangle.compress.vertical", title: String(localized: "Heavy compression"),
                body: String(format: String(localized: "%@ of RAM is being squeezed on the fly. That costs CPU time and battery, and on a fanless Mac it adds heat."), formatMemory(s.compressed)),
                tone: .warn
            ))
        }

        if let heaviest = top.first(where: \.isQuittable), s.total > 0 {
            let share = Double(heaviest.bytes) / Double(s.total)
            let stressed = s.pressure != .normal || s.swapUsed > MemoryReader.gib
            if stressed || share > 0.25 {
                out.append(MemoryInsight(
                    id: "lever", symbol: "scope",
                    title: String(format: String(localized: "%@ is your biggest lever"), heaviest.name),
                    body: String(format: String(localized: "It holds %@, %d%% of your RAM, across %d processes. Quitting it frees about that much at once."), formatMemory(heaviest.bytes), Int(share * 100), heaviest.pids.count),
                    tone: stressed ? .warn : .good
                ))
            }
        }

        let browsers = ["Google Chrome", "Safari", "Arc", "Microsoft Edge", "Brave Browser", "Firefox", "Dia", "Comet", "Opera", "Vivaldi"]
        if let browser = top.first(where: { browsers.contains($0.name) }), browser.pids.count > 6 {
            out.append(MemoryInsight(
                id: "tabs", symbol: "square.stack.3d.up.fill", title: String(localized: "Tabs are processes"),
                body: String(format: String(localized: "%@ runs %d processes. Each open tab and extension is its own. Closing tabs you aren't using frees memory without quitting the browser."), browser.name, browser.pids.count),
                tone: .good
            ))
        }

        if let cpu, cpu > 0.85 {
            out.append(MemoryInsight(
                id: "cpu", symbol: "cpu.fill", title: String(localized: "The processor is busy"),
                body: String(localized: "Something is using most of the CPU. Sort the list below by CPU to see which app it is."),
                tone: .warn
            ))
        }

        if let temperature, temperature >= 92 {
            out.append(MemoryInsight(
                id: "heat", symbol: "thermometer.high", title: String(localized: "Your Mac is running hot"),
                body: String(localized: "macOS may slow the processor down to cool it. Heavy apps and blocked vents both add heat."),
                tone: .bad
            ))
        }
        return out
    }
}

private let memoryFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    // "0 KB" instead of "Zero KB", so the column stays numeric.
    formatter.allowsNonnumericFormatting = false
    return formatter
}()

func formatMemory(_ bytes: UInt64) -> String {
    memoryFormatter.string(fromByteCount: Int64(clamping: bytes))
}

/// One reading for the performance charts.
struct PerformanceSample: Identifiable, Equatable {
    let id: Int
    let date: Date
    let memoryUsedGB: Double
    let swapGB: Double
    let cpu: Double
    let cpuSystem: Double
    let temperature: Double?
    var gpu: Double? = nil
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var netDown: Double = 0
    var netUp: Double = 0
}

/// Live memory, CPU and temperature for the Performance page. Sampling runs
/// only while the page is on screen and MacFresh is the frontmost app.
@MainActor
final class PerformanceModel: ObservableObject {
    static let historyLength = 90
    /// At most this many rows in "Heavy in the background".
    static let backgroundLimit = 4

    @Published private(set) var snapshot: MemorySnapshot?
    /// macOS's memory pressure as a percentage, as the menu bar panel showed it.
    @Published private(set) var pressurePercent: Int?
    /// The heaviest groups of all, which the diagnosis reasons about.
    @Published private(set) var groups: [MemoryAppGroup] = []
    /// macOS services and menu bar apps using a lot right now. Empty when
    /// nothing in the background stands out.
    @Published private(set) var background: [MemoryAppGroup] = []
    @Published private(set) var history: [PerformanceSample] = []
    @Published private(set) var cpuUser: Double = 0
    @Published private(set) var cpuSystem: Double = 0
    @Published private(set) var temperature: Double?
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published var notice: String?

    private var cpuReader = CPULoadReader()
    private let gpuReader = GPUUsageReader()
    private var diskReader = DiskActivityReader()
    private var previousNetwork: (inBytes: UInt64, outBytes: UInt64, at: UInt64, interface: String)?
    private var nextID = 0
    @Published private(set) var gpuLoad: Double?
    @Published private(set) var diskRead: Double = 0
    @Published private(set) var diskWrite: Double = 0
    @Published private(set) var netDown: Double = 0
    @Published private(set) var netUp: Double = 0
    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var powerWatts: Double?
    private var icons: [String: NSImage] = [:]
    private var previousCPU: (nanos: [pid_t: UInt64], at: UInt64)?
    /// The connection and what's plugged in or paired, for the Activity
    /// details; read only while they're open.
    @Published private(set) var connection: NetworkStatus?
    @Published private(set) var bluetooth: [BluetoothDevice] = []
    @Published private(set) var drives: [ExternalDrive] = []
    @Published private(set) var ejecting: Set<String> = []
    @Published private(set) var isReadingDevices = false
    /// The apps the user has open (the ones with a Dock icon), helpers
    /// included, for the Processes list. Comes from the same reading as the
    /// rest of the page, so processes are walked once.
    @Published private(set) var openApps: [ProcessResourceConsumer] = []
    @Published private(set) var hasReadProcesses = false

    var cpuTotal: Double { min(1, cpuUser + cpuSystem) }

    var insights: [MemoryInsight] {
        guard let snapshot else { return [] }
        return MemoryDiagnosis.insights(snapshot, top: groups, cpu: history.isEmpty ? nil : cpuTotal, temperature: temperature)
    }

    /// Runs until the calling task is cancelled.
    /// Runs until the calling task is cancelled. The second reading comes
    /// after one second, since rates (CPU, disk, network) need two.
    func monitor(interval: UInt64 = 2_000_000_000) async {
        var tick = 0
        while !Task.isCancelled {
            // Processes on the first two readings (CPU needs two), then every
            // four seconds; they're the costly part.
            await sample(readTemperature: tick % 2 == 0, readProcesses: tick < 2 || tick % 2 == 0)
            tick += 1
            try? await Task.sleep(nanoseconds: tick == 1 ? 1_000_000_000 : interval)
        }
    }

    /// True until there are enough readings to draw the charts.
    var isCollecting: Bool { history.count < 2 }

    /// One reading. Everything slow is read first, off the main thread;
    /// then every value is published in one go, so the page redraws once per
    /// reading instead of once per value.
    func sample(readTemperature: Bool = true, readProcesses: Bool = true) async {
        var heat: (temperature: Double?, fans: [FanReading], watts: Double?, gpu: Double?)?
        if readTemperature {
            heat = await Task.detached(priority: .utility) { [gpuReader] in
                (DieTemperature.read(), SMCReader.shared.fans(), SMCReader.shared.systemPowerWatts(), gpuReader.read())
            }.value
        }
        var all: [MemoryAppGroup]?
        if readProcesses {
            all = await Task.detached(priority: .utility) { MemoryReader.groups() }.value
        }

        // From here on nothing awaits.
        let memory = MemoryReader.snapshot()
        let cpu = cpuReader.read()
        let activity = diskReader.read()
        let network = readNetwork()
        if let memory { snapshot = memory }
        pressurePercent = SystemLoadReader.memoryPressurePercent()
        if let cpu {
            cpuUser = cpu.user
            cpuSystem = cpu.system
        }
        if let heat {
            temperature = heat.temperature
            thermalState = ProcessInfo.processInfo.thermalState
            fans = heat.fans
            powerWatts = heat.watts
            gpuLoad = heat.gpu
        }
        if let activity {
            diskRead = activity.read
            diskWrite = activity.write
        }
        if let network {
            netDown = network.down
            netUp = network.up
        }
        if let memory, cpu != nil {
            nextID += 1
            history.append(PerformanceSample(
                id: nextID,
                date: Date(),
                memoryUsedGB: Double(memory.used) / Double(MemoryReader.gib),
                swapGB: Double(memory.swapUsed) / Double(MemoryReader.gib),
                cpu: cpuTotal,
                cpuSystem: cpuSystem,
                temperature: temperature,
                gpu: gpuLoad,
                diskRead: diskRead,
                diskWrite: diskWrite,
                netDown: netDown,
                netUp: netUp
            ))
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        if var all {
            applyCPU(to: &all)
            groups = Array(all.prefix(10))
            let opened = Self.openedAppPaths()
            openApps = Self.openApps(from: all, opened: opened)
            hasReadProcesses = true
            background = Self.heavyBackground(
                all,
                openApps: opened,
                total: memory?.total ?? ProcessInfo.processInfo.physicalMemory,
                shown: Set(background.map(\.id))
            )
        }
    }

    /// Download and upload on the interface macOS routes traffic through,
    /// once there are two readings to compare.
    private func readNetwork() -> (down: Double, up: Double)? {
        guard let interface = NetworkReader.primaryInterface(), let counters = NetworkReader.byteCounters()[interface] else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        defer { previousNetwork = (counters.0, counters.1, now, interface) }
        guard let previous = previousNetwork, previous.interface == interface, now > previous.at,
              counters.0 >= previous.inBytes, counters.1 >= previous.outBytes else { return nil }
        let seconds = Double(now - previous.at) / 1_000_000_000
        return (Double(counters.0 - previous.inBytes) / seconds, Double(counters.1 - previous.outBytes) / seconds)
    }

    /// Turns cumulative CPU time into a share of total capacity since the
    /// previous reading, process by process: only processes seen both times
    /// count, and a group missing some is marked partial.
    private func applyCPU(to groups: inout [MemoryAppGroup]) {
        let now = DispatchTime.now().uptimeNanoseconds
        let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        if let previousCPU, now > previousCPU.at {
            let elapsed = Double(now - previousCPU.at) * cores
            for index in groups.indices {
                var spent: UInt64 = 0
                var measured = 0
                for (pid, nanos) in groups[index].pidNanos {
                    guard let before = previousCPU.nanos[pid], nanos >= before else { continue }
                    spent &+= nanos - before
                    measured += 1
                }
                guard measured > 0 else { continue }
                groups[index].cpuFraction = min(1, Double(spent) / elapsed)
                groups[index].cpuIsPartial = measured < groups[index].pidNanos.count
            }
        }
        var nanos: [pid_t: UInt64] = [:]
        for group in groups { nanos.merge(group.pidNanos) { $1 } }
        previousCPU = (nanos, now)
    }

    /// Bundles of the apps the user has open: the ones with a Dock icon.
    static func openedAppPaths() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL?.path })
    }

    /// Only apps the user opened, named as the Dock names them.
    static func openApps(from groups: [MemoryAppGroup], opened: Set<String>) -> [ProcessResourceConsumer] {
        let names = NSWorkspace.shared.runningApplications.reduce(into: [String: String]()) { result, app in
            if let path = app.bundleURL?.path, let name = app.localizedName { result[path] = name }
        }
        return groups.compactMap { group in
            guard let path = group.appPath, opened.contains(path) else { return nil }
            return ProcessResourceConsumer(
                id: "app:\(path)", name: names[path] ?? group.name, applicationPath: path,
                cpuFraction: group.cpuFraction, memoryBytes: group.bytes, processCount: group.pids.count,
                cpuIsPartial: group.cpuIsPartial
            )
        }
    }

    /// Background work that is genuinely heavy: a lot of memory for this Mac,
    /// or a steady share of the processor. Rows already shown stay until they
    /// drop well below the bar, so the list doesn't flicker.
    static func memoryBar(total: UInt64) -> Double { max(768 * 1_048_576, Double(total) * 0.06) }
    static let cpuBar = 0.10

    static func heavyBackground(_ groups: [MemoryAppGroup], openApps: Set<String>, total: UInt64, shown: Set<String>) -> [MemoryAppGroup] {
        let memoryBar = memoryBar(total: total)
        return groups
            .filter { group in
                if let app = group.appPath, openApps.contains(app) { return false }
                if group.appPath == Bundle.main.bundlePath { return false }
                let scale = shown.contains(group.id) ? 0.75 : 1
                return Double(group.bytes) >= memoryBar * scale || (group.cpuFraction ?? 0) >= cpuBar * scale
            }
            .sorted { weight($0, memoryBar: memoryBar, cpuBar: cpuBar) > weight($1, memoryBar: memoryBar, cpuBar: cpuBar) }
            .prefix(backgroundLimit)
            .map { $0 }
    }

    private static func weight(_ group: MemoryAppGroup, memoryBar: Double, cpuBar: Double) -> Double {
        max(Double(group.bytes) / memoryBar, (group.cpuFraction ?? 0) / cpuBar)
    }

    /// Refreshes the connection and devices until the calling task is
    /// cancelled. Bluetooth comes from System Information, a heavy process,
    /// so this runs once a minute.
    func watchConnections() async {
        while !Task.isCancelled {
            isReadingDevices = true
            let readings = await Task.detached(priority: .utility) { (NetworkReader.read(), ExternalDriveReader.mounted()) }.value
            connection = readings.0
            drives = readings.1
            let paired = await Task.detached(priority: .utility) { BluetoothReader.connected() }.value
            guard !Task.isCancelled else { isReadingDevices = false; return }
            bluetooth = paired
            isReadingDevices = false
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    func eject(_ drive: ExternalDrive) {
        ejecting.insert(drive.id)
        Task {
            let ok = await ExternalDriveReader.eject(drive)
            ejecting.remove(drive.id)
            if ok {
                drives.removeAll { $0.id == drive.id }
            } else {
                notice = String(format: String(localized: "%@ couldn't be ejected. An app may still be using it."), drive.name)
            }
        }
    }

    func icon(for group: MemoryAppGroup) -> NSImage? {
        group.appPath.flatMap(icon(forPath:))
    }

    func icon(forPath path: String) -> NSImage? {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    /// Asks the app to quit normally, so it can offer to save documents.
    func quit(_ group: MemoryAppGroup) {
        if let path = group.appPath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            app.terminate()
        } else {
            group.pids.forEach { kill($0, SIGTERM) }
        }
        notice = String(format: String(localized: "Asked %@ to quit."), group.name)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.sample(readTemperature: false, readProcesses: true)
        }
    }
}
