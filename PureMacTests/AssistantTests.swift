import XCTest
@testable import PureMac

final class AssistantTests: XCTestCase {
    private var root: URL!
    private var home: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // The checks compare paths with their link-free form, and the system's
        // temporary folder sits behind a link (/var -> /private/var).
        let base = fm.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("AssistantTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home").path
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func write(_ relative: String, bytes: Int = 64) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    @discardableResult
    private func folder(_ relative: String) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func walk(skip: Set<String> = []) -> AssistantTreeWalk {
        let walk = AssistantTreeWalk(
            root: home, skip: skip, tracked: AssistantScanner.trackedPaths(home: home),
            expand: AssistantScanner.expandedPaths(home: home), cancel: AssistantCancelFlag()
        ) { _ in }
        walk.run()
        return walk
    }

    private func context(running: [AssistantRunningApp] = [], own: String = "/nowhere/MacDash.app") -> AssistantExecutor.Context {
        AssistantExecutor.Context(home: home, runningApps: running, ownBundlePath: own, exclusions: [])
    }

    private func target(_ path: String, rule: String, suggested: Bool = true) -> AssistantTarget {
        let identity = AssistantScanner.identity(of: path)
        return AssistantTarget(
            path: path, label: (path as NSString).lastPathComponent, size: 0, fileID: identity?.fileID,
            isDirectory: identity?.isDirectory ?? true, modified: identity?.modified, note: "", suggested: suggested, rule: rule
        )
    }

    private func finding(_ targets: [AssistantTarget], requiresQuit: [String] = []) -> AssistantFinding {
        var finding = AssistantFinding(
            id: "test", area: .projects, severity: .suggestion, symbol: "hammer.fill", title: "Test",
            explanation: "", recommendation: "", action: .trash
        )
        finding.targets = targets
        finding.requiresQuit = requiresQuit
        return finding
    }

