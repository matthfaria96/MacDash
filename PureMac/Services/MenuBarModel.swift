import AppKit
import SwiftUI

/// Which card's detail panel is showing next to the menu bar panel.
enum MenuBarDetail: String, Identifiable, CaseIterable {
    case apps, battery
    var id: String { rawValue }
}

/// Overall verdict in the panel's header.
enum MacHealthVerdict: Equatable {
    case good, fair, poor

    var label: String {
        switch self {
        case .good: return String(localized: "Good")
        case .fair: return String(localized: "Fair")
        case .poor: return String(localized: "Needs attention")
        }
    }

    var tint: Color {
        switch self {
        case .good: return Color(red: 0.42, green: 0.93, blue: 0.85)
        case .fair: return Tint.yellow
        case .poor: return Tint.red
        }
    }
}

struct CPUSample: Identifiable, Equatable {
    let id: Int
    let user: Double
    let system: Double
}

struct ThroughputSample: Identifiable, Equatable {
    let id: Int
    let down: Double
    let up: Double
}

/// Live data for the menu bar panel. Sampling runs only while the panel is
/// open: fast readings every two seconds, slow ones (Bluetooth, drives, folder
/// sizes) far less often.
@MainActor
final class MenuBarModel: ObservableObject {
    static let shared = MenuBarModel()
    static let historyLength = 60

    // Fast
    @Published private(set) var memory: MemorySnapshot?
    @Published private(set) var memoryPressure: Int?
    @Published private(set) var cpuUser: Double = 0
    @Published private(set) var cpuSystem: Double = 0
    @Published private(set) var cpuHistory: [CPUSample] = []
    @Published private(set) var network = NetworkStatus(kind: .offline, name: "")
    @Published private(set) var downRate: Double = 0
    @Published private(set) var upRate: Double = 0
    @Published private(set) var throughput: [ThroughputSample] = []
    @Published private(set) var cpuTemperature: Double?
    /// The detail panel showing, so its heavier readings run only while seen.
    var openDetail: MenuBarDetail? {
        didSet {
            guard openDetail != oldValue, samplingTask != nil else { return }
            Task { await sampleForDetail() }
        }
    }
    private var lastNetworkRead: Date?
    private var lastBluetoothRead: Date?
    @Published private(set) var isReadingBluetooth = false
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    /// The heaviest open apps, by memory, with their CPU share.
    @Published private(set) var topApps: [MemoryAppGroup] = []

    // Slow
    @Published private(set) var disk: StartupDiskStatus?
    @Published private(set) var battery: BatteryStatus?
    @Published private(set) var bluetooth: [BluetoothDevice] = []
    @Published private(set) var drives: [ExternalDrive] = []
    @Published private(set) var diskHealth: StartupDiskReader.Health = .unknown

    // Actions
    @Published private(set) var ejecting: Set<String> = []
    @Published var notice: String?

    private var cpuReader = CPULoadReader()
    private var previousCounters: (inBytes: UInt64, outBytes: UInt64, at: UInt64, interface: String?)?
    private var previousCPU: (nanos: [String: UInt64], at: UInt64)?
    private var sampleID = 0
    private var samplingTask: Task<Void, Never>?
    private var lastSlowRead: Date?
    private var didReadDiskHealth = false
    private var icons: [String: NSImage] = [:]

    var cpuLoad: Double { min(1, cpuUser + cpuSystem) }

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var verdict: MacHealthVerdict {
        var worst = MacHealthVerdict.good
        func lower(to verdict: MacHealthVerdict) {
            if verdict == .poor || (verdict == .fair && worst == .good) { worst = verdict }
        }
        if let disk, disk.total > 0 {
            let free = Double(disk.available) / Double(disk.total)
            if free < 0.05 { lower(to: .poor) } else if free < 0.12 { lower(to: .fair) }
        }
        if let memory {
            if memory.pressure == .critical { lower(to: .poor) } else if memory.pressure == .warning { lower(to: .fair) }
        }
        if let cpuTemperature {
            if cpuTemperature >= 98 { lower(to: .poor) } else if cpuTemperature >= 90 { lower(to: .fair) }
        }
        if thermalState == .critical { lower(to: .poor) } else if thermalState == .serious { lower(to: .fair) }
        if diskHealth == .failing { lower(to: .poor) }
        if let health = battery?.healthPercent {
            if health < 60 { lower(to: .poor) } else if health < 80 { lower(to: .fair) }
        }
        return worst
    }

