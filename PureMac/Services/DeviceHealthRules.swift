import Foundation

// Turns what the readers measured into a verdict anyone can act on: one of
// three levels per item, a short status, one plain sentence and what to do.
// The thresholds are fixed and spelled out here, so the same Mac always gets
// the same answer. A drive that doesn't report its wear (most USB disks) is
// judged only on what macOS can see, and the card says so instead of
// inventing a percentage.

enum HealthLevel: Int, Comparable, Sendable {
    case good, watch, act

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct HealthItem: Identifiable, Equatable {
    enum Kind: Equatable { case drive, backup, memory, temperature }
    enum Action: Equatable { case openTimeMachine, grantFullDiskAccess }

    struct Fact: Equatable, Identifiable {
        let label: String
        let value: String
        var level: HealthLevel = .good
        var id: String { label }
    }

    let id: String
    let kind: Kind
    let symbol: String
    let title: String
    let level: HealthLevel
    /// One or two words: "Healthy", "No backup".
    let status: String
    /// The line under the status on the chip.
    let caption: String
    /// 0…1, only for a drive that reports its wear.
    var lifeLeft: Double?
    let summary: String
    var facts: [Fact] = []
    var advice: [String] = []
    var action: Action?
}

struct HealthReport: Equatable {
    let items: [HealthItem]
    let level: HealthLevel
    let headline: String
    let detail: String
}

enum DeviceHealthRules {
    /// Wear above this share of rated life asks for attention.
    static let wornShare = 80
    /// Read or write errors from here on mean the disk is at risk.
    static let riskyErrors: UInt64 = 10
    static let noisyRetries: UInt64 = 20
    static let hotDrive = 70
    static let lowFreeShare = 0.10
    static let lowFreeBytes: Int64 = 50_000_000_000
    static let staleBackup: TimeInterval = 14 * 86_400

    static func report(_ facts: DeviceHealthFacts, memory: MemorySnapshot?, thermal: ProcessInfo.ThermalState,
                       temperature: Double?, now: Date = Date()) -> HealthReport {
        var items = facts.drives.map(drive)
        items.append(backup(facts.backup, drives: facts.drives, now: now))
        if let memory { items.append(self.memory(memory)) }
        items.append(self.temperature(thermal, celsius: temperature))
        return summarize(items)
    }

    static func summarize(_ items: [HealthItem]) -> HealthReport {
        let level = items.map(\.level).max() ?? .good
        let worst = items.first { $0.level == level }
        switch level {
        case .good:
            return HealthReport(items: items, level: level, headline: String(localized: "Everything looks good"),
                                detail: String(localized: "Your disks show no errors and your files have a backup."))
        case .act:
            return HealthReport(items: items, level: level, headline: String(localized: "Something needs your attention now"),
                                detail: worst.map { "\($0.title): \($0.summary)" } ?? "")
        case .watch:
            let drivesFine = items.allSatisfy { $0.kind != .drive || $0.level == .good }
            if drivesFine, let backup = items.first(where: { $0.kind == .backup && $0.level != .good }) {
                return HealthReport(items: items, level: level, headline: String(localized: "Your disks are healthy"), detail: backup.summary)
            }
            // Every item that needs a look, in a word each, so none hides behind another.
            let flagged = items.filter { $0.level != .good }
            return HealthReport(items: items, level: level, headline: String(localized: "Nothing is broken, but keep an eye on it"),
                                detail: flagged.count == 1 ? "\(flagged[0].title): \(flagged[0].summary)"
                                    : flagged.map { "\($0.title): \($0.status)" }.joined(separator: " · "))
        }
    }

    // MARK: - Drives

