import Foundation

/// Turns measurements into a report: what uses the disk, what deserves
/// attention and what MacDash suggests. Every verdict is a fixed rule over
/// numbers the scanner measured, so the same Mac always gets the same answer
/// and each suggestion can say why it was made.
enum AssistantRules {
    /// What an earlier report knew, for telling what grew since.
    struct Baseline: Sendable {
        let date: Date
        let diskFree: Int64
        let folderSizes: [String: Int64]
    }

    enum Limits {
        static let gigabyte: Int64 = 1_000_000_000
        static let megabyte: Int64 = 1_000_000
        /// Below either of these the disk counts as getting full.
        static let lowFreeFraction = 0.10
        static let lowFreeBytes: Int64 = 20 * gigabyte
        static let criticalFreeFraction = 0.05
        static let criticalFreeBytes: Int64 = 8 * gigabyte
        /// Items listed per finding; the rest is counted, not listed.
        static let maxTargets = 120
        /// A folder must have grown by this much, and by this share, to be reported.
        static let growthBytes: Int64 = gigabyte
        static let growthFraction = 0.15
        /// Forecasts further away than this are not worth a warning.
        static let forecastDays = 60
    }

    static func format(_ bytes: Int64) -> String {
        guard bytes == 0 else { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        // "0 KB" rather than the formatter's spelled-out "Zero KB".
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: 0)
    }

    // MARK: - Report

    static func report(
        from facts: AssistantFacts,
        baselines: [Baseline],
        duration: TimeInterval,
        appVersion: String
    ) -> AssistantReport {
        var report = AssistantReport(date: facts.now)
        report.duration = duration
        report.appVersion = appVersion
        report.diskTotal = facts.diskTotal
        report.diskFree = facts.diskFree
        report.filesChecked = facts.filesChecked
        report.limitedAccess = facts.limitedAccess
        report.folderSizes = trackedFolders(facts)
        report.usage = usage(facts)
        report.findings = findings(facts, folderSizes: report.folderSizes, baselines: baselines)
        report.probes = probes(facts)
        report.headline = headline(facts, findings: report.findings)
        return report
    }

    static func isDiskLow(_ facts: AssistantFacts) -> Bool {
        guard facts.diskTotal > 0 else { return false }
        return Double(facts.diskFree) / Double(facts.diskTotal) < Limits.lowFreeFraction || facts.diskFree < Limits.lowFreeBytes
    }

    static func isDiskCritical(_ facts: AssistantFacts) -> Bool {
        guard facts.diskTotal > 0 else { return false }
        return Double(facts.diskFree) / Double(facts.diskTotal) < Limits.criticalFreeFraction || facts.diskFree < Limits.criticalFreeBytes
    }

    static func headline(_ facts: AssistantFacts, findings: [AssistantFinding]) -> String {
        let recoverable = findings.reduce(Int64(0)) { $0 + $1.reclaimable }
        if isDiskLow(facts) {
            return String(format: String(localized: "The disk is almost full: %@ free. MacDash found %@ that can be recovered."),
                          format(facts.diskFree), format(recoverable))
        }
        if findings.isEmpty {
            return String(localized: "Nothing needs attention. Your Mac is in good shape.")
        }
        if recoverable == 0 {
            return String(localized: "Nothing to clean right now. A few notes are below.")
        }
        return String(format: String(localized: "MacDash found %@ that can be recovered."), format(recoverable))
    }

    // MARK: - Findings

    static func findings(_ facts: AssistantFacts, folderSizes: [String: Int64], baselines: [Baseline]) -> [AssistantFinding] {
        let low = isDiskLow(facts)
        var list: [AssistantFinding] = []
        // The disk as a whole only matters when the whole Mac is analyzed.
        if facts.scope == nil {
            list += [diskFinding(facts), forecastFinding(facts, baselines: baselines)].compactMap { $0 }
            list += [growthFinding(facts, folderSizes: folderSizes, baselines: baselines)].compactMap { $0 }
            list += [antivirusFinding(facts)].compactMap { $0 }
        }
        list += [scopeArtifactFinding(facts), projectsFinding(facts, diskLow: low)].compactMap { $0 }
        list += facts.editors.compactMap { editorFinding($0, diskLow: low, focused: facts.scope != nil) }
        list += [
            claudeFinding(facts, diskLow: low), offloadFinding(facts, diskLow: low), devCachesFinding(facts, diskLow: low),
            appCachesFinding(facts, diskLow: low), unusedAppsFinding(facts, diskLow: low), xcodeFinding(facts, diskLow: low),
            cachesFinding(facts, diskLow: low), trashFinding(facts, diskLow: low), downloadsFinding(facts, diskLow: low),
            appDataFinding(facts),
        ].compactMap { $0 }
        return list.sorted {
            ($0.severity.rank, -max($0.reclaimable, $0.total)) < ($1.severity.rank, -max($1.reclaimable, $1.total))
        }
    }

