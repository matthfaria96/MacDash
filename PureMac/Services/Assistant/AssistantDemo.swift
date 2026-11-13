import Foundation

/// MACDASH_DEMO=1: a fictional analysis for the site screenshots. The numbers
/// below are made up and run through the same rules as a real analysis, so
/// the wording matches the app. Nothing on the Mac is read or changed.
enum AssistantDemo {
    private static let gb: Int64 = 1_000_000_000
    private static let mb: Int64 = 1_000_000
    private static let home = "/Users/alex"

    static let report: AssistantReport = AssistantRules.report(
        from: facts(now: Date(), projectsGrowth: 0),
        baselines: [AssistantRules.Baseline(date: earlier.date, diskFree: earlier.diskFree, folderSizes: earlier.folderSizes)],
        duration: 21,
        appVersion: AppVersion.marketing
    )

    /// An analysis from nine days before, with one suggestion already handled.
    static let earlier: AssistantReport = {
        let date = Date().addingTimeInterval(-9 * 86_400)
        var report = AssistantRules.report(from: facts(now: date, projectsGrowth: -7 * gb), baselines: [], duration: 19, appVersion: AppVersion.marketing)
        if let index = report.findings.firstIndex(where: { $0.id == "devtools.caches" }) {
            let finding = report.findings[index]
            var record = AssistantActionRecord(date: date.addingTimeInterval(240), findingID: finding.id, findingTitle: finding.title, kind: .trash)
            record.requested = finding.targets.count
            record.moved = finding.targets.count
            record.bytes = finding.total
            record.movedPaths = finding.targets.map(\.path)
            report.actions = [record]
            report.findings[index].status = .done
            report.findings[index].outcome = String(format: String(localized: "Moved to the Trash: %lld (%@)."),
                                                    Int64(record.moved), AssistantRules.format(record.bytes))
            report.findings[index].targets = []
        }
        if let index = report.findings.firstIndex(where: { $0.id == "apps.unused" }) {
            report.findings[index].status = .ignored
        }
        return report
    }()

    static var history: [AssistantReport] { [report, earlier] }

    private static func item(_ path: String, _ label: String, _ megabytes: Int64, daysOld: Double = 3, now: Date) -> AssistantFacts.Measured {
        AssistantFacts.Measured(
            path: home + "/" + path, label: label, size: megabytes * mb, fileID: nil,
            modified: now.addingTimeInterval(-daysOld * 86_400), isDirectory: true
        )
    }

