import SwiftUI

// MARK: - Cleaning Category

enum CleaningCategory: String, CaseIterable, Identifiable, Codable {
    case smartScan = "Smart Scan"
    case systemJunk = "System Junk"
    case userCache = "User Cache"
    case aiApps = "AI Apps"
    case mailAttachments = "Mail Files"
    case trashBins = "Trash Bins"
    case largeFiles = "Large & Old Files"
    case purgeableSpace = "Purgeable Space"
    case xcodeJunk = "Xcode Junk"
    case brewCache = "Brew Cache"
    case nodeCache = "Node Cache"
    case dockerCache = "Docker Cache"
    case universalBinaries = "Universal Binaries"
    case languageFiles = "Language Files"
    case threats = "Threat Check"
    case virtualMachines = "Virtual Machines"
    case dockerData = "Docker Images & Volumes"

    var id: String { rawValue }

    var displayTitle: LocalizedStringKey {
        self == .largeFiles ? "Large Files" : LocalizedStringKey(rawValue)
    }

    var icon: String {
        switch self {
        case .smartScan: return "sparkles"
        case .systemJunk: return "gearshape.fill"
        case .userCache: return "internaldrive.fill"
        case .aiApps: return "cpu.fill"
        case .mailAttachments: return "envelope.fill"
        case .trashBins: return "trash.fill"
        case .largeFiles: return "doc.fill"
        case .purgeableSpace: return "arrow.3.trianglepath"
        case .xcodeJunk: return "hammer.fill"
        case .brewCache: return "mug.fill"
        case .nodeCache: return "leaf.fill"
        case .dockerCache: return "shippingbox.fill"
        case .universalBinaries: return "cpu"
        case .languageFiles: return "globe"
        case .threats: return "checkmark.shield.fill"
        case .virtualMachines: return "server.rack"
        case .dockerData: return "externaldrive.fill.badge.xmark"
        }
    }

    var description: String {
        switch self {
        case .smartScan: return "Scan everything at once"
        case .systemJunk: return "System caches, logs, and temporary files"
        case .userCache: return "Application caches and browser data"
        case .aiApps: return "Local AI app logs, caches, and optional history"
        case .mailAttachments: return "Downloaded mail attachments"
        case .trashBins: return "Files in your Trash"
        case .largeFiles: return "Files over 100 MB or older than 1 year"
        case .purgeableSpace: return "Reserved by macOS - freed automatically when space is needed"
        case .xcodeJunk: return "Derived data, archives, and simulator runtimes"
        case .brewCache: return "Homebrew download cache"
        case .nodeCache: return "npm, yarn, and pnpm download caches"
        case .dockerCache: return "Docker images, containers, and build cache"
        case .universalBinaries: return "Unused CPU architecture slices in app binaries"
        case .languageFiles: return "Unused app localizations"
        case .threats: return "Known adware and suspicious launch items"
        case .virtualMachines: return "Whole virtual machines from UTM, Parallels, VMware and others"
        case .dockerData: return "All unused images, volumes and build cache, or Docker's whole disk"
        }
    }

    var color: Color {
        switch self {
        case .smartScan: return .accentColor
        case .systemJunk: return .purple
        case .userCache: return .blue
        case .aiApps: return CleanupBundle.developerColor
        case .mailAttachments: return .orange
        case .trashBins: return .red
        case .largeFiles: return Color(red: 0.38, green: 0.88, blue: 0.48)
        case .purgeableSpace: return .green
        case .xcodeJunk, .brewCache, .nodeCache, .dockerCache: return CleanupBundle.developerColor
        case .universalBinaries: return .brown
        case .languageFiles: return .gray
        case .threats: return Color(red: 1.00, green: 0.42, blue: 0.36)
        case .virtualMachines: return Color(red: 1.00, green: 0.62, blue: 0.24)
        case .dockerData: return Color(red: 1.00, green: 0.48, blue: 0.30)
        }
    }

    /// The essential, low-risk areas Smart Care scans. Everything else lives in
    /// Advanced Cleanup, so the two screens never share an area.
    static var smartCare: [CleaningCategory] {
        [.systemJunk, .userCache, .trashBins, .mailAttachments, .threats].filter(scannable.contains)
    }

    /// Areas whose findings are counted rather than weighed: a flagged launch
    /// agent is a few hundred bytes, so its size says nothing.
    var reportsCount: Bool { self == .threats }

