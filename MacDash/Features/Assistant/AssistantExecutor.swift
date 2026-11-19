import Foundation

/// An app that is open, as far as the checks care.
struct AssistantRunningApp: Sendable {
    let bundleID: String
    let name: String
    let path: String
}

/// Checks a finding's items again and moves the confirmed ones to the Trash.
///
/// Nothing here trusts the report it is handed. Every item is looked up on
/// disk again, must still be the very file or folder the analysis saw, must
/// still fit the catalog rule it was listed under, and is then moved to the
/// Trash, never deleted. There is no administrator pass and no fallback to
/// removing in place: what can't go to the Trash stays where it is.
enum AssistantExecutor {
    struct Context: Sendable {
        var home: String
        var runningApps: [AssistantRunningApp]
        var ownBundlePath: String
        var exclusions: [String]
    }

    /// A fresh look at every item of `finding`.
    static func check(_ finding: AssistantFinding, context: Context) -> AssistantPlan {
        let git = AssistantScanner.gitPath()
        let targets = finding.targets
        // Each item is independent, and measuring is the slow part: several at a time.
        var items = [AssistantPlanItem?](repeating: nil, count: targets.count)
        items.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                let target = targets[index]
                let (state, size) = state(of: target, finding: finding, context: context, git: git)
                (base + index).pointee = AssistantPlanItem(
                    target: target, size: size, state: state, selected: state == .ready && target.suggested
                )
            }
        }
        return AssistantPlan(findingID: finding.id, title: finding.title, checkedAt: Date(), items: items.compactMap { $0 })
    }

    /// Whether `target` may move right now, and its size as measured now.
    static func state(
        of target: AssistantTarget,
        finding: AssistantFinding,
        context: Context,
        git: String? = AssistantScanner.gitPath()
    ) -> (AssistantItemState, Int64) {
        let path = target.path
        let home = context.home
        guard finding.action == .trash, AssistantCatalog.permits(path, rule: target.rule, home: home) else {
            return (.changed(String(localized: "Not something the Assistant may move")), 0)
        }
        guard let identity = AssistantScanner.identity(of: path) else { return (.gone, 0) }
        let replaced = String(localized: "Replaced since the analysis")
        guard !identity.isLink, identity.isDirectory == target.isDirectory else { return (.changed(replaced), 0) }
        if let fileID = target.fileID, fileID != identity.fileID { return (.changed(replaced), 0) }
        // No part of the path may be a link: the item must be where it says.
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
            return (.changed(String(localized: "Reached through a link")), 0)
        }
        if CleanupExclusions.excludes(path, paths: context.exclusions) {
            return (.blocked(String(localized: "Excluded from cleanup in Settings")), 0)
        }
        if ProviderPaths.isProviderOwned(path, homeDirectory: URL(fileURLWithPath: home, isDirectory: true)) {
            return (.blocked(String(localized: "Belongs to a cloud storage service")), 0)
        }
        if let reason = staleReason(target, identity: identity, home: home, git: git) { return (.changed(reason), 0) }
        if let reason = busyReason(target, finding: finding, context: context) { return (.blocked(reason), 0) }
        let size = identity.isDirectory ? AppFootprintScanner.measure(path) : identity.size
        return (.ready, size)
    }

    /// Why the item is no longer what its rule describes; nil when it still is.
    private static func staleReason(_ target: AssistantTarget, identity: AssistantScanner.Identity, home: String, git: String?) -> String? {
        let path = target.path
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let nowInUse = String(localized: "Now the version in use")

        switch target.rule {
        case AssistantCatalog.Rule.artifact:
            return AssistantScanner.isStillArtifact(path, home: home, git: git) ? nil
                : String(localized: "No longer looks like a build folder")
        case AssistantCatalog.Rule.editorExtension:
            return AssistantScanner.obsoleteExtensions(in: parent).contains(name) ? nil : nowInUse
        case AssistantCatalog.Rule.claudeVersion:
            let isCommandLine = parent == home + "/" + AssistantCatalog.Claude.cliVersions
            let inUse = isCommandLine
                ? (try? FileManager.default.destinationOfSymbolicLink(atPath: home + "/" + AssistantCatalog.Claude.cliLink))
                    .map { ($0 as NSString).lastPathComponent }
                : nil
            return AssistantScanner.olderVersions(in: parent, keeping: inUse).contains(name) ? nil : nowInUse
        case AssistantCatalog.Rule.claudeSession, AssistantCatalog.Rule.claudeHistory:
            // A session someone resumed is no longer the idle one that was listed.
            guard let modified = target.modified else { return nil }
            return abs(identity.modified.timeIntervalSince(modified)) < 1 ? nil : String(localized: "Used again since the analysis")
        case AssistantCatalog.Rule.editorWorkspace:
            guard let folder = AssistantScanner.workspaceFolder(in: path) else {
                return String(localized: "Replaced since the analysis")
            }
            return FileManager.default.fileExists(atPath: folder) ? String(localized: "Its folder exists again") : nil
        default:
            return nil
        }
    }

    /// Why the item can't move while things are as they are; nil when it can.
    private static func busyReason(_ target: AssistantTarget, finding: AssistantFinding, context: Context) -> String? {
        let path = target.path
        func quit(_ name: String) -> String { String(format: String(localized: "Quit %@ first"), name) }

        if let app = context.runningApps.first(where: { finding.requiresQuit.contains($0.bundleID) }) { return quit(app.name) }
        if target.rule == AssistantCatalog.Rule.chromiumCache {
            // Library/Application Support/<app>/<cache>: the folder is named after the app.
            let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
            let owner = context.runningApps.first { app in
                app.name.lowercased() == folder
                    || ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == folder
            }
            if let owner { return quit(owner.name) }
        }
        let prefix = path + "/"
        if context.ownBundlePath.hasPrefix(prefix) {
            return String(localized: "MacDash is running from this folder")
        }
        if let app = context.runningApps.first(where: { $0.path.hasPrefix(prefix) }) {
            return String(format: String(localized: "%@ is running from this folder"), app.name)
        }
        return nil
    }

    /// Moves the given items to the Trash, one by one, checking each again
    /// in the instant before it moves. `trash` is how one item moves; tests
    /// pass their own so nothing lands in the real Trash.
    static func moveToTrash(
        _ items: [AssistantPlanItem],
        finding: AssistantFinding,
        context: Context,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> AssistantActionRecord {
        var record = AssistantActionRecord(date: Date(), findingID: finding.id, findingTitle: finding.title, kind: .trash)
        record.requested = items.count
        let git = AssistantScanner.gitPath()
        for item in items {
            let path = item.target.path
            let (state, size) = state(of: item.target, finding: finding, context: context, git: git)
            guard state == .ready else {
                record.skipped.append(.init(path: path, reason: state.reason ?? ""))
                continue
            }
            do {
                try trash(URL(fileURLWithPath: path))
                record.moved += 1
                record.bytes += size
                record.movedPaths.append(path)
            } catch {
                record.skipped.append(.init(path: path, reason: error.localizedDescription))
            }
        }
        return record
    }
}