    static func drive(_ drive: DriveFacts) -> HealthItem {
        var level = HealthLevel.good
        var summary: String?
        var advice: [String] = []
        func raise(_ to: HealthLevel, _ reason: String) {
            // The first reason at the highest level is the one told.
            if to > level || summary == nil { summary = reason }
            level = max(level, to)
        }

        let wear = drive.wear
        // Under a tenth free and under 50 GB: a big disk with plenty of room
        // left in bytes isn't nagged about.
        let almostFull = drive.volumes.contains { $0.total > 0 && Double($0.available) / Double($0.total) < lowFreeShare && $0.available < lowFreeBytes }

        if drive.smart == .failing || (wear?.criticalWarning ?? 0) != 0 {
            raise(.act, String(localized: "The disk reports that it's failing. Copy your files to another disk now."))
        }
        if let wear, wear.availableSpare < wear.spareThreshold || wear.percentUsed >= 100 {
            raise(.act, String(localized: "The disk is worn out and can fail at any time."))
        }
        if let wear, wear.mediaErrors > 0 {
            raise(.act, String(localized: "The disk found data it couldn't read back. Some files may already be damaged."))
        }
        if drive.errors > 0 {
            raise(drive.errors >= riskyErrors ? .act : .watch,
                  String(format: String(localized: "macOS counted %lld read or write errors on this disk since it was connected."), Int64(drive.errors)))
        } else if drive.retries >= noisyRetries {
            raise(.watch, String(localized: "macOS had to try again many times to read or write this disk."))
        }
        if let wear, wear.percentUsed >= wornShare, wear.percentUsed < 100 {
            raise(.watch, String(localized: "The disk has used most of its rated life. It still works, but plan to replace it."))
        }
        if let celsius = wear?.temperatureCelsius, celsius >= hotDrive {
            raise(.watch, String(localized: "The disk is running hot."))
        }
        if almostFull {
            raise(.watch, String(localized: "The disk is almost full. Keep at least 10% free so macOS can work and update."))
        }
        // Only space is wrong: say so, so a full disk doesn't read as a failing one.
        let onlySpace = almostFull && level == .watch
            && summary == String(localized: "The disk is almost full. Keep at least 10% free so macOS can work and update.")

        let lifeLeft = wear.map { Double(max(0, 100 - $0.percentUsed)) / 100 }
        if summary == nil {
            summary = lifeLeft.map { String(format: String(localized: "No signs of wear or errors. It still has %@ of its rated life."), percent($0)) }
                ?? String(localized: "No read or write errors since it was connected. This disk doesn't report its wear to macOS, so MacDash watches its errors instead.")
        }

        if level == .act {
            advice.append(String(localized: "Copy what matters to another disk or to the cloud today."))
        }
        if !drive.isInternal && (drive.errors > 0 || drive.retries >= noisyRetries) {
            advice.append(String(localized: "Errors on a USB disk often come from the cable or the dock. Try another cable, or plug it straight into the Mac."))
        }
        if almostFull {
            advice.append(String(localized: "Free up space with Smart Care or Space Lens."))
        }
        if !drive.isInternal {
            advice.append(String(localized: "Always eject it before unplugging it or turning off the dock."))
        }

        var facts = [HealthItem.Fact(label: String(localized: "Connection"), value: connection(drive))]
        if let lifeLeft {
            facts.append(.init(label: String(localized: "Life left"), value: percent(lifeLeft),
                               level: wear.map { $0.percentUsed >= wornShare ? .watch : .good } ?? .good))
        }
        if let celsius = wear?.temperatureCelsius {
            facts.append(.init(label: String(localized: "Temperature"), value: "\(celsius) °C", level: celsius >= hotDrive ? .watch : .good))
        }
        facts.append(.init(label: String(localized: "Read and write errors"), value: "\(drive.errors)",
                           level: drive.errors == 0 ? .good : (drive.errors >= riskyErrors ? .act : .watch)))
        if let volume = drive.volumes.min(by: { Double($0.available) / Double(max($0.total, 1)) < Double($1.available) / Double(max($1.total, 1)) }) {
            facts.append(.init(label: String(localized: "Free space"), value: bytes(volume.available), level: almostFull ? .watch : .good))
        }
        if drive.isBackupDisk {
            facts.append(.init(label: String(localized: "Used for"), value: String(localized: "Time Machine backups")))
        }

        let names = drive.volumes.map(\.name)
        let title = drive.isInternal ? String(localized: "Internal disk") : (names.isEmpty ? drive.model : names.joined(separator: " · "))
        let caption: String
        if let lifeLeft {
            caption = String(format: String(localized: "%@ life left"), percent(lifeLeft))
        } else if drive.errors == 0 {
            caption = String(localized: "No errors")
        } else {
            caption = String(format: String(localized: "%lld errors"), Int64(drive.errors))
        }

        return HealthItem(
            id: "drive:\(drive.id)", kind: .drive,
            symbol: drive.isInternal ? "internaldrive.fill" : "externaldrive.fill",
            title: title, level: level, status: onlySpace ? String(localized: "Almost full") : status(level), caption: caption, lifeLeft: lifeLeft,
            summary: summary ?? "", facts: facts, advice: advice
        )
    }

    // MARK: - Backup