    /// Areas whose items are whole machines or data someone may still need.
    /// They start switched off and nothing in them is preselected.
    var isRisky: Bool { self == .virtualMachines || self == .dockerData }

    // Categories to scan in Smart Scan mode.
    //
    // `purgeableSpace` is deliberately excluded: APFS purgeable space is
    // reserved and reclaimed by macOS itself — no third-party app can reliably
    // enumerate or free it, and the Finder's own purgeable figure is known to
    // be inaccurate. We still SHOW it in the storage breakdown for
    // transparency, but we never present it as junk MacDash can delete.
    // Honest > impressive.
    // `appModifying` is excluded too — see the note on that property. Both of
    // those categories are withdrawn as of 2.9.5 and must not be scanned,
    // surfaced, or selectable anywhere in the UI.
    static var scannable: [CleaningCategory] {
        allCases.filter {
            $0 != .smartScan && $0 != .purgeableSpace && !appModifying.contains($0)
        }
    }

    // Categories that rewrite app bundles in place (binary thinning,
    // localization stripping) instead of deleting junk.
    //
    // WITHDRAWN in 2.9.5 (issues #135, #144). Both mutate a third-party
    // bundle and then ad-hoc re-sign it, which cannot preserve the vendor's
    // Developer ID or notarization — that is cryptographic fact, not a bug
    // that can be patched. Worse, `codesign --deep` does not descend into
    // Contents/Resources, so a Mach-O there keeps the vendor signature while
    // the outer bundle becomes ad-hoc; dyld then refuses to load the pair
    // ("different Team IDs") and the app dies before showing UI. Users lost
    // 21 bundles in a single run. `codesign --verify --deep --strict` cannot
    // detect this because it checks seal consistency, not runtime Team-ID
    // compatibility.
    //
    // The cases stay in the enum for Codable compatibility with persisted
    // scan results, but `scannable` no longer includes them, so nothing
    // reaches BinaryThinner. See also the unconditional refusal in
    // BinaryThinner.stagedModify, which makes any replayed or persisted item
    // list inert.
    static var appModifying: Set<CleaningCategory> {
        [.universalBinaries, .languageFiles]
    }
}

// MARK: - Scan State

enum ScanState: Equatable {
    case idle
    case scanning(progress: Double, currentCategory: String)
    case completed
    case cleaning(progress: Double)
    case cleaned

    var isActive: Bool {
        switch self {
        case .scanning, .cleaning: return true
        default: return false
        }
    }
}

// MARK: - Cleanup bundles

/// Groups of cleaning categories that are scanned and reviewed together on a
/// single screen.
enum CleanupBundle: String, CaseIterable, Identifiable, Hashable {
    case systemSweep
    case devAI
    case virtualization

    var id: String { rawValue }

    var categories: [CleaningCategory] {
        let all: [CleaningCategory]
        switch self {
        case .systemSweep:
            all = [.largeFiles]
        case .devAI:
            all = [.aiApps, .xcodeJunk, .brewCache, .nodeCache, .dockerCache]
        case .virtualization:
            all = [.virtualMachines, .dockerData]
        }
        return all.filter(CleaningCategory.scannable.contains)
    }

    /// Orphaned files from uninstalled apps are part of the system sweep.
    var includesOrphans: Bool { self == .systemSweep }

    /// Apps unused for months are listed in the Files column too.
    var includesUnusedApps: Bool { self == .systemSweep }

    var title: LocalizedStringKey {
        switch self {
        case .systemSweep: return "Files"
        case .devAI: return "Developer"
        case .virtualization: return "Virtual Machines"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .systemSweep: return "Large files, leftovers from removed apps and apps you no longer use."
        case .devAI: return "Xcode, Homebrew, Node, Docker and local AI app data in one pass."
        case .virtualization: return "Whole virtual machines and Docker images. Riskier: nothing is preselected and machines go to the Trash."
        }
    }

    /// One cyan shared by every developer area, so they read as a single group.
    static let developerColor = Color(red: 0.36, green: 0.86, blue: 1.00)

    /// Color of the orphaned-files area (not a cleaning category).
    static let orphanColor = Color(red: 1.00, green: 0.38, blue: 0.40)

    /// Color of the unused-apps area (not a cleaning category).
    static let unusedAppsColor = Color(red: 1.00, green: 0.40, blue: 0.82)

