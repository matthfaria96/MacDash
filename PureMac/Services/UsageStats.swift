import Foundation

/// A small, local record of what MacDash has done on this Mac, shown by the
/// Assistant: days since first use, space cleaned, tasks run, how many files
/// the last run checked and when that was. Nothing leaves the Mac.
@MainActor
final class UsageStats: ObservableObject {
    static let shared = UsageStats()

    enum Activity: String {
        case smartCareScan
        case advancedScan
        case cleanup
        case uninstall
        case duplicates
        case similarPhotos
        case spaceLens

        var title: String {
            switch self {
            case .smartCareScan: return String(localized: "Smart Care scan")
            case .advancedScan: return String(localized: "Advanced Cleanup scan")
            case .cleanup: return String(localized: "Cleanup")
            case .uninstall: return String(localized: "App removal")
            case .duplicates: return String(localized: "Duplicate Files")
            case .similarPhotos: return String(localized: "Similar Photos")
            case .spaceLens: return String(localized: "Space Lens")
            }
        }

        var icon: String {
            switch self {
            case .smartCareScan: return "desktopcomputer"
            case .advancedScan: return "wand.and.stars"
            case .cleanup: return "sparkles"
            case .uninstall: return "trash"
            case .duplicates: return "doc.on.doc"
            case .similarPhotos: return "photo.stack"
            case .spaceLens: return "chart.pie"
            }
        }
    }

    @Published private(set) var firstUse: Date
    @Published private(set) var bytesCleaned: Int64
    @Published private(set) var tasksRun: Int
    @Published private(set) var lastFilesChecked: Int
    @Published private(set) var lastActivity: Date?
    @Published private(set) var lastActivityKind: Activity?

    private let defaults: UserDefaults
    private enum Key {
        static let firstUse = "stats.firstUse"
        static let bytesCleaned = "stats.bytesCleaned"
        static let tasksRun = "stats.tasksRun"
        static let lastFilesChecked = "stats.lastFilesChecked"
        static let lastActivity = "stats.lastActivity"
        static let lastActivityKind = "stats.lastActivityKind"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let start = defaults.object(forKey: Key.firstUse) as? Date ?? Date()
        defaults.set(start, forKey: Key.firstUse)
        firstUse = start
        bytesCleaned = (defaults.object(forKey: Key.bytesCleaned) as? NSNumber)?.int64Value ?? 0
        tasksRun = defaults.integer(forKey: Key.tasksRun)
        lastFilesChecked = defaults.integer(forKey: Key.lastFilesChecked)
        lastActivity = defaults.object(forKey: Key.lastActivity) as? Date
        lastActivityKind = defaults.string(forKey: Key.lastActivityKind).flatMap(Activity.init(rawValue:))
    }

    /// Calendar days since the first launch, counting today.
    var daysWithMacTidy: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstUse), to: calendar.startOfDay(for: Date())).day ?? 0
        return max(1, days + 1)
    }

    /// A finished scan: one task, and its file count becomes "checked last time".
    func recordScan(_ activity: Activity, filesChecked: Int) {
        tasksRun += 1
        lastFilesChecked = max(0, filesChecked)
        markActivity(activity)
        save()
    }

    /// A finished cleanup. `countsAsTask` is false when the same cleanup is
    /// also recorded elsewhere, so it isn't counted twice.
    func recordCleanup(_ activity: Activity, bytes: Int64, countsAsTask: Bool = true) {
        guard bytes > 0 || countsAsTask else { return }
        bytesCleaned += max(0, bytes)
        if countsAsTask { tasksRun += 1 }
        markActivity(activity)
        save()
    }

    private func markActivity(_ activity: Activity) {
        lastActivity = Date()
        lastActivityKind = activity
    }

    private func save() {
        defaults.set(NSNumber(value: bytesCleaned), forKey: Key.bytesCleaned)
        defaults.set(tasksRun, forKey: Key.tasksRun)
        defaults.set(lastFilesChecked, forKey: Key.lastFilesChecked)
        defaults.set(lastActivity, forKey: Key.lastActivity)
        defaults.set(lastActivityKind?.rawValue, forKey: Key.lastActivityKind)
    }
}