    static func backup(_ backup: BackupFacts, drives: [DriveFacts], now: Date = Date()) -> HealthItem {
        func item(_ level: HealthLevel, status: String, caption: String, summary: String, advice: [String] = [], action: HealthItem.Action? = .openTimeMachine) -> HealthItem {
            var facts: [HealthItem.Fact] = []
            if let destination = backup.destinations.first {
                facts.append(.init(label: String(localized: "Time Machine"), value: destination.name))
            }
            if let last = backup.lastBackup {
                facts.append(.init(label: String(localized: "Last backup"), value: relative(last, now: now),
                                   level: now.timeIntervalSince(last) > staleBackup ? .watch : .good))
            }
            return HealthItem(id: "backup", kind: .backup, symbol: "clock.arrow.circlepath", title: String(localized: "Backup"),
                              level: level, status: status, caption: caption, summary: summary, facts: facts, advice: advice, action: action)
        }

        guard !backup.destinations.isEmpty else {
            return item(.watch, status: String(localized: "No backup"), caption: String(localized: "Time Machine is off"),
                        summary: String(localized: "Nothing is backed up. If a disk fails, the files on it are lost for good."),
                        advice: [String(localized: "Connect a second disk and turn on Time Machine. It copies your files every hour on its own.")])
        }
        guard backup.checkedDetails else {
            return item(.good, status: String(localized: "On"), caption: String(localized: "Time Machine is on"),
                        summary: String(localized: "Time Machine is set up. With Full Disk Access, MacDash also checks when the last backup ran and which disks it includes."),
                        action: .grantFullDiskAccess)
        }
        let left = drives.filter { !$0.isInternal && !$0.isBackupDisk }
            .flatMap(\.volumes).filter { $0.excludedFromBackup == true }.map(\.name)
        if !left.isEmpty {
            let names = ListFormatter.localizedString(byJoining: left)
            return item(.watch, status: String(localized: "Incomplete"), caption: String(format: String(localized: "%@ is left out"), names),
                        summary: String(format: String(localized: "Time Machine leaves out %@, so its files have no copy."), names),
                        advice: [String(localized: "In Time Machine settings, open Options and remove it from the excluded items.")])
        }
        if let last = backup.lastBackup, now.timeIntervalSince(last) > staleBackup {
            return item(.watch, status: String(localized: "Out of date"), caption: String(format: String(localized: "Last backup %@"), relative(last, now: now)),
                        summary: String(format: String(localized: "The last backup was %@."), relative(last, now: now)),
                        advice: [String(localized: "Connect the backup disk so Time Machine can catch up.")])
        }
        return item(.good, status: String(localized: "Up to date"),
                    caption: backup.lastBackup.map { String(format: String(localized: "Last backup %@"), relative($0, now: now)) } ?? String(localized: "Time Machine is on"),
                    summary: String(localized: "Time Machine copies your files and the last backup is recent."))
    }

    // MARK: - Memory and temperature

    static func memory(_ snapshot: MemorySnapshot) -> HealthItem {
        let level: HealthLevel
        let status: String
        let summary: String
        switch snapshot.pressure {
        case .normal:
            (level, status) = (.good, String(localized: "Healthy"))
            summary = String(localized: "Memory doesn't wear out. What matters is pressure, and it's normal.")
        case .warning:
            (level, status) = (.watch, String(localized: "Tight"))
            summary = String(localized: "Memory is getting tight. Quitting a heavy app helps.")
        case .critical:
            (level, status) = (.act, String(localized: "Overloaded"))
            summary = String(localized: "Memory is overloaded and your Mac is using the disk to make up for it. Quit apps you aren't using.")
        }
        return HealthItem(
            id: "memory", kind: .memory, symbol: "memorychip", title: String(localized: "Memory"),
            level: level, status: status, caption: String(format: String(localized: "%@ free"), formatMemory(snapshot.total > snapshot.used ? snapshot.total - snapshot.used : 0)),
            summary: summary,
            facts: [
                .init(label: String(localized: "Pressure"), value: snapshot.pressure.label, level: level),
                .init(label: String(localized: "Swap"), value: formatMemory(snapshot.swapUsed))
            ]
        )
    }

    static func temperature(_ thermal: ProcessInfo.ThermalState, celsius: Double?) -> HealthItem {
        let level: HealthLevel
        let status: String
        let summary: String
        switch thermal {
        case .serious:
            (level, status) = (.watch, String(localized: "Running hot"))
            summary = String(localized: "Your Mac is hot and is slowing down to cool off. Keep its vents clear.")
        case .critical:
            (level, status) = (.act, String(localized: "Critical"))
            summary = String(localized: "Your Mac is too hot. Quit heavy apps and let it cool down.")
        case .fair:
            (level, status) = (.good, String(localized: "Warm"))
            summary = String(localized: "Your Mac is cool enough to run at full speed.")
        default:
            (level, status) = (.good, String(localized: "Normal"))
            summary = String(localized: "Your Mac is cool enough to run at full speed.")
        }
        let reading = celsius.map { "\(Int($0.rounded())) °C" }
        return HealthItem(
            id: "temperature", kind: .temperature, symbol: "thermometer.medium", title: String(localized: "Temperature"),
            level: level, status: status, caption: reading ?? status, summary: summary,
            facts: reading.map { [.init(label: String(localized: "Temperature"), value: $0, level: level)] } ?? []
        )
    }

    // MARK: - Wording

    static func status(_ level: HealthLevel) -> String {
        switch level {
        case .good: return String(localized: "Healthy")
        case .watch: return String(localized: "Attention")
        case .act: return String(localized: "At risk")
        }
    }

    private static func connection(_ drive: DriveFacts) -> String {
        if drive.isInternal { return String(localized: "Internal disk") }
        switch drive.interconnect {
        case "USB": return "USB"
        case "Thunderbolt", "PCI-Express": return "Thunderbolt"
        default: return drive.interconnect.isEmpty ? "—" : drive.interconnect
        }
    }

    private static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    private static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
