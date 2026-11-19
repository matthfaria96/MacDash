import AppKit
import Darwin
import Foundation

struct ProcessResourceConsumer: Identifiable, Sendable {
    let id: String
    var name: String
    let applicationPath: String?
    var cpuFraction: Double?
    /// Physical footprint, the "Memory" Activity Monitor shows: what the app
    /// itself holds, without pages it shares with other processes.
    var memoryBytes: UInt64
    var processCount: Int
    /// A member without an interval yet (new process or recycled PID) leaves
    /// the group's CPU as the sum of its measured members only.
    var cpuIsPartial = false
}

enum ProcessResourceSort: String, CaseIterable, Identifiable {
    case cpu, memory
    var id: Self { self }
}

/// Includes the kernel start time so a recycled PID never inherits CPU counters.
struct ProcessResourceReading: Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
    let name: String
    let cpuTicks: UInt64
    let memoryBytes: UInt64
    let sampledAt: UInt64

    var identity: String { "\(pid):\(startSeconds):\(startMicroseconds)" }
}

enum ProcessResourceMath {
    /// The first bundle owns nested helpers, XPC services and embedded apps.
    static func applicationPath(for executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        let components = (executablePath as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components.prefix(through: index)))
    }

    static func cpuFraction(current: ProcessResourceReading, previous: ProcessResourceReading?, processorCount: Int, nanosecondsPerTick: Double = 1) -> Double? {
        guard let previous, previous.identity == current.identity,
              previous.executablePath == current.executablePath,
              current.sampledAt > previous.sampledAt,
              current.cpuTicks >= previous.cpuTicks,
              processorCount > 0, nanosecondsPerTick.isFinite, nanosecondsPerTick > 0 else { return nil }
        let elapsed = Double(current.sampledAt - previous.sampledAt)
        let cpu = Double(current.cpuTicks - previous.cpuTicks) * nanosecondsPerTick
        return min(1, max(0, cpu / elapsed / Double(processorCount)))
    }

    static func consumers(readings: [ProcessResourceReading], previous: [String: ProcessResourceReading], processorCount: Int, nanosecondsPerTick: Double = 1) -> [ProcessResourceConsumer] {
        var groups: [String: ProcessResourceConsumer] = [:]
        for reading in readings {
            let application = applicationPath(for: reading.executablePath)
            // Unknown executable paths remain separate; similarly named processes
            // must not be attributed to an application without evidence.
            let id = application.map { "app:\($0)" }
                ?? (reading.executablePath.isEmpty ? "pid:\(reading.identity)" : "exe:\(reading.executablePath)")
            let cpu = cpuFraction(current: reading, previous: previous[reading.identity], processorCount: processorCount, nanosecondsPerTick: nanosecondsPerTick)
            if var group = groups[id] {
                group.memoryBytes = group.memoryBytes.addingReportingOverflow(reading.memoryBytes).overflow
                    ? UInt64.max : group.memoryBytes + reading.memoryBytes
                group.processCount += 1
                if let cpu {
                    group.cpuFraction = min(1, (group.cpuFraction ?? 0) + cpu)
                } else {
                    group.cpuIsPartial = true
                }
                groups[id] = group
            } else {
                let name = application.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                    ?? reading.name
                groups[id] = ProcessResourceConsumer(id: id, name: name, applicationPath: application,
                                                     cpuFraction: cpu, memoryBytes: reading.memoryBytes, processCount: 1,
                                                     cpuIsPartial: cpu == nil)
            }
        }
        return Array(groups.values)
    }

    /// Processes that started or stopped since the previous sample. The first
    /// sample has no baseline, so nothing counts as changed yet.
    static func changedProcessCount(readings: [ProcessResourceReading], previous: [String: ProcessResourceReading]) -> Int {
        guard !previous.isEmpty else { return 0 }
        let current = Set(readings.map(\.identity))
        let started = current.subtracting(previous.keys).count
        let stopped = previous.keys.filter { !current.contains($0) }.count
        return started + stopped
    }

    static func sorted(_ consumers: [ProcessResourceConsumer], by sort: ProcessResourceSort, ascending: Bool = false, search: String = "") -> [ProcessResourceConsumer] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = consumers.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.sorted {
            switch sort {
            case .cpu:
                if $0.cpuFraction != $1.cpuFraction { return ($0.cpuFraction ?? -1) > ($1.cpuFraction ?? -1) }
                if $0.memoryBytes != $1.memoryBytes { return $0.memoryBytes > $1.memoryBytes }
            case .memory:
                if $0.memoryBytes != $1.memoryBytes { return $0.memoryBytes > $1.memoryBytes }
            }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        return ascending ? ordered.reversed() : ordered
    }
}