    /// The smallest amount worth a finding. When one folder is analyzed the
    /// bar is a tenth: it is a smaller place, and the person asked about it.
    static func floor(_ bytes: Int64, _ facts: AssistantFacts) -> Int64 {
        facts.scope == nil ? bytes : bytes / 10
    }

    static func severity(_ bytes: Int64, diskLow: Bool) -> AssistantSeverity {
        if bytes >= 5 * Limits.gigabyte || (diskLow && bytes >= Limits.gigabyte) { return .attention }
        if bytes >= 300 * Limits.megabyte { return .suggestion }
        return .info
    }

    private static func target(
        _ item: AssistantFacts.Measured, note: String, suggested: Bool, rule: String, label: String? = nil
    ) -> AssistantTarget {
        AssistantTarget(
            path: item.path, label: label ?? item.label, size: item.size, fileID: item.fileID,
            isDirectory: item.isDirectory, modified: item.modified, note: note, suggested: suggested, rule: rule
        )
    }

    /// Display-only row for findings another tool handles.
    private static func row(_ label: String, path: String, size: Int64, note: String = "") -> AssistantTarget {
        AssistantTarget(path: path, label: label, size: size, fileID: nil, isDirectory: true, modified: nil, note: note, suggested: false, rule: "")
    }

    /// Fills in the sizes and trims the list to the largest items.
    private static func finish(_ finding: AssistantFinding, targets: [AssistantTarget], diskLow: Bool) -> AssistantFinding {
        var finding = finding
        let sorted = targets.sorted { $0.size > $1.size }
        finding.total = sorted.reduce(0) { $0 + $1.size }
        finding.targets = Array(sorted.prefix(Limits.maxTargets))
        finding.omittedCount = sorted.count - finding.targets.count
        switch finding.action {
        case .trash: finding.reclaimable = finding.targets.filter(\.suggested).reduce(0) { $0 + $1.size }
        case .openTool: finding.reclaimable = finding.total
        case .advice: finding.reclaimable = 0
        }
        finding.severity = severity(max(finding.reclaimable, finding.total / 2), diskLow: diskLow)
        return finding
    }

