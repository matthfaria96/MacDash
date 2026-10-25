import AppKit

/// MACDASH_DEMO=1: screenshots for witchmymac.com, taken from a renamed copy (see CLAUDE.md).
/// Every number, file and app shown comes from here and is fictional. Nothing is scanned,
/// cleaned, removed or updated: the actions that would touch the Mac return early, and a
/// "scan" just shows these findings. No menu bar item, updater, scheduler or Full Disk Access
/// registration either.
/// - MACDASH_DEMO_RESULTS=smartCare|cleanup opens that screen with its findings already in.
/// - MACDASH_DEMO_REVIEW=<category raw value, e.g. "User Cache"> also opens its review list.
enum DemoMode {
    static let isActive = ProcessInfo.processInfo.environment["MACDASH_DEMO"] == "1"

    static var initialResults: ScanScope? {
        switch ProcessInfo.processInfo.environment["MACDASH_DEMO_RESULTS"] {
        case "smartCare": return .smartCare
        case "cleanup": return .generalCleanup
        default: return nil
        }
    }

    static let computerName = "My Mac"

    static var initialReview: ReviewTarget? {
        guard isActive, let raw = ProcessInfo.processInfo.environment["MACDASH_DEMO_REVIEW"] else { return nil }
        return CleaningCategory(rawValue: raw).map(ReviewTarget.category)
    }

    private static let gb: Int64 = 1_000_000_000
    private static let mb: Int64 = 1_000_000

    static let diskInfo = DiskInfo(totalSpace: 494 * gb, freeSpace: 186 * gb, usedSpace: 302 * gb, purgeableSpace: 9 * gb)

    private static let home = "/Users/alex"

    private static func days(_ count: Double) -> Date { Date().addingTimeInterval(-count * 86_400) }

    /// (name, path under the fictional home, size in MB, days since modified)
    private static let findings: [CleaningCategory: [(String, String, Int64, Double)]] = [
        .systemJunk: [
            ("System logs", "/Library/Logs/DiagnosticReports", 412, 3),
            ("Temporary files", "/Library/Caches/TemporaryItems", 268, 1),
            ("Old installer packages", "/Library/Updates/Installers", 1_240, 64),
            ("Crash reports", "/Library/Logs/CrashReporter", 86, 12),
        ],
        .userCache: [
            ("PhotoStudio cache", "/Library/Caches/com.example.PhotoStudio", 1_830, 2),
            ("Browser cache", "/Library/Caches/com.example.Browser", 964, 1),
            ("Music streaming cache", "/Library/Caches/com.example.Tunes", 712, 4),
            ("Code editor cache", "/Library/Application Support/CodeEditor/Cache", 388, 6),
            ("Chat app cache", "/Library/Caches/com.example.Chat", 241, 1),
        ],
        .trashBins: [
            ("Trip photos (old copies)", "/.Trash/Trip photos", 2_150, 9),
            ("Draft video export.mov", "/.Trash/Draft video export.mov", 1_420, 15),
            ("Installer.dmg", "/.Trash/Installer.dmg", 640, 21),
        ],
        .mailAttachments: [
            ("Mail downloads", "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", 538, 30),
        ],
        .largeFiles: [
            ("Conference talk 4K.mov", "/Movies/Conference talk 4K.mov", 6_820, 410),
            ("Project archive 2023.zip", "/Documents/Archive/Project archive 2023.zip", 3_460, 520),
            ("Sample library.pkg", "/Downloads/Sample library.pkg", 2_270, 380),
            ("Old backup.sparsebundle", "/Documents/Old backup.sparsebundle", 4_950, 610),
        ],
        .aiApps: [
            ("Local model logs", "/Library/Logs/LocalModelRunner", 182, 8),
        ],
        .xcodeJunk: [
            ("DerivedData", "/Library/Developer/Xcode/DerivedData", 9_420, 5),
            ("Old archives", "/Library/Developer/Xcode/Archives/2024", 2_810, 300),
            ("Device support files", "/Library/Developer/Xcode/iOS DeviceSupport", 3_640, 200),
        ],
        .brewCache: [
            ("Homebrew downloads", "/Library/Caches/Homebrew/downloads", 1_160, 14),
        ],
        .nodeCache: [
            ("npm cache", "/.npm/_cacache", 2_040, 7),
            ("pnpm store", "/Library/pnpm/store", 1_330, 10),
        ],
        .dockerCache: [
            ("Docker build cache", "/Library/Containers/com.docker.docker/Data/cache", 3_120, 18),
        ],
    ]

    static func result(for category: CleaningCategory) -> CategoryResult? {
        guard let rows = findings[category] else { return nil }
        let items = rows.map { name, path, size, age in
            CleanableItem(name: name, path: home + path, size: size * mb, category: category,
                          isSelected: category != .largeFiles, lastModified: days(age))
        }
        return CategoryResult(category: category, items: items, totalSize: items.reduce(0) { $0 + $1.size })
    }

    static var orphans: [(url: URL, size: Int64)] {
        [
            (URL(fileURLWithPath: home + "/Library/Application Support/OldPhotoEditor"), 742 * mb),
            (URL(fileURLWithPath: home + "/Library/Preferences/com.example.OldPhotoEditor.plist"), 1 * mb),
            (URL(fileURLWithPath: home + "/Library/Caches/com.example.RetiredGame"), 318 * mb),
            (URL(fileURLWithPath: home + "/Library/Containers/com.example.NotesLite"), 96 * mb),
        ]
    }

    static var unusedApps: [UnusedAppRecord] {
        [
            UnusedAppRecord(appURL: URL(fileURLWithPath: "/Applications/Pixel Paint.app"), name: "Pixel Paint",
                            bundleIdentifier: "com.example.PixelPaint", lastUsed: days(260), files: [], totalSize: 412 * mb),
            UnusedAppRecord(appURL: URL(fileURLWithPath: "/Applications/Retro Racer.app"), name: "Retro Racer",
                            bundleIdentifier: "com.example.RetroRacer", lastUsed: days(410), files: [], totalSize: 1_870 * mb),
        ]
    }

    /// Apple's own apps (present on every Mac) with fictional sizes and dates, so no real list is shown.
    static func installedApps() -> [InstalledApp] {
        let names: [(String, String, Int64, Double)] = [
            ("Calculator", "com.apple.calculator", 9, 3), ("Calendar", "com.apple.iCal", 34, 1),
            ("Chess", "com.apple.Chess", 12, 200), ("Freeform", "com.apple.freeform", 96, 40),
            ("Maps", "com.apple.Maps", 118, 6), ("Notes", "com.apple.Notes", 58, 1),
            ("Photo Booth", "com.apple.PhotoBooth", 7, 320), ("Podcasts", "com.apple.podcasts", 44, 90),
            ("Preview", "com.apple.Preview", 31, 2), ("Reminders", "com.apple.reminders", 27, 5),
            ("Stickies", "com.apple.Stickies", 4, 150), ("TextEdit", "com.apple.TextEdit", 6, 12),
            ("Weather", "com.apple.weather", 39, 8),
        ]
        return names.compactMap { name, bundle, size, age in
            let url = URL(fileURLWithPath: "/System/Applications/\(name).app")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return InstalledApp(id: UUID(), appName: name, bundleIdentifier: bundle, path: url,
                                icon: NSWorkspace.shared.icon(forFile: url.path), size: size * mb, lastUsed: days(age))
        }
    }
}