    private func git(_ arguments: [String], in directory: String) throws {
        guard let git = AssistantScanner.gitPath() else { throw XCTSkip("git is not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", directory, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    // MARK: What may go to the Trash

    func testPermitsOnlyTheShapeEachRuleDescribes() {
        let rule = AssistantCatalog.Rule.self
        func permits(_ relative: String, _ name: String) -> Bool {
            AssistantCatalog.permits(home + "/" + relative, rule: name, home: home)
        }
        XCTAssertTrue(permits("Documents/VSCode/app/node_modules", rule.artifact))
        XCTAssertTrue(permits("Developer/tool/target", rule.artifact))
        XCTAssertTrue(permits(".vscode/extensions/pub.ext-1.0.0", rule.editorExtension))
        XCTAssertTrue(permits("Library/Application Support/Code/CachedExtensionVSIXs", rule.editorData))
        XCTAssertTrue(permits("Library/Application Support/Code/User/workspaceStorage/abc123", rule.editorWorkspace))
        XCTAssertTrue(permits(".claude/projects/-Users-me-app/\(UUID().uuidString).jsonl", rule.claudeSession))
        XCTAssertTrue(permits(".local/share/claude/versions/2.1.300", rule.claudeVersion))
        XCTAssertTrue(permits("Library/Application Support/Discord/Cache", rule.chromiumCache))
        XCTAssertTrue(permits(".bun/install/cache", rule.devCache))
        XCTAssertTrue(permits(".cache/sometool", rule.devCache))

        // A source folder is not a build folder, whatever the report says.
        XCTAssertFalse(permits("Documents/VSCode/app/src", rule.artifact))
        XCTAssertFalse(permits("Documents", rule.artifact))
        XCTAssertFalse(permits("node_modules", rule.artifact))
        XCTAssertFalse(permits("Library/Caches/node_modules", rule.artifact))
        XCTAssertFalse(permits(".config/app/node_modules", rule.artifact))
        // Project memory is never a session.
        XCTAssertFalse(permits(".claude/projects/-Users-me-app/memory", rule.claudeSession))
        XCTAssertFalse(permits(".claude/settings.json", rule.claudeSession))
        XCTAssertFalse(permits(".vscode/extensions/extensions.json", rule.editorExtension))
        XCTAssertFalse(permits("Library/Application Support/Code/User", rule.editorData))
        XCTAssertFalse(permits("Library/Application Support/Discord/Local Storage", rule.chromiumCache))
        XCTAssertFalse(permits(".cache/huggingface", rule.devCache))
        XCTAssertFalse(permits(".ssh", rule.devCache))
        // Rules can't be swapped, and unknown rules allow nothing.
        XCTAssertFalse(permits(".bun/install/cache", rule.artifact))
        XCTAssertFalse(permits("Documents/VSCode/app/node_modules", ""))
        XCTAssertFalse(permits("Documents/VSCode/app/node_modules", "anything"))
    }

    func testPermitsRefusesPathsOutsideHomeAndUnnormalizedPaths() {
        let rule = AssistantCatalog.Rule.artifact
        XCTAssertFalse(AssistantCatalog.permits("/Applications/App.app/node_modules", rule: rule, home: home))
        XCTAssertFalse(AssistantCatalog.permits(home + "/Documents/app/../../../etc/node_modules", rule: rule, home: home))
        XCTAssertFalse(AssistantCatalog.permits(home + "/Documents/app//node_modules", rule: rule, home: home))
        XCTAssertFalse(AssistantCatalog.permits(home + "x/Documents/app/node_modules", rule: rule, home: home))
        XCTAssertFalse(AssistantCatalog.permits(home, rule: rule, home: home))
    }

    // MARK: Versions

    func testExtensionIdentityAndVersionOrder() {
        let identity = AssistantCatalog.extensionIdentity("anthropic.claude-code-2.1.323-darwin-arm64")
        XCTAssertEqual(identity?.id, "anthropic.claude-code")
        XCTAssertEqual(identity?.version ?? [], [2, 1, 323])
        XCTAssertNil(AssistantCatalog.extensionIdentity("extensions.json"))
        XCTAssertTrue(AssistantCatalog.isOlder([2, 1, 99], than: [2, 1, 323]))
        XCTAssertTrue(AssistantCatalog.isOlder([2, 9], than: [2, 10, 0]))
        XCTAssertFalse(AssistantCatalog.isOlder([2, 1, 0], than: [2, 1]))
        XCTAssertEqual(AssistantCatalog.claudeProjectFolder(for: "/Users/me/Documents/my app.v2"), "-Users-me-Documents-my-app-v2")
    }

    func testObsoleteExtensionsKeepNewestAndWhatTheEditorLists() throws {
        let extensions = try folder(".vscode/extensions")
        for name in ["pub.tool-1.0.0", "pub.tool-1.2.0", "pub.tool-1.10.0", "other.theme-3.0.0", "pinned.ext-1.0.0", "pinned.ext-2.0.0"] {
            try folder(".vscode/extensions/" + name)
        }
        // The editor still lists the older "pinned" version: it stays.
        let listed = [["relativeLocation": "pub.tool-1.10.0"], ["relativeLocation": "pinned.ext-1.0.0"]]
        try JSONSerialization.data(withJSONObject: listed).write(to: URL(fileURLWithPath: extensions + "/extensions.json"))

        XCTAssertEqual(Set(AssistantScanner.obsoleteExtensions(in: extensions)), ["pub.tool-1.0.0", "pub.tool-1.2.0"])
    }

    func testOlderVersionsKeepNewestAndTheOneInUse() throws {
        let versions = try folder(".local/share/claude/versions")
        for name in ["2.1.9", "2.1.300", "2.1.316"] { try write(".local/share/claude/versions/" + name) }
        XCTAssertEqual(Set(AssistantScanner.olderVersions(in: versions, keeping: "2.1.300")), ["2.1.9"])
        XCTAssertEqual(Set(AssistantScanner.olderVersions(in: versions, keeping: nil)), ["2.1.9", "2.1.300"])
        XCTAssertTrue(AssistantScanner.olderVersions(in: home + "/missing", keeping: nil).isEmpty)
    }

    func testSessionAndWorkspaceFoldersAreReadFromTheirFiles() throws {
        let session = try write(".claude/projects/-x/a.jsonl")
        try Data(#"{"type":"user","cwd":"/Users/me/Documents/my \"app\"","sessionId":"1"}"#.utf8 + [0x0A]).write(to: URL(fileURLWithPath: session))
        XCTAssertEqual(AssistantScanner.sessionFolder(in: session), #"/Users/me/Documents/my "app""#)

        let storage = try folder("Library/Application Support/Code/User/workspaceStorage/abc")
        try Data(#"{"folder":"file:///Users/me/Documents/site%20one"}"#.utf8).write(to: URL(fileURLWithPath: storage + "/workspace.json"))
        XCTAssertEqual(AssistantScanner.workspaceFolder(in: storage), "/Users/me/Documents/site one")
        try Data(#"{"folder":"vscode-remote://ssh-remote+host/home/me/site"}"#.utf8).write(to: URL(fileURLWithPath: storage + "/workspace.json"))
        XCTAssertNil(AssistantScanner.workspaceFolder(in: storage))
    }

    // MARK: The walk

    func testWalkMeasuresFoldersAndFindsBuildFolders() throws {
        try write("Documents/app/package.json")
        try write("Documents/app/node_modules/lib/index.js", bytes: 200_000)
        try write("Documents/app/src/main.js", bytes: 10_000)
        // No package.json next to it: just a folder that happens to share the name.
        try write("Documents/notes/node_modules/readme.txt", bytes: 50_000)
        try write("Documents/rust/Cargo.toml")
        try write("Documents/rust/target/debug/bin", bytes: 300_000)
        try write("Documents/site/build/out.js", bytes: 100_000)
        try write("Documents/py/.venv/pyvenv.cfg")
        // Hidden folders and the Library are never searched for projects.
        try write(".config/tool/package.json")
        try write(".config/tool/node_modules/x.js", bytes: 50_000)
        try write("Library/Caches/thing/data", bytes: 400_000)

        let walk = walk()
        let found = Dictionary(uniqueKeysWithValues: walk.candidates.map { (String($0.path.dropFirst(home.count + 1)), $0) })
        XCTAssertEqual(Set(found.keys), ["Documents/app/node_modules", "Documents/rust/target", "Documents/site/build", "Documents/py/.venv"])
        XCTAssertEqual(found["Documents/app/node_modules"]?.needsGit, false)
        XCTAssertEqual(found["Documents/app/node_modules"]?.command, "npm install")
        XCTAssertEqual(found["Documents/site/build"]?.needsGit, true)
        XCTAssertGreaterThanOrEqual(found["Documents/rust/target"]?.size ?? 0, 300_000)

        XCTAssertGreaterThanOrEqual(walk.sizes[home + "/Library/Caches"] ?? 0, 400_000)
        XCTAssertGreaterThanOrEqual(walk.sizes[home + "/Documents/app"] ?? 0, 210_000)
        XCTAssertEqual(walk.sizes[home], walk.sizes.filter { ($0.key as NSString).deletingLastPathComponent == home }.values.reduce(0, +))
        XCTAssertEqual(walk.files, 11)
    }

    func testWalkLeavesSkippedFoldersUnread() throws {
        try write("Documents/app/package.json")
        try write("Documents/app/node_modules/index.js", bytes: 100_000)
        try write("Pictures/Photos Library.photoslibrary/database", bytes: 100_000)
        let walk = walk(skip: [home + "/Documents", home + "/Pictures"])
        XCTAssertTrue(walk.candidates.isEmpty)
        XCTAssertNil(walk.sizes[home + "/Documents"])
        XCTAssertNil(walk.sizes[home + "/Pictures"])
        XCTAssertEqual(walk.files, 0)
    }

    func testGuardedPathsCoverEverythingMacOSAsksAbout() throws {
        for name in ["Application Support/AddressBook", "Application Support/Code", "Caches", "Containers", "Calendars", "Photos", "Mail"] {
            try folder("Library/" + name)
        }
        let guarded = AssistantScanner.guardedPaths(home: home)
        for relative in ["Documents", "Desktop", "Downloads", "Pictures", "Library/Containers", "Library/Calendars", "Library/Photos",
                         "Library/Mail", "Library/Application Support/AddressBook"] {
            XCTAssertTrue(guarded.contains(home + "/" + relative), relative)
        }
        XCTAssertFalse(guarded.contains(home + "/Library/Caches"))
        XCTAssertFalse(guarded.contains(home + "/Library/Application Support"))
        XCTAssertFalse(guarded.contains(home + "/Library/Application Support/Code"))
    }

    // MARK: Projects and git

    func testGitDecidesAmbiguousBuildFolders() throws {
        let project = try folder("Documents/site")
        try write("Documents/site/package.json")
        try write("Documents/site/build/out.js", bytes: 30_000_000)
        try write("Documents/site/dist/logo.png", bytes: 30_000_000)
        try write("Documents/site/coverage/report.html", bytes: 30_000_000)
        try write("Documents/site/.gitignore")
        try Data("build/\ncoverage/\n".utf8).write(to: URL(fileURLWithPath: project + "/.gitignore"))
        try git(["init", "-q"], in: project)
        try git(["add", "package.json", ".gitignore", "dist"], in: project)
        try git(["commit", "-q", "-m", "first"], in: project)
        // Outside any repository nothing vouches for a folder called "build".
        try write("Documents/loose/build/out.bin", bytes: 30_000_000)
        try write("Documents/loose/package.json")
        try write("Documents/loose/node_modules/a.js", bytes: 30_000_000)

        let found = AssistantScanner.artifacts(from: walk().candidates, home: home, now: Date(), cancel: AssistantCancelFlag())
        let paths = Set(found.map { String($0.item.path.dropFirst(home.count + 1)) })
        // "dist" is tracked by the repository, so it is source, not output.
        XCTAssertEqual(paths, ["Documents/site/build", "Documents/site/coverage", "Documents/loose/node_modules"])
        XCTAssertEqual(found.first { $0.name == "build" }?.item.label, "site › build")
        XCTAssertNotNil(found.first { $0.name == "build" }?.lastActivity)

        XCTAssertTrue(AssistantScanner.isStillArtifact(project + "/build", home: home))
        XCTAssertFalse(AssistantScanner.isStillArtifact(project + "/dist", home: home))
        XCTAssertFalse(AssistantScanner.isStillArtifact(home + "/Documents/loose/build", home: home))
        // Once the project starts tracking it, it stops being disposable.
        try git(["add", "-f", "build/out.js"], in: project)
        XCTAssertFalse(AssistantScanner.isStillArtifact(project + "/build", home: home))
    }

    func testProjectNamesBorrowFromAboveWhenGeneric() {
        let base = home + "/Documents/VSCode"
        XCTAssertEqual(AssistantScanner.projectRoot(for: base + "/Skykeep/source", repository: nil, home: home), base + "/Skykeep")
        XCTAssertEqual(AssistantScanner.projectRoot(for: base + "/ninho", repository: nil, home: home), base + "/ninho")
        XCTAssertEqual(AssistantScanner.projectRoot(for: base + "/a/src", repository: base + "/a/src", home: home), base + "/a/src")
        XCTAssertEqual(AssistantScanner.displayName(of: base + "/Skykeep/source", home: home), "Skykeep/source")
        XCTAssertEqual(AssistantScanner.displayName(of: base + "/MacDash", home: home), "MacDash")
        // Never climbs to a top-level folder.
        XCTAssertEqual(AssistantScanner.projectRoot(for: home + "/Documents/src", repository: nil, home: home), home + "/Documents/src")
    }

    // MARK: Checking again

    func testCheckAcceptsUnchangedItemsAndDropsWhatChanged() throws {
        try write("Documents/app/package.json")
        let modules = try folder("Documents/app/node_modules")
        try write("Documents/app/node_modules/a.js", bytes: 40_000)
        let gone = try folder("Documents/old/node_modules")
        try write("Documents/old/package.json")
        let swapped = try folder("Documents/swap/node_modules")
        try write("Documents/swap/package.json")
        let orphan = try folder("Documents/plain/node_modules")

        let targets = [modules, gone, swapped, orphan].map { target($0, rule: AssistantCatalog.Rule.artifact) }
        try fm.removeItem(atPath: gone)
        // Same path, different folder: not the one the analysis saw.
        try fm.removeItem(atPath: swapped)
        try fm.createDirectory(atPath: swapped + "-new", withIntermediateDirectories: true)
        try fm.moveItem(atPath: swapped + "-new", toPath: swapped)

        let plan = AssistantExecutor.check(finding(targets), context: context())
        let states = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.state) })
        XCTAssertEqual(states[modules], .ready)
        XCTAssertEqual(states[gone], .gone)
        guard case .changed = states[swapped] else { return XCTFail("a replaced folder must not be accepted") }
        // No package.json beside it any more: no longer build output.
        guard case .changed = states[orphan] else { return XCTFail("a folder that lost its marker must not be accepted") }
        XCTAssertEqual(plan.selected.map(\.id), [modules])
        XCTAssertGreaterThanOrEqual(plan.selectedBytes, 40_000)
    }

    func testCheckRefusesLinksAndPathsTheRuleDoesNotCover() throws {
        let precious = try folder("Documents/thesis")
        try write("Documents/thesis/chapter.txt")
        try write("Documents/app/package.json")
        // A link named like a build folder, pointing at something that matters.
        try fm.createSymbolicLink(atPath: home + "/Documents/app/node_modules", withDestinationPath: precious)
        let link = AssistantTarget(path: home + "/Documents/app/node_modules", label: "", size: 0, fileID: nil, isDirectory: true,
                                   modified: nil, note: "", suggested: true, rule: AssistantCatalog.Rule.artifact)
        // A real folder reached through a link in its path.
        try write("Documents/real/package.json")
        try folder("Documents/real/node_modules")
        try fm.createSymbolicLink(atPath: home + "/Documents/alias", withDestinationPath: home + "/Documents/real")
        let throughLink = AssistantTarget(path: home + "/Documents/alias/node_modules", label: "", size: 0, fileID: nil, isDirectory: true,
                                          modified: nil, note: "", suggested: true, rule: AssistantCatalog.Rule.artifact)
        // A path no rule covers, smuggled into a report.
        let smuggled = AssistantTarget(path: precious, label: "", size: 0, fileID: nil, isDirectory: true,
                                       modified: nil, note: "", suggested: true, rule: AssistantCatalog.Rule.artifact)

        let plan = AssistantExecutor.check(finding([link, throughLink, smuggled]), context: context())
        XCTAssertTrue(plan.ready.isEmpty)
        XCTAssertEqual(plan.unavailable.count, 3)

        // A finding that isn't a Trash action never yields movable items either.
        var advice = finding([target(home + "/Documents/real/node_modules", rule: AssistantCatalog.Rule.artifact)])
        XCTAssertEqual(AssistantExecutor.check(advice, context: context()).ready.count, 1)
        advice = AssistantFinding(id: "x", area: .disk, severity: .info, symbol: "", title: "", explanation: "", recommendation: "",
                                  action: .openTool, targets: advice.targets)
        XCTAssertTrue(AssistantExecutor.check(advice, context: context()).ready.isEmpty)
    }

    func testCheckBlocksWhileAnAppIsUsingTheFolder() throws {
        let old = try folder(".vscode/extensions/pub.tool-1.0.0")
        try folder(".vscode/extensions/pub.tool-2.0.0")
        let extensionFinding = finding([target(old, rule: AssistantCatalog.Rule.editorExtension)], requiresQuit: ["com.microsoft.VSCode"])
        let code = AssistantRunningApp(bundleID: "com.microsoft.VSCode", name: "Code", path: "/Applications/Visual Studio Code.app")
        guard case .blocked = AssistantExecutor.check(extensionFinding, context: context(running: [code])).items[0].state else {
            return XCTFail("an editor's folders must wait until it quits")
        }
        XCTAssertEqual(AssistantExecutor.check(extensionFinding, context: context()).items[0].state, .ready)

        let cache = try folder("Library/Application Support/Discord/Cache")
        let cacheFinding = finding([target(cache, rule: AssistantCatalog.Rule.chromiumCache)])
        let discord = AssistantRunningApp(bundleID: "com.hnc.Discord", name: "Discord", path: "/Applications/Discord.app")
        guard case .blocked = AssistantExecutor.check(cacheFinding, context: context(running: [discord])).items[0].state else {
            return XCTFail("an app's cache must wait until it quits")
        }

        // MacDash itself running from inside a build folder.
        try write("Documents/MacDash/package.json")
        let build = try folder("Documents/MacDash/node_modules")
        let own = build + "/Debug/MacDash.app"
        let buildFinding = finding([target(build, rule: AssistantCatalog.Rule.artifact)])
        guard case .blocked = AssistantExecutor.check(buildFinding, context: context(own: own)).items[0].state else {
            return XCTFail("the folder MacDash runs from must not move")
        }
    }

    func testIdleSessionThatWasResumedIsLeftAlone() throws {
        let session = try write(".claude/projects/-Users-me-app/\(UUID().uuidString).jsonl")
        let listed = target(session, rule: AssistantCatalog.Rule.claudeSession, suggested: false)
        XCTAssertEqual(AssistantExecutor.check(finding([listed]), context: context()).items[0].state, .ready)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: session)
        guard case .changed = AssistantExecutor.check(finding([listed]), context: context()).items[0].state else {
            return XCTFail("a session used again must not be accepted")
        }
    }

    func testPlanGoesStaleAfterAFewMinutes() {
        let plan = AssistantPlan(findingID: "x", title: "", checkedAt: Date(), items: [])
        XCTAssertTrue(plan.isFresh())
        XCTAssertFalse(plan.isFresh(now: Date().addingTimeInterval(AssistantPlan.lifetime + 1)))
    }

    // MARK: Rules

    private func makeFacts(free: Int64 = 200_000_000_000) -> AssistantFacts {
        var facts = AssistantFacts(home: "/Users/test", now: Date(timeIntervalSince1970: 1_800_000_000))
        facts.diskTotal = 500_000_000_000
        facts.diskFree = free
        return facts
    }

    private func artifact(_ name: String, project: String, megabytes: Int64, idleDays: Double?, now: Date) -> AssistantFacts.Artifact {
        AssistantFacts.Artifact(
            item: AssistantFacts.Measured(path: "/Users/test/Documents/\(project)/\(name)", label: "\(project) › \(name)",
                                          size: megabytes * 1_000_000, fileID: 1, modified: now, isDirectory: true),
            name: name, project: "/Users/test/Documents/" + project,
            lastActivity: idleDays.map { now.addingTimeInterval(-$0 * 86_400) }, command: nil
        )
    }

    func testDiskWarningsFollowFreeSpace() {
        XCTAssertNil(AssistantRules.diskFinding(makeFacts()))
        XCTAssertEqual(AssistantRules.diskFinding(makeFacts(free: 30_000_000_000))?.severity, .attention)
        XCTAssertEqual(AssistantRules.diskFinding(makeFacts(free: 4_000_000_000))?.severity, .critical)
        XCTAssertEqual(AssistantRules.diskFinding(makeFacts(free: 4_000_000_000))?.action, .advice)
    }

    func testOnlyIdleProjectsAreTickedAndAFullDiskLowersTheBar() throws {
        var facts = makeFacts()
        facts.artifacts = [
            artifact("node_modules", project: "old", megabytes: 900, idleDays: 60, now: facts.now),
            artifact("target", project: "recent", megabytes: 800, idleDays: 10, now: facts.now),
            artifact("build", project: "today", megabytes: 700, idleDays: 0, now: facts.now),
            artifact("dist", project: "old", megabytes: 600, idleDays: 60, now: facts.now),
            artifact("node_modules", project: "unknown", megabytes: 500, idleDays: nil, now: facts.now),
        ]
        func ticked(_ finding: AssistantFinding?) -> Set<String> {
            Set((finding?.targets ?? []).filter(\.suggested).map(\.label))
        }
        let normal = try XCTUnwrap(AssistantRules.projectsFinding(facts, diskLow: false))
        XCTAssertEqual(ticked(normal), ["old › node_modules"])
        XCTAssertEqual(normal.reclaimable, 900_000_000)
        XCTAssertEqual(normal.total, 3_500_000_000)
        XCTAssertEqual(normal.action, .trash)
        XCTAssertTrue(normal.targets.allSatisfy { $0.rule == AssistantCatalog.Rule.artifact })
        // "dist" may hold something exported by hand and a project with no
        // known activity proves nothing: neither is ever ticked.
        XCTAssertEqual(ticked(AssistantRules.projectsFinding(facts, diskLow: true)), ["old › node_modules", "recent › target"])
    }

    func testGrowthIsReportedOnceAtTheDeepestFolder() throws {
        var facts = makeFacts()
        let before: [String: Int64] = ["": 60_000_000_000, "Documents": 20_000_000_000, "Documents/VSCode": 14_000_000_000,
                                       "Documents/VSCode/KAZE": 6_000_000_000, "Movies": 20_000_000_000]
        let now: [String: Int64] = ["": 67_400_000_000, "Documents": 24_000_000_000, "Documents/VSCode": 18_000_000_000,
                                    "Documents/VSCode/KAZE": 10_000_000_000, "Movies": 20_400_000_000, "Downloads": 3_000_000_000]
        let baseline = AssistantRules.Baseline(date: facts.now.addingTimeInterval(-5 * 86_400), diskFree: 0, folderSizes: before)
        let finding = try XCTUnwrap(AssistantRules.growthFinding(facts, folderSizes: now, baselines: [baseline]))
        // KAZE explains what Documents and VSCode gained; Downloads is new.
        XCTAssertEqual(Set(finding.targets.map(\.label)), ["~/Documents/VSCode/KAZE", "~/Downloads"])
        XCTAssertEqual(finding.total, 7_000_000_000)
        XCTAssertEqual(finding.reclaimable, 0)
        XCTAssertEqual(finding.action, .openTool)

        // A report from minutes ago is no base for comparison.
        facts.now = baseline.date.addingTimeInterval(600)
        XCTAssertNil(AssistantRules.growthFinding(facts, folderSizes: now, baselines: [baseline]))
    }

    func testForecastWarnsWhenTheDiskIsFillingFast() {
        let facts = makeFacts(free: 20_000_000_000)
        let fast = AssistantRules.Baseline(date: facts.now.addingTimeInterval(-10 * 86_400), diskFree: 40_000_000_000, folderSizes: [:])
        let slow = AssistantRules.Baseline(date: facts.now.addingTimeInterval(-10 * 86_400), diskFree: 21_000_000_000, folderSizes: [:])
        // 20 GB lost in 10 days with 20 GB left: about 10 days.
        XCTAssertEqual(AssistantRules.forecastFinding(facts, baselines: [fast])?.severity, .critical)
        XCTAssertNil(AssistantRules.forecastFinding(facts, baselines: [slow]))
        XCTAssertNil(AssistantRules.forecastFinding(facts, baselines: []))
    }

    func testReportRanksFindingsAndKeepsOnlyLargeFolders() {
        var facts = makeFacts(free: 4_000_000_000)
        facts.sizes = [
            "/Users/test": 90_000_000_000, "/Users/test/Documents": 50_000_000_000, "/Users/test/Documents/small": 100_000_000,
            "/Users/test/Library": 30_000_000_000, "/Users/test/Library/Caches": 6_000_000_000, "/Users/test/.Trash": 2_000_000_000,
        ]
        facts.artifacts = [artifact("node_modules", project: "old", megabytes: 3_000, idleDays: 90, now: facts.now)]
        let report = AssistantRules.report(from: facts, baselines: [], duration: 3, appVersion: "test")

        XCTAssertEqual(report.findings.first?.id, "disk.low")
        XCTAssertEqual(report.findings.first?.severity, .critical)
        let ids = report.findings.map(\.id)
        XCTAssertTrue(ids.contains("projects.artifacts"))
        XCTAssertTrue(ids.contains("caches.user"))
        XCTAssertTrue(ids.contains("caches.trash"))
        XCTAssertEqual(report.findings.map(\.severity.rank), report.findings.map(\.severity.rank).sorted())
        XCTAssertEqual(report.reclaimable, 3_000_000_000 + 6_000_000_000 + 2_000_000_000)
        XCTAssertNotNil(report.folderSizes["Documents"])
        XCTAssertNil(report.folderSizes["Documents/small"])
        XCTAssertEqual(report.usage.first?.id, "documents")
        XCTAssertFalse(report.headline.isEmpty)
    }

    func testAntivirusRemindersFollowItsState() {
        var facts = makeFacts()
        XCTAssertNil(AssistantRules.antivirusFinding(facts))
        facts.antivirus = AntivirusState(pendingThreats: 2, lastScan: facts.now, isScanning: false)
        XCTAssertEqual(AssistantRules.antivirusFinding(facts)?.id, "security.threats")
        XCTAssertEqual(AssistantRules.antivirusFinding(facts)?.tool, .antivirus)
        facts.antivirus = AntivirusState(pendingThreats: 0, lastScan: facts.now.addingTimeInterval(-86_400), isScanning: false)
        XCTAssertNil(AssistantRules.antivirusFinding(facts))
        facts.antivirus = AntivirusState(pendingThreats: 0, lastScan: nil, isScanning: false)
        XCTAssertEqual(AssistantRules.antivirusFinding(facts)?.id, "security.scan")
        facts.antivirus = AntivirusState(pendingThreats: 0, lastScan: nil, isScanning: true)
        XCTAssertNil(AssistantRules.antivirusFinding(facts))
        // A folder's report says nothing about Antivirus.
        facts.antivirus = AntivirusState(pendingThreats: 3, lastScan: nil, isScanning: false)
        facts.scope = "/Users/test/Documents"
        XCTAssertFalse(AssistantRules.findings(facts, folderSizes: [:], baselines: []).contains { $0.area == .security })
    }

    // MARK: One folder

    private func folderOptions() -> AssistantScanner.Options {
        AssistantScanner.Options(home: home, applicationRoots: [], fullDiskAccess: true, runningAppPaths: [], unusedMonths: 6)
    }

    func testFolderAnalysisFindsBuildFoldersRightInsideIt() throws {
        let project = try folder("Documents/site")
        try write("Documents/site/package.json")
        try write("Documents/site/node_modules/lib/index.js", bytes: 30_000_000)
        try write("Documents/site/src/app.js", bytes: 2_000)

        let facts = try XCTUnwrap(AssistantScanner.gatherFolder(project, options: folderOptions(), cancel: AssistantCancelFlag()) { _, _ in })
        XCTAssertEqual(facts.scope, project)
        XCTAssertEqual(facts.artifacts.map(\.name), ["node_modules"])
        XCTAssertNil(facts.scopeArtifact)

        let report = AssistantRules.folderReport(from: facts, duration: 1, appVersion: "test")
        XCTAssertEqual(report.scope, project)
        XCTAssertGreaterThanOrEqual(report.scopeSize ?? 0, 30_000_000)
        XCTAssertEqual(report.usage.first?.title, "node_modules")
        XCTAssertTrue(report.findings.contains { $0.id == "projects.artifacts" })
        // The disk as a whole is not part of a folder's report.
        XCTAssertFalse(report.findings.contains { $0.id.hasPrefix("disk.") })
        XCTAssertTrue(report.folderSizes.isEmpty)
    }

    func testFolderThatIsItselfBuildOutputCanGoToTheTrash() throws {
        try write("Documents/site/package.json")
        try write("Documents/site/node_modules/a/package.json")
        try write("Documents/site/node_modules/a/node_modules/b.js", bytes: 5_000_000)
        let modules = home + "/Documents/site/node_modules"

        let facts = try XCTUnwrap(AssistantScanner.gatherFolder(modules, options: folderOptions(), cancel: AssistantCancelFlag()) { _, _ in })
        XCTAssertNotNil(facts.scopeArtifact)
        // What sits inside a build folder is part of it, not a separate find.
        XCTAssertTrue(facts.artifacts.isEmpty)
        let report = AssistantRules.folderReport(from: facts, duration: 1, appVersion: "test")
        let finding = try XCTUnwrap(report.findings.first { $0.id == "scope.artifact" })
        XCTAssertEqual(finding.targets.map(\.path), [modules])
        XCTAssertEqual(AssistantExecutor.check(finding, context: context()).ready.count, 1)
    }

    func testFolderSummaryNamesWhatTheFolderIs() throws {
        var facts = AssistantFacts(home: home)
        XCTAssertEqual(AssistantScanner.summary(of: home + "/Library/Caches/com.example", facts: facts),
                       String(localized: "Temporary files that apps rebuild on their own."))
        XCTAssertEqual(AssistantScanner.summary(of: home + "/Library/Mail", facts: facts),
                       String(localized: "macOS or an app relies on this folder. Leave it as it is."))
        let repo = try folder("Documents/tool")
        try git(["init", "-q"], in: repo)
        XCTAssertTrue(AssistantScanner.summary(of: repo, facts: facts).contains("git"))
        facts.now = Date()
        XCTAssertEqual(AssistantScanner.summary(of: try folder("Documents/notes"), facts: facts),
                       String(localized: "A regular folder. Its largest items are below."))
    }

    func testFinderLinksOnlyReachFoldersInHomeOrOnOtherDisks() throws {
        let inside = try folder("Documents/site")
        let file = try write("Documents/readme.txt")
        XCTAssertEqual(AssistantStore.acceptedFolder(inside, home: home), inside)
        XCTAssertEqual(AssistantStore.acceptedFolder(inside + "/../site", home: home), inside)
        XCTAssertNil(AssistantStore.acceptedFolder(file, home: home))
        XCTAssertNil(AssistantStore.acceptedFolder(home + "/missing", home: home))
        XCTAssertNil(AssistantStore.acceptedFolder("/System/Library", home: home))
        XCTAssertNil(AssistantStore.acceptedFolder("Documents/site", home: home))
        XCTAssertNil(AssistantStore.acceptedFolder(home + "/../../etc", home: home))
    }

    // MARK: Reports on disk

    func testReportsRoundTripAndListNewestFirst() throws {
        let folder = root.appendingPathComponent("reports")
        var older = AssistantReport(date: Date(timeIntervalSince1970: 1_700_000_000))
        older.headline = "older"
        older.folderSizes = ["Documents": 5]
        var newer = AssistantReport(date: Date(timeIntervalSince1970: 1_700_100_000))
        newer.headline = "newer"
        var kept = finding([AssistantTarget(path: "/a", label: "a", size: 1, fileID: 9, isDirectory: true, modified: nil, note: "n", suggested: true, rule: "artifact")])
        kept.status = .ignored
        newer.findings = [kept]
        newer.actions = [AssistantActionRecord(date: newer.date, findingID: "test", findingTitle: "Test", kind: .ignore)]
        AssistantStore.write(older, in: folder)
        AssistantStore.write(newer, in: folder)
        try Data("not a report".utf8).write(to: folder.appendingPathComponent("broken.json"))

        let read = AssistantStore.readReports(in: folder)
        XCTAssertEqual(read.map(\.headline), ["newer", "older"])
        XCTAssertEqual(read.first?.findings.first?.status, .ignored)
        XCTAssertEqual(read.first?.findings.first?.targets.first?.fileID, 9)
        XCTAssertEqual(read.first?.actions.first?.kind, .ignore)
        XCTAssertEqual(read.last?.folderSizes, ["Documents": 5])
        XCTAssertNotEqual(AssistantStore.file(for: older, in: folder), AssistantStore.file(for: newer, in: folder))
    }

    func testMovingToTheTrashChecksEachItemAgain() throws {
        try write("Documents/app/package.json")
        let modules = try folder("Documents/app/node_modules")
        let listed = finding([target(modules, rule: AssistantCatalog.Rule.artifact)])
        let plan = AssistantExecutor.check(listed, context: context())
        XCTAssertEqual(plan.ready.count, 1)
        // Between the confirmation and the move the folder is swapped for another.
        try fm.removeItem(atPath: modules)
        try fm.createDirectory(atPath: modules, withIntermediateDirectories: true)
        try write("Documents/app/node_modules/now-precious.txt")

        let record = AssistantExecutor.moveToTrash(plan.ready, finding: listed, context: context()) { _ in
            XCTFail("a folder that changed after the confirmation must not move")
        }
        XCTAssertEqual(record.moved, 0)
        XCTAssertEqual(record.skipped.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: modules + "/now-precious.txt"))
    }

    func testMovingToTheTrashRecordsWhatMovedAndWhatDidNot() throws {
        try write("Documents/app/package.json")
        let modules = try folder("Documents/app/node_modules")
        try write("Documents/app/node_modules/a.js", bytes: 60_000)
        try write("Documents/web/package.json")
        let stuck = try folder("Documents/web/node_modules")
        let listed = finding([target(modules, rule: AssistantCatalog.Rule.artifact), target(stuck, rule: AssistantCatalog.Rule.artifact)])
        let plan = AssistantExecutor.check(listed, context: context())
        XCTAssertEqual(plan.ready.count, 2)

        // A stand-in for the Trash; one item refuses to move.
        let bin = root.appendingPathComponent("trash")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = AssistantExecutor.moveToTrash(plan.ready, finding: listed, context: context()) { url in
            if url.path == stuck { throw CocoaError(.fileWriteNoPermission) }
            try self.fm.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString))
        }
        XCTAssertEqual(record.requested, 2)
        XCTAssertEqual(record.moved, 1)
        XCTAssertEqual(record.movedPaths, [modules])
        XCTAssertGreaterThanOrEqual(record.bytes, 60_000)
        XCTAssertEqual(record.skipped.map(\.path), [stuck])
        XCTAssertFalse(fm.fileExists(atPath: modules))
        // What couldn't go to the Trash is left exactly where it was, never removed in place.
        XCTAssertTrue(fm.fileExists(atPath: stuck))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: bin.path).count, 1)
    }
}