    private static func days(from date: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    // MARK: Disk

    static func diskFinding(_ facts: AssistantFacts) -> AssistantFinding? {
        guard isDiskLow(facts) else { return nil }
        let critical = isDiskCritical(facts)
        let title = critical
            ? String(format: String(localized: "Only %@ free on the startup disk"), format(facts.diskFree))
            : String(format: String(localized: "The startup disk is getting full: %@ free"), format(facts.diskFree))
        return AssistantFinding(
            id: "disk.low", area: .disk, severity: critical ? .critical : .attention, symbol: "internaldrive.fill",
            title: title,
            explanation: String(localized: "macOS needs free space for updates, memory swap and temporary files. Below about 10% the Mac slows down and apps can fail to save."),
            recommendation: String(localized: "Start with the largest suggestions below. Items go to the Trash first, so the space only comes back when the Trash is emptied."),
            action: .advice
        )
    }

    static func forecastFinding(_ facts: AssistantFacts, baselines: [Baseline]) -> AssistantFinding? {
        let candidates = baselines.filter {
            let age = facts.now.timeIntervalSince($0.date)
            return age >= 86_400 && age <= 30 * 86_400
        }
        guard let baseline = candidates.min(by: { $0.date < $1.date }) else { return nil }
        let lost = baseline.diskFree - facts.diskFree
        let elapsed = facts.now.timeIntervalSince(baseline.date) / 86_400
        guard lost >= 2 * Limits.gigabyte, elapsed > 0 else { return nil }
        let left = Int(Double(facts.diskFree) / (Double(lost) / elapsed))
        guard left < Limits.forecastDays else { return nil }
        return AssistantFinding(
            id: "disk.forecast", area: .disk, severity: left < 14 ? .critical : .attention, symbol: "chart.line.downtrend.xyaxis",
            title: String(format: String(localized: "At this pace the disk fills up in about %lld days"), Int64(max(2, left))),
            explanation: String(format: String(localized: "Free space dropped by %@ since %@."),
                                format(lost), baseline.date.formatted(date: .abbreviated, time: .omitted)),
            recommendation: String(localized: "The folders that grew are listed in this report. Cleaning build folders and caches usually reverses it."),
            action: .advice
        )
    }

    // MARK: Antivirus

    /// Threats waiting for a decision, or a scan that is overdue. Antivirus
    /// handles both; the Assistant only points there.
    static func antivirusFinding(_ facts: AssistantFacts) -> AssistantFinding? {
        guard let antivirus = facts.antivirus else { return nil }
        if antivirus.pendingThreats > 0 {
            return AssistantFinding(
                id: "security.threats", area: .security, severity: .attention, symbol: "shield.lefthalf.filled",
                title: String(localized: "Review possible threats"),
                explanation: String(format: String(localized: "%lld items are waiting for your decision. Nothing was moved."),
                                    Int64(antivirus.pendingThreats)),
                recommendation: String(localized: "Antivirus lists them so you can decide about each one."),
                action: .openTool, tool: .antivirus
            )
        }
        let overdue = facts.now.timeIntervalSince(antivirus.lastScan ?? .distantPast) > 7 * 86_400
        guard overdue, !antivirus.isScanning else { return nil }
        return AssistantFinding(
            id: "security.scan", area: .security, severity: .suggestion, symbol: "shield.lefthalf.filled",
            title: String(localized: "Run an Antivirus scan"),
            explanation: AntivirusScanMode.quick.scopeDescription,
            recommendation: String(localized: "Open Antivirus to run a quick scan."),
            action: .openTool, tool: .antivirus
        )
    }

    // MARK: Growth

    static func growthFinding(_ facts: AssistantFacts, folderSizes: [String: Int64], baselines: [Baseline]) -> AssistantFinding? {
        // The latest report old enough for a difference to mean something.
        let usable = baselines.filter { facts.now.timeIntervalSince($0.date) >= 6 * 3_600 && !$0.folderSizes.isEmpty }
        guard let baseline = usable.max(by: { $0.date < $1.date }) else { return nil }

        var grown: [(path: String, before: Int64, now: Int64)] = []
        for (path, now) in folderSizes where !path.isEmpty {
            // Folders the earlier report left out were below its listing size.
            let before = baseline.folderSizes[path] ?? 0
            let delta = now - before
            guard delta >= Limits.growthBytes, Double(delta) >= Double(before) * Limits.growthFraction else { continue }
            grown.append((path, before, now))
        }
        // A folder is dropped when one inside it explains most of its growth.
        let deepestFirst = grown.sorted { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }
        var kept: [(path: String, before: Int64, now: Int64)] = []
        for entry in deepestFirst {
            let delta = entry.now - entry.before
            let explained = kept.filter { $0.path.hasPrefix(entry.path + "/") }.reduce(Int64(0)) { $0 + ($1.now - $1.before) }
            if Double(explained) < Double(delta) * 0.7 { kept.append(entry) }
        }
        guard !kept.isEmpty else { return nil }

        let targets = kept.map { entry in
            row(displayPath(entry.path), path: absolute(entry.path, home: facts.home), size: entry.now - entry.before,
                note: String(format: String(localized: "%@ before, %@ now"), format(entry.before), format(entry.now)))
        }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        var finding = AssistantFinding(
            id: "growth.folders", area: .growth, severity: .suggestion, symbol: "arrow.up.right.circle.fill",
            title: String(format: String(localized: "Folders grew by %@ since %@"), format(total),
                          baseline.date.formatted(date: .abbreviated, time: .omitted)),
            explanation: String(localized: "Compared with the previous analysis. The sizes shown are how much each folder gained."),
            recommendation: String(localized: "Space Lens shows what is inside each one."),
            action: .openTool, tool: .spaceLens
        )
        finding = finish(finding, targets: targets, diskLow: false)
        finding.reclaimable = 0
        finding.severity = total >= 5 * Limits.gigabyte ? .attention : .suggestion
        return finding
    }

    // MARK: Projects

    /// The analyzed folder is itself build output.
    static func scopeArtifactFinding(_ facts: AssistantFacts) -> AssistantFinding? {
        guard let artifact = facts.scopeArtifact, artifact.item.size > 0 else { return nil }
        let back = artifact.command.map { String(format: String(localized: "comes back with %@"), $0) }
            ?? String(localized: "rebuilt on the next build")
        let finding = AssistantFinding(
            id: "scope.artifact", area: .projects, severity: .suggestion, symbol: "hammer.fill",
            title: String(format: String(localized: "This folder can be rebuilt: %@"), format(artifact.item.size)),
            explanation: String(localized: "Folders such as node_modules, target and build are made from your code and can be made again. They are what makes Documents grow when you work with VS Code and Claude Code."),
            recommendation: String(localized: "Building or installing again brings it back."),
            action: .trash
        )
        return finish(finding, targets: [target(artifact.item, note: back, suggested: true, rule: AssistantCatalog.Rule.artifact)], diskLow: false)
    }

    static func projectsFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        guard !facts.artifacts.isEmpty else { return nil }
        let idleAfter = diskLow ? AssistantCatalog.idleProjectDaysWhenFull : AssistantCatalog.idleProjectDays
        let targets = facts.artifacts.map { artifact -> AssistantTarget in
            let idle = artifact.lastActivity.map { days(from: $0, to: facts.now) }
            let state: String
            if let idle, idle >= idleAfter {
                state = String(format: String(localized: "Project idle for %lld days"), Int64(idle))
            } else if idle != nil {
                state = String(localized: "Project in use")
            } else {
                state = String(localized: "No recent activity found")
            }
            let back = artifact.command.map { String(format: String(localized: "comes back with %@"), $0) }
                ?? String(localized: "rebuilt on the next build")
            let isIdle = (idle ?? 0) >= idleAfter
            return target(artifact.item, note: state + " · " + back,
                          suggested: isIdle && AssistantCatalog.artifactsSuggestedWhenIdle.contains(artifact.name),
                          rule: AssistantCatalog.Rule.artifact)
        }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        guard total >= floor(200 * Limits.megabyte, facts) else { return nil }
        let finding = AssistantFinding(
            id: "projects.artifacts", area: .projects, severity: .suggestion, symbol: "hammer.fill",
            title: String(format: String(localized: "%@ of build folders and dependencies in your projects"), format(total)),
            explanation: String(localized: "Folders such as node_modules, target and build are made from your code and can be made again. They are what makes Documents grow when you work with VS Code and Claude Code."),
            recommendation: String(format: String(localized: "Folders of projects idle for %lld days or more are selected. Building or installing again brings them back."), Int64(idleAfter)),
            action: .trash
        )
        return finish(finding, targets: targets, diskLow: diskLow)
    }