    private static func facts(now: Date, projectsGrowth: Int64) -> AssistantFacts {
        var facts = AssistantFacts(home: home, now: now)
        facts.diskTotal = DemoMode.diskInfo.totalSpace
        facts.diskFree = DemoMode.diskInfo.freeSpace - projectsGrowth
        facts.filesChecked = 1_284_630

        let harbor = 24 * gb + projectsGrowth
        let folders: [(String, Int64)] = [
            ("Documents", 89 * gb + harbor), ("Documents/Projects", 37 * gb + harbor), ("Documents/Projects/harbor", harbor),
            ("Documents/Projects/atlas-web", 14 * gb), ("Documents/Projects/kite-ios", 12 * gb), ("Documents/Projects/lumen", 11 * gb),
            ("Documents/Archive", 22 * gb), ("Documents/Design", 9 * gb),
            ("Downloads", 14 * gb), ("Desktop", 3 * gb), ("Movies", 31 * gb), ("Music", 6 * gb), ("Pictures", 28 * gb),
            ("Library", 44 * gb), ("Library/Caches", 7_400 * mb), ("Library/Logs", 600 * mb),
            ("Library/Caches/com.example.PhotoStudio", 1_830 * mb), ("Library/Caches/com.example.Browser", 964 * mb),
            ("Library/Caches/com.example.Tunes", 712 * mb),
            ("Library/Developer", 14 * gb), ("Library/Developer/Xcode", 10 * gb), ("Library/Developer/CoreSimulator", 4 * gb),
            ("Library/Developer/Xcode/DerivedData", 9_420 * mb),
            ("Library/Application Support", 16 * gb), ("Library/Application Support/PhotoStudio", 6 * gb),
            ("Library/Application Support/CodeEditor", 3 * gb), ("Library/Containers", 5 * gb),
            (".cargo", 2_100 * mb), (".npm", 2_040 * mb), (".claude", 1_600 * mb), (".vscode", 1_100 * mb), (".cache", 900 * mb),
            (".Trash", 4_200 * mb),
        ]
        for (path, size) in folders { facts.sizes[home + "/" + path] = size }
        facts.sizes[home] = 233 * gb + harbor

        func artifact(_ project: String, _ name: String, _ megabytes: Int64, idle: Double, command: String?) -> AssistantFacts.Artifact {
            let folder = "Documents/Projects/" + project
            return AssistantFacts.Artifact(
                item: item(folder + "/" + name, project + " › " + name, megabytes, now: now), name: name,
                project: home + "/" + folder, lastActivity: now.addingTimeInterval(-idle * 86_400), command: command
            )
        }
        facts.artifacts = [
            artifact("harbor", "target", 6_800, idle: 41, command: "cargo build"),
            artifact("kite-ios", "build", 3_400, idle: 2, command: nil),
            artifact("atlas-web", "node_modules", 1_900, idle: 74, command: "npm install"),
            artifact("lumen", "node_modules", 1_200, idle: 1, command: "npm install"),
            artifact("atlas-web", ".next", 640, idle: 74, command: nil),
        ]

        var editor = AssistantFacts.EditorFacts(key: "vscode", name: "Visual Studio Code", bundleIDs: [])
        editor.oldExtensions = [
            item(".vscode/extensions/example.linter-3.1.0", "example.linter-3.1.0", 310, now: now),
            item(".vscode/extensions/example.theme-pack-2.4.1", "example.theme-pack-2.4.1", 85, now: now),
        ]
        editor.regenerating = [
            item("Library/Application Support/Code/CachedExtensionVSIXs", "Visual Studio Code · CachedExtensionVSIXs", 443, now: now),
            item("Library/Application Support/Code/logs", "Visual Studio Code · logs", 144, now: now),
        ]
        facts.editors = [editor]

        facts.claude.sessionsTotal = 1_400 * mb
        facts.claude.oldVersions = [item(".local/share/claude/versions/2.1.300", "Claude Code 2.1.300", 296, now: now)]
        facts.claude.sessions = [
            AssistantFacts.Session(item: item(".claude/projects/-Users-alex-Documents-Projects-atlas-web/a.jsonl", "atlas-web", 212, daysOld: 21, now: now), project: "atlas-web", orphaned: false),
            AssistantFacts.Session(item: item(".claude/projects/-Users-alex-Documents-Projects-old-site/b.jsonl", "old-site", 164, daysOld: 26, now: now), project: "old-site", orphaned: true),
        ]
        facts.devCaches = [
            item(".gradle/caches", "Gradle · caches", 2_300, now: now),
            item(".cargo/registry/cache", "Cargo · registry/cache", 1_100, now: now),
            item(".bun/install/cache", "Bun · install/cache", 420, now: now),
        ]
        facts.chromiumCaches = [
            item("Library/Application Support/Chat/Cache", "Chat · Cache", 380, now: now),
            item("Library/Application Support/Tunes/Code Cache", "Tunes · Code Cache", 210, now: now),
        ]
        let models = DriveOffloadCatalog.entries.first { $0.id == "ollama.models" }?.title ?? "Ollama"
        let simulators = DriveOffloadCatalog.entries.first { $0.id == "simulators" }?.title ?? "Simulators"
        facts.offload = [
            item(".ollama/models", models, 18_000, now: now),
            item("Library/Developer/CoreSimulator/Devices", simulators, 4_000, now: now),
        ]
        let apps: [(String, Int64, Double)] = [
            ("Photo Studio", 3_200, 2), ("Retro Racer", 1_870, 410), ("Video Cutter", 2_300, 12), ("Code Editor", 940, 1),
            ("Pixel Paint", 412, 260), ("Chat", 510, 1), ("Tunes", 380, 3),
        ]
        facts.apps = apps.map { name, megabytes, daysOld in
            AssistantFacts.App(
                path: "/Applications/\(name).app", name: name, bundleID: "com.example." + name.replacingOccurrences(of: " ", with: ""),
                size: megabytes * mb, lastUsed: now.addingTimeInterval(-daysOld * 86_400), isRunning: false
            )
        }
        facts.applicationsTotal = 38 * gb
        return facts
    }
}