    /// Accent for the group's card on the General Cleanup overview.
    var cardTint: Color {
        switch self {
        case .systemSweep: return Color(red: 0.45, green: 0.95, blue: 0.45)
        case .devAI: return Color(red: 0.36, green: 0.86, blue: 1.00)
        case .virtualization: return Color(red: 1.00, green: 0.58, blue: 0.26)
        }
    }

    /// Groups whose items can't simply be regenerated.
    var isRisky: Bool { self == .virtualization }

    var tabIcon: String {
        switch self {
        case .systemSweep: return "doc.fill"
        case .devAI: return "chevron.left.forwardslash.chevron.right"
        case .virtualization: return "server.rack"
        }
    }

    var icon: String {
        switch self {
        case .systemSweep: return "wand.and.stars"
        case .devAI: return "chevron.left.forwardslash.chevron.right"
        case .virtualization: return "server.rack"
        }
    }

    static func containing(_ category: CleaningCategory) -> CleanupBundle? {
        allCases.first { $0.categories.contains(category) }
    }
}

/// Which screen owns the current scan, so each screen only shows its own run.
enum ScanScope: Equatable {
    case smartCare
    case generalCleanup
}

// MARK: - Cleanable Item

struct CleanableItem: Identifiable, Hashable {
    /// Path prefix for virtual items cleaned via `xcrun simctl runtime delete`
    /// rather than a filesystem unlink. The UUID after the colon is the
    /// runtime disk-image identifier from `simctl runtime list`.
    static let simctlRuntimePathPrefix = "simctl-runtime:"
    /// Path prefix for Docker commands offered as items, such as removing
    /// every unused image. The rest names the command (see DockerDataAction).
    static let dockerActionPathPrefix = "docker-action:"

    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let category: CleaningCategory
    var isSelected: Bool
    let lastModified: Date?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// True for action-only items (Docker prune, simctl runtimes) that have
    /// no real filesystem path to reveal in Finder.
    var isActionItem: Bool {
        path.isEmpty || path.hasPrefix(Self.simctlRuntimePathPrefix) || path.hasPrefix(Self.dockerActionPathPrefix)
    }

    var simctlRuntimeIdentifier: String? {
        guard path.hasPrefix(Self.simctlRuntimePathPrefix) else { return nil }
        let id = String(path.dropFirst(Self.simctlRuntimePathPrefix.count))
        return id.isEmpty ? nil : id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CleanableItem, rhs: CleanableItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Category Result

struct CategoryResult: Identifiable {
    let id = UUID()
    let category: CleaningCategory
    var items: [CleanableItem]
    var totalSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var itemCount: Int { items.count }
}

// MARK: - Schedule Settings

enum ScheduleInterval: String, CaseIterable, Identifiable, Codable {
    case hours1 = "Every Hour"
    case hours3 = "Every 3 Hours"
    case hours6 = "Every 6 Hours"
    case hours12 = "Every 12 Hours"
    case daily = "Daily"
    case weekly = "Weekly"
    case biweekly = "Every 2 Weeks"
    case monthly = "Monthly"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hours1: return 3600
        case .hours3: return 10800
        case .hours6: return 21600
        case .hours12: return 43200
        case .daily: return 86400
        case .weekly: return 604800
        case .biweekly: return 1209600
        case .monthly: return 2592000
        }
    }
}

struct ScheduleConfig: Codable {
    var isEnabled: Bool = false
    var interval: ScheduleInterval = .daily
    var autoClean: Bool = false
    var autoPurge: Bool = false
    var categoriesToScan: [CleaningCategory] = CleaningCategory.smartCare
    var lastRunDate: Date?
    var nextRunDate: Date?
    var notifyOnCompletion: Bool = true
    var minimumCleanSize: Int64 = 100 * 1024 * 1024 // 100 MB

    var formattedLastRun: String {
        guard let date = lastRunDate else { return String(localized: "Never") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var formattedNextRun: String {
        guard let date = nextRunDate else { return String(localized: "Not scheduled") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Disk Info

struct DiskInfo {
    var totalSpace: Int64 = 0
    var freeSpace: Int64 = 0
    var usedSpace: Int64 = 0
    var purgeableSpace: Int64 = 0

    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }

    var freePercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(freeSpace) / Double(totalSpace)
    }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalSpace, countStyle: .file)
    }

    var formattedFree: String {
        ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
    }

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: usedSpace, countStyle: .file)
    }

    var formattedPurgeable: String {
        ByteCountFormatter.string(fromByteCount: purgeableSpace, countStyle: .file)
    }
}