    // MARK: Editors

    static func editorFinding(_ editor: AssistantFacts.EditorFacts, diskLow: Bool, focused: Bool = false) -> AssistantFinding? {
        let minimum = 5 * Limits.megabyte
        var targets: [AssistantTarget] = []
        targets += editor.oldExtensions.map {
            target($0, note: String(localized: "Older version; a newer one is installed"), suggested: true, rule: AssistantCatalog.Rule.editorExtension)
        }
        targets += editor.regenerating.map {
            target($0, note: String(localized: "Rebuilt by the app when needed"), suggested: true, rule: AssistantCatalog.Rule.editorData)
        }
        targets += editor.caches.map {
            target($0, note: String(localized: "Rebuilt by the app when needed"), suggested: true, rule: AssistantCatalog.Rule.chromiumCache)
        }
        targets += editor.orphanWorkspaces.map {
            target($0, note: String(localized: "Saved state of a folder that no longer exists"), suggested: true, rule: AssistantCatalog.Rule.editorWorkspace)
        }
        targets = targets.filter { $0.size >= minimum }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        guard total >= (focused ? 10 : 100) * Limits.megabyte else { return nil }
        var finding = AssistantFinding(
            id: "editor." + editor.key, area: .editors, severity: .suggestion, symbol: "chevron.left.forwardslash.chevron.right",
            title: String(format: String(localized: "%@ keeps %@ it no longer needs"), editor.name, format(total)),
            explanation: String(localized: "Old versions of extensions, downloaded installers, logs and caches. Each extension update leaves the previous copy behind."),
            recommendation: String(format: String(localized: "Quit %@ first: an open window may still be running an older extension."), editor.name),
            action: .trash
        )
        finding.requiresQuit = editor.bundleIDs
        return finish(finding, targets: targets, diskLow: diskLow)
    }

    // MARK: Claude