    func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleFast(tick: tick)
                if self.lastSlowRead.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
                    self.lastSlowRead = Date()
                    await self.sampleSlow()
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        previousCPU = nil
        previousCounters = nil
    }

    // MARK: Sampling

    private func sampleFast(tick: Int) async {
        memory = MemoryReader.snapshot()
        memoryPressure = SystemLoadReader.memoryPressurePercent()
        if let load = cpuReader.read() {
            cpuUser = load.user
            cpuSystem = load.system
            sampleID += 1
            cpuHistory.append(CPUSample(id: sampleID, user: load.user, system: load.system))
            if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
        }

        // The connection's description (name, kind, address) is slow to read
        // and rarely changes: every 30 seconds, off the main thread. Only the
        // byte counters, a cheap sysctl, are read every tick.
        if lastNetworkRead.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
            lastNetworkRead = Date()
            var status = await Task.detached(priority: .utility) { NetworkReader.read() }.value
            status.totalIn = network.totalIn
            status.totalOut = network.totalOut
            network = status
        }
        if let interface = network.interface, let counters = NetworkReader.byteCounters()[interface] {
            let now = DispatchTime.now().uptimeNanoseconds
            if let previous = previousCounters, previous.interface == interface, now > previous.at,
               counters.0 >= previous.inBytes, counters.1 >= previous.outBytes {
                let seconds = Double(now - previous.at) / 1_000_000_000
                downRate = Double(counters.0 - previous.inBytes) / seconds
                upRate = Double(counters.1 - previous.outBytes) / seconds
                throughput.append(ThroughputSample(id: sampleID, down: downRate, up: upRate))
                if throughput.count > Self.historyLength { throughput.removeFirst(throughput.count - Self.historyLength) }
            }
            previousCounters = (counters.0, counters.1, now, interface)
            network.totalIn = counters.0
            network.totalOut = counters.1
        }

        // The heaviest apps: every 6 seconds for the Apps square, every 4
        // while their list is open.
        if needsApps, tick % (openDetail == .apps ? 2 : 3) == 0 {
            await readTopApps()
        }
        if tick % 3 == 0 {
            cpuTemperature = await Task.detached(priority: .utility) { DieTemperature.read() }.value
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private var needsApps: Bool {
        openDetail == .apps || MenuBarPreferences.isVisible(.performance)
    }

    private func readTopApps() async {
        var groups = await Task.detached(priority: .utility) { MemoryReader.groups() }.value
        applyCPU(to: &groups)
        topApps = Array(groups.filter { $0.appPath != nil && $0.appPath != Bundle.main.bundlePath }.prefix(6))
    }

    /// Cheap readings for the cards. Bluetooth (System Information, the
    /// heaviest read) only when the Devices card or its detail is showing.
    private func sampleSlow() async {
        let readings = await Task.detached(priority: .utility) {
            (StartupDiskReader.read(), BatteryReader.read(), ExternalDriveReader.mounted())
        }.value
        disk = readings.0
        battery = readings.1
        drives = readings.2
        // The drive's self-test only feeds the header's verdict; once a run.
        if !didReadDiskHealth {
            didReadDiskHealth = true
            diskHealth = await Task.detached(priority: .utility) { StartupDiskReader.health() }.value
        }
        if MenuBarPreferences.isVisible(.devices) {
            await readBluetoothIfStale()
        }
    }

    /// System Information is the only public source of accessory batteries,
    /// and it's a heavy process, so it runs at most once a minute and the
    /// result is kept between openings of the panel.
    private func readBluetoothIfStale(force: Bool = false) async {
        guard force || (lastBluetoothRead.map { Date().timeIntervalSince($0) >= 60 } ?? true), !isReadingBluetooth else { return }
        isReadingBluetooth = true
        lastBluetoothRead = Date()
        bluetooth = await Task.detached(priority: .utility) { BluetoothReader.connected() }.value
        isReadingBluetooth = false
    }

    /// Readings that belong to one detail panel, taken when it opens.
    private func sampleForDetail() async {
        if openDetail == .apps { await readTopApps() }
    }

    private func applyCPU(to groups: inout [MemoryAppGroup]) {
        let now = DispatchTime.now().uptimeNanoseconds
        let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        if let previousCPU, now > previousCPU.at {
            let elapsed = Double(now - previousCPU.at) * cores
            for index in groups.indices {
                guard let before = previousCPU.nanos[groups[index].id], groups[index].cpuNanos >= before else { continue }
                groups[index].cpuFraction = min(1, Double(groups[index].cpuNanos - before) / elapsed)
            }
        }
        previousCPU = (Dictionary(groups.map { ($0.id, $0.cpuNanos) }, uniquingKeysWith: +), now)
    }

    // MARK: Actions

    func icon(for group: MemoryAppGroup) -> NSImage? {
        guard let path = group.appPath else { return nil }
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    func quit(_ group: MemoryAppGroup) {
        if let path = group.appPath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
            app.terminate()
        }
        topApps.removeAll { $0.id == group.id }
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

    func ejectAll() {
        drives.forEach(eject)
    }

}