    static func claudeFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        let claude = facts.claude
        var targets: [AssistantTarget] = []
        targets += claude.oldVersions.map {
            target($0, note: String(localized: "Older version, not the one in use"), suggested: true, rule: AssistantCatalog.Rule.claudeVersion)
        }
        targets += claude.sessions.map { session in
            let date = session.item.modified ?? facts.now
            let note = session.orphaned
                ? String(localized: "Its project folder no longer exists")
                : String(format: String(localized: "Session not opened for %lld days"), Int64(days(from: date, to: facts.now)))
            return target(session.item, note: note, suggested: false, rule: AssistantCatalog.Rule.claudeSession,
                          label: session.project + " · " + date.formatted(date: .abbreviated, time: .omitted))
        }
        targets += claude.history.map { item in
            target(item, note: String(localized: "Edit checkpoints of an old session"), suggested: false, rule: AssistantCatalog.Rule.claudeHistory,
                   label: "file-history · " + (item.modified ?? facts.now).formatted(date: .abbreviated, time: .omitted))
        }
        targets = targets.filter { $0.size >= Limits.megabyte }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        guard total >= floor(100 * Limits.megabyte, facts) else { return nil }
        let finding = AssistantFinding(
            id: "claude.code", area: .claude, severity: .suggestion, symbol: "cpu.fill",
            title: String(format: String(localized: "Claude Code: %@ in old sessions and versions"), format(total)),
            explanation: String(format: String(localized: "Claude Code keeps every conversation on this Mac (%@ in total). Listed are sessions untouched for %lld days and sessions of projects that were deleted. A removed session can no longer be resumed."),
                                format(claude.sessionsTotal), Int64(AssistantCatalog.Claude.sessionIdleDays)),
            recommendation: String(localized: "Old versions are selected. Sessions are yours to choose, so none is selected for you. Project memory is never listed."),
            action: .trash
        )
        return finish(finding, targets: targets, diskLow: diskLow)
    }

    // MARK: Caches the Assistant cleans itself

    static func devCachesFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        let targets = facts.devCaches.map { item -> AssistantTarget in
            let tool = item.label.components(separatedBy: " · ").first ?? item.label
            // Folders in ~/.cache belong to tools MacDash doesn't know by name, so they wait for a tick.
            let known = !tool.hasPrefix(".")
            let note = known
                ? String(format: String(localized: "%@ downloads it again when needed"), tool)
                : String(localized: "Cache folder of a tool; filled again when needed")
            return target(item, note: note, suggested: known, rule: AssistantCatalog.Rule.devCache)
        }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        guard total >= floor(300 * Limits.megabyte, facts) else { return nil }
        let finding = AssistantFinding(
            id: "devtools.caches", area: .devTools, severity: .suggestion, symbol: "shippingbox.fill",
            title: String(format: String(localized: "Package manager caches: %@"), format(total)),
            explanation: String(localized: "Downloads kept by tools such as Cargo, Gradle and Bun. Other MacDash tools don't cover these folders."),
            recommendation: String(localized: "The next build takes longer while they download again."),
            action: .trash
        )
        return finish(finding, targets: targets, diskLow: diskLow)
    }

    static func appCachesFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        let targets = (facts.chromiumCaches + facts.claude.desktopCaches).filter { $0.size >= 10 * Limits.megabyte }.map {
            target($0, note: String(localized: "Rebuilt by the app when needed"), suggested: true, rule: AssistantCatalog.Rule.chromiumCache)
        }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        guard total >= floor(200 * Limits.megabyte, facts) else { return nil }
        let finding = AssistantFinding(
            id: "apps.chromium", area: .caches, severity: .suggestion, symbol: "internaldrive.fill",
            title: String(format: String(localized: "App caches outside the usual folder: %@"), format(total)),
            explanation: String(localized: "Apps built on Chromium, such as Claude, Discord and Teams, keep their caches in Application Support, where Smart Care doesn't look."),
            recommendation: String(localized: "Quit the apps listed before cleaning. Each one rebuilds its cache the next time it opens."),
            action: .trash
        )
        return finish(finding, targets: targets, diskLow: diskLow)
    }

    // MARK: Handled by other tools

    static func offloadFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        let items = facts.offload.filter { $0.size >= floor(Limits.gigabyte, facts) }
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total >= floor(2 * Limits.gigabyte, facts) else { return nil }
        let finding = AssistantFinding(
            id: "offload.folders", area: .devTools, severity: .suggestion, symbol: "externaldrive.connected.to.line.below.fill",
            title: String(format: String(localized: "%@ can move to an external drive"), format(total)),
            explanation: String(localized: "AI models, virtual machines, simulators and device backups are large and rarely read. Drive Offload moves them and leaves a link, so apps keep finding them."),
            recommendation: String(localized: "Connect an APFS drive and open Drive Offload."),
            action: .openTool, tool: .driveOffload
        )
        return finish(finding, targets: items.map { row($0.label, path: $0.path, size: $0.size) }, diskLow: diskLow)
    }

    static func unusedAppsFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        guard let cutoff = Calendar.current.date(byAdding: .month, value: -facts.unusedMonths, to: facts.now) else { return nil }
        let unused = facts.apps.filter { app in
            guard let last = app.lastUsed else { return false }
            return last <= cutoff && !app.isRunning && !app.bundleID.hasPrefix("com.apple.") && app.size >= 20 * Limits.megabyte
        }
        let total = unused.reduce(Int64(0)) { $0 + $1.size }
        guard !unused.isEmpty, total >= 200 * Limits.megabyte else { return nil }
        let targets = unused.map { app in
            row(app.name, path: app.path, size: app.size,
                note: String(format: String(localized: "Last opened %@"), (app.lastUsed ?? facts.now).formatted(date: .abbreviated, time: .omitted)))
        }
        let finding = AssistantFinding(
            id: "apps.unused", area: .apps, severity: .suggestion, symbol: "app.dashed",
            title: String(format: String(localized: "Apps not opened in %lld months: %@"), Int64(facts.unusedMonths), format(total)),
            explanation: String(localized: "macOS records when each app was last opened. These have stayed closed since then and still take space."),
            recommendation: String(localized: "Advanced Cleanup lists them with their leftover files and moves what you pick to the Trash."),
            action: .openTool, tool: .cleanup
        )
        return finish(finding, targets: targets, diskLow: diskLow)
    }

    static func xcodeFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        let places = ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives", "Library/Developer/Xcode/iOS DeviceSupport"]
        let targets = places.compactMap { place -> AssistantTarget? in
            let size = facts.size(place)
            return size > 0 ? row((place as NSString).lastPathComponent, path: facts.home + "/" + place, size: size) : nil
        }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        guard total >= Limits.gigabyte else { return nil }
        let finding = AssistantFinding(
            id: "devtools.xcode", area: .devTools, severity: .suggestion, symbol: "hammer.circle.fill",
            title: String(format: String(localized: "Xcode build data: %@"), format(total)),
            explanation: String(localized: "DerivedData, archives and device support files. Xcode builds or downloads them again."),
            recommendation: String(localized: "Advanced Cleanup reviews and cleans them in its Developer group."),
            action: .openTool, tool: .cleanup
        )
        return finish(finding, targets: targets, diskLow: diskLow)
    }

    static func cachesFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        let caches = facts.home + "/Library/Caches"
        let total = facts.size("Library/Caches") + facts.size("Library/Logs")
        guard total >= Limits.gigabyte else { return nil }
        let targets = children(of: caches, in: facts.sizes).prefix(8).map { row($0.name, path: $0.path, size: $0.size) }
        var finding = AssistantFinding(
            id: "caches.user", area: .caches, severity: .suggestion, symbol: "sparkles",
            title: String(format: String(localized: "%@ of caches and logs"), format(total)),
            explanation: String(localized: "Temporary files that apps rebuild on their own. The largest are listed."),
            recommendation: String(localized: "Smart Care scans them again and lets you review before anything is cleaned."),
            action: .openTool, tool: .smartCare
        )
        finding = finish(finding, targets: Array(targets), diskLow: diskLow)
        finding.total = total
        finding.reclaimable = total
        finding.severity = severity(total, diskLow: diskLow)
        return finding
    }

    static func trashFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        let total = facts.size(".Trash")
        guard total >= 500 * Limits.megabyte else { return nil }
        var finding = AssistantFinding(
            id: "caches.trash", area: .caches, severity: .suggestion, symbol: "trash.fill",
            title: String(format: String(localized: "The Trash holds %@"), format(total)),
            explanation: String(localized: "Files in the Trash keep using the disk until it is emptied."),
            recommendation: String(localized: "Empty the Trash in Finder, or let Smart Care do it."),
            action: .openTool, tool: .smartCare
        )
        finding.total = total
        finding.reclaimable = total
        finding.severity = severity(total, diskLow: diskLow)
        return finding
    }

    /// Apps holding a lot of data of their own. Only pointed out: what is
    /// still needed in there is not something a rule can tell.
    static func appDataFinding(_ facts: AssistantFacts) -> AssistantFinding? {
        let covered = Set(facts.offload.map(\.path))
        let folders = ["Library/Application Support", "Library/Containers", "Library/Group Containers"]
        let large = folders.flatMap { children(of: facts.home + "/" + $0, in: facts.sizes) }.compactMap { child -> AssistantTarget? in
            // What Drive Offload can move is already suggested there.
            let moved = covered.filter { $0.hasPrefix(child.path + "/") }.reduce(Int64(0)) { $0 + (facts.sizes[$1] ?? 0) }
            let size = child.size - moved
            return size >= 2 * Limits.gigabyte ? row(child.name, path: child.path, size: size) : nil
        }
        guard !large.isEmpty else { return nil }
        var finding = AssistantFinding(
            id: "appdata.large", area: .apps, severity: .info, symbol: "shippingbox.fill",
            title: String(format: String(localized: "Apps with more than %@ of their own data"), format(2 * Limits.gigabyte)),
            explanation: String(localized: "Libraries, downloads and projects that apps store for themselves. MacDash can't know what is still needed in there, so it suggests nothing for removal."),
            recommendation: String(localized: "Look inside with Space Lens, or free the space from within each app."),
            action: .openTool, tool: .spaceLens
        )
        finding = finish(finding, targets: large, diskLow: false)
        finding.reclaimable = 0
        finding.severity = .info
        return finding
    }

    static func downloadsFinding(_ facts: AssistantFacts, diskLow: Bool) -> AssistantFinding? {
        let total = facts.size("Downloads")
        guard total >= 5 * Limits.gigabyte else { return nil }
        var finding = AssistantFinding(
            id: "folders.downloads", area: .apps, severity: .suggestion, symbol: "arrow.down.circle.fill",
            title: String(format: String(localized: "Downloads holds %@"), format(total)),
            explanation: String(localized: "Installers and files that were often needed only once."),
            recommendation: String(localized: "Advanced Cleanup lists the large and old files there."),
            action: .openTool, tool: .cleanup
        )
        finding.total = total
        // How much of it is disposable is the person's call.
        finding.reclaimable = 0
        finding.severity = diskLow ? .suggestion : .info
        return finding
    }

    // MARK: - One folder

    static func folderReport(from facts: AssistantFacts, duration: TimeInterval, appVersion: String) -> AssistantReport {
        var report = AssistantReport(date: facts.now)
        let folder = facts.scope ?? facts.home
        report.duration = duration
        report.appVersion = appVersion
        report.diskTotal = facts.diskTotal
        report.diskFree = facts.diskFree
        report.filesChecked = facts.filesChecked
        report.scope = folder
        report.scopeSize = facts.sizes[folder] ?? 0
        report.headline = facts.scopeSummary
        report.usage = folderUsage(facts, folder: folder)
        report.findings = findings(facts, folderSizes: [:], baselines: [])
        report.probes = [
            AssistantProbe(id: AssistantStep.folders.rawValue, title: (folder as NSString).lastPathComponent,
                           detail: String(format: String(localized: "%lld files measured, %@"), Int64(facts.filesChecked), format(report.scopeSize ?? 0))),
            AssistantProbe(id: AssistantStep.projects.rawValue, title: String(localized: "Projects"),
                           detail: String(format: String(localized: "Build folders found: %lld"), Int64(facts.artifacts.count))),
        ]
        return report
    }

    /// The largest things right inside the folder, each with its own largest.
    static func folderUsage(_ facts: AssistantFacts, folder: String) -> [AssistantUsage] {
        let inside = children(of: folder, in: facts.sizes)
        let shown = inside.prefix(9)
        var slices = shown.map { child in
            AssistantUsage(id: child.path, title: child.name, symbol: "folder.fill", bytes: child.size,
                           items: children(of: child.path, in: facts.sizes).prefix(6).map {
                               AssistantUsage.Item(name: $0.name, path: $0.path, bytes: $0.size)
                           })
        }
        let rest = (facts.sizes[folder] ?? 0) - shown.reduce(Int64(0)) { $0 + $1.size }
        if rest > Limits.megabyte {
            slices.append(AssistantUsage(id: "other", title: String(localized: "Other items"), symbol: "doc.fill", bytes: rest))
        }
        return slices
    }

    // MARK: - What uses the disk

    struct Child {
        let name: String
        let path: String
        let size: Int64
    }

    /// Folders directly inside `folder` whose size the walk kept, largest first.
    static func children(of folder: String, in sizes: [String: Int64]) -> [Child] {
        let prefix = folder + "/"
        return sizes.compactMap { path, size -> Child? in
            guard path.hasPrefix(prefix) else { return nil }
            let name = String(path.dropFirst(prefix.count))
            return name.contains("/") || size <= 0 ? nil : Child(name: name, path: path, size: size)
        }
        .sorted { $0.size > $1.size }
    }

    static func usage(_ facts: AssistantFacts) -> [AssistantUsage] {
        let home = facts.home
        let sizes = facts.sizes
        let homeTotal = sizes[home] ?? 0
        var slices: [AssistantUsage] = []
        var counted: Int64 = 0

        func items(_ list: [Child], limit: Int = 6) -> [AssistantUsage.Item] {
            list.prefix(limit).map { AssistantUsage.Item(name: $0.name, path: $0.path, bytes: $0.size) }
        }
        /// Children of a folder; when one of them holds most of it, its own
        /// children are shown instead ("VSCode/KAZE").
        func drilled(_ folder: String) -> [Child] {
            let direct = children(of: folder, in: sizes)
            guard let first = direct.first, let total = sizes[folder], total > 0, Double(first.size) > Double(total) * 0.6 else { return direct }
            let inner = children(of: first.path, in: sizes).map { Child(name: first.name + "/" + $0.name, path: $0.path, size: $0.size) }
            return inner.isEmpty ? direct : (inner + direct.dropFirst()).sorted { $0.size > $1.size }
        }
        func add(_ id: String, _ title: String, _ symbol: String, _ bytes: Int64, _ list: [Child], inHome: Bool = true) {
            guard bytes > 0 else { return }
            if inHome { counted += bytes }
            slices.append(AssistantUsage(id: id, title: title, symbol: symbol, bytes: bytes, items: items(list)))
        }

        add("apps", String(localized: "Applications"), "square.grid.2x2.fill", facts.applicationsTotal,
            facts.apps.map { Child(name: $0.name, path: $0.path, size: $0.size) }, inHome: false)
        add("documents", String(localized: "Documents"), "folder.fill", facts.size("Documents"), drilled(home + "/Documents"))
        add("downloads", String(localized: "Downloads"), "arrow.down.circle.fill", facts.size("Downloads"), [])
        add("desktop", String(localized: "Desktop"), "menubar.dock.rectangle", facts.size("Desktop"), children(of: home + "/Desktop", in: sizes))
        add("movies", String(localized: "Movies"), "film.fill", facts.size("Movies"), children(of: home + "/Movies", in: sizes))
        add("music", String(localized: "Music"), "music.note", facts.size("Music"), children(of: home + "/Music", in: sizes))
        add("pictures", String(localized: "Pictures"), "photo.fill", facts.size("Pictures"), children(of: home + "/Pictures", in: sizes))

        let caches = facts.size("Library/Caches") + facts.size("Library/Logs")
        add("caches", String(localized: "Caches and logs"), "sparkles", caches, children(of: home + "/Library/Caches", in: sizes))

        let hidden = children(of: home, in: sizes).filter { $0.name.hasPrefix(".") && $0.name != ".Trash" }
        let xcode = children(of: home + "/Library/Developer", in: sizes).map { Child(name: "Developer/" + $0.name, path: $0.path, size: $0.size) }
        let developer = hidden.reduce(Int64(0)) { $0 + $1.size } + facts.size("Library/Developer")
        add("developer", String(localized: "Developer tools"), "terminal.fill", developer, (hidden + xcode).sorted { $0.size > $1.size })

        let appData = facts.size("Library") - caches - facts.size("Library/Developer")
        let support = children(of: home + "/Library/Application Support", in: sizes)
        let containers = children(of: home + "/Library/Containers", in: sizes) + children(of: home + "/Library/Group Containers", in: sizes)
        add("appdata", String(localized: "App data"), "shippingbox.fill", appData, (support + containers).sorted { $0.size > $1.size })

        add("trash", String(localized: "Trash"), "trash.fill", facts.size(".Trash"), [])

        let rest = homeTotal - counted
        if rest > 100 * Limits.megabyte {
            let known: Set<String> = ["Documents", "Downloads", "Desktop", "Movies", "Music", "Pictures", "Library", "Applications"]
            let others = children(of: home, in: sizes).filter { !$0.name.hasPrefix(".") && !known.contains($0.name) }
            slices.append(AssistantUsage(id: "other", title: String(localized: "Other folders"), symbol: "folder.fill", bytes: rest, items: items(others)))
        }
        let system = facts.diskTotal - facts.diskFree - homeTotal - facts.applicationsTotal
        if system > 100 * Limits.megabyte, !facts.limitedAccess {
            slices.append(AssistantUsage(id: "system", title: String(localized: "macOS and system data"), symbol: "gearshape.fill", bytes: system))
        }
        // What the system itself uses goes last: nothing can be done about it here.
        return slices.sorted { ($0.id == "system" ? 1 : 0, -$0.bytes) < ($1.id == "system" ? 1 : 0, -$1.bytes) }
    }

    // MARK: - Folders remembered for the next comparison

    /// The larger folders, by path relative to the home folder ("" is the
    /// home folder itself). Small ones are left out to keep reports light.
    static func trackedFolders(_ facts: AssistantFacts) -> [String: Int64] {
        let prefix = facts.home + "/"
        var result: [String: Int64] = ["": facts.sizes[facts.home] ?? 0]
        for (path, size) in facts.sizes where path.hasPrefix(prefix) {
            let relative = String(path.dropFirst(prefix.count))
            let parts = relative.split(separator: "/")
            let floor: Int64
            switch parts.count {
            case 1: floor = 200 * Limits.megabyte
            case 2: floor = 300 * Limits.megabyte
            case 3: floor = 500 * Limits.megabyte
            default: continue
            }
            if size >= floor { result[relative] = size }
        }
        return result
    }

    static func displayPath(_ relative: String) -> String { "~/" + relative }
    static func absolute(_ relative: String, home: String) -> String { relative.isEmpty ? home : home + "/" + relative }

    // MARK: - What was analyzed

    static func probes(_ facts: AssistantFacts) -> [AssistantProbe] {
        return [
            AssistantProbe(id: AssistantStep.disk.rawValue, title: String(localized: "Startup disk"),
                           detail: String(format: String(localized: "%@ in total, %@ free"), format(facts.diskTotal), format(facts.diskFree))),
            AssistantProbe(id: AssistantStep.folders.rawValue, title: String(localized: "Home folder"),
                           detail: String(format: String(localized: "%lld files measured, %@"), Int64(facts.filesChecked), format(facts.sizes[facts.home] ?? 0)),
                           complete: !facts.limitedAccess),
            AssistantProbe(id: AssistantStep.projects.rawValue, title: String(localized: "Projects"),
                           detail: String(format: String(localized: "Build folders found: %lld"), Int64(facts.artifacts.count)),
                           complete: !facts.limitedAccess),
            AssistantProbe(id: AssistantStep.tools.rawValue, title: String(localized: "VS Code, Claude and developer tools"),
                           detail: String(format: String(localized: "Editors: %lld · Claude Code sessions: %@ · Package caches: %lld"),
                                          Int64(facts.editors.count), format(facts.claude.sessionsTotal), Int64(facts.devCaches.count))),
            AssistantProbe(id: AssistantStep.apps.rawValue, title: String(localized: "Applications"),
                           detail: String(format: String(localized: "Apps: %lld (%@)"), Int64(facts.apps.count), format(facts.applicationsTotal))),
        ]
    }
}
