import XCTest
@testable import PureMac

final class DriveOffloadEngineTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var drive: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("DriveOffloadTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        drive = root.appendingPathComponent("drive")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = home.appendingPathComponent(name)
        try fm.createDirectory(at: folder.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
        try Data("model weights".utf8).write(to: folder.appendingPathComponent("model.bin"))
        try Data(repeating: 7, count: 300_000).write(to: folder.appendingPathComponent("nested/big.dat"))
        try Data().write(to: folder.appendingPathComponent("nested/deeper/empty"))
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("latest").path, withDestinationPath: "model.bin")
        return folder
    }

    private func record(for source: URL, destination: String, phase: OffloadRecord.Phase = .active) -> OffloadRecord {
        OffloadRecord(
            id: UUID(), sourcePath: source.path, title: source.lastPathComponent, catalogID: nil,
            volumeUUID: "TEST", volumeName: "Drive", mountPath: drive.path,
            destinationRelativePath: destination, size: 0, fileCount: 0, phase: phase,
            createdAt: Date(), lastVerifiedAt: nil
        )
    }

    // MARK: Full round trip

    func testMoveThenRestoreKeepsEveryFile() throws {
        let source = try makeFolder("models")
        let item = record(for: source, destination: "MacDash Offload/models")
        let destination = item.destinationURL()

        try DriveOffloadEngine.copy(from: source, to: destination)
        let measure = try DriveOffloadEngine.verify(original: source, copy: destination)
        XCTAssertEqual(measure.fileCount, 3)

        try DriveOffloadEngine.swapInLink(source: source, backup: item.backupURL, destination: destination)
        XCTAssertTrue(DriveOffloadEngine.isSymbolicLink(source))
        XCTAssertEqual(DriveOffloadEngine.linkTarget(source), destination.path)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("model.bin")), "model weights")
        try DriveOffloadEngine.deleteBackup(item.backupURL)
        XCTAssertFalse(fm.fileExists(atPath: item.backupURL.path))
        XCTAssertEqual(DriveOffloadEngine.status(of: item, mountPath: drive.path), .healthy)

        // Apps write through the link onto the drive.
        try Data("new".utf8).write(to: source.appendingPathComponent("written-later.txt"))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("written-later.txt").path))

        try DriveOffloadEngine.copy(from: destination, to: item.restoreURL)
        _ = try DriveOffloadEngine.verify(original: destination, copy: item.restoreURL)
        try DriveOffloadEngine.swapOutLink(source: source, restored: item.restoreURL)
        XCTAssertFalse(DriveOffloadEngine.isSymbolicLink(source))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("written-later.txt")), "new")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: source.appendingPathComponent("latest").path), "model.bin")
    }

    // MARK: Verification

    func testVerifyCatchesAChangedFile() throws {
        let source = try makeFolder("data")
        let copy = drive.appendingPathComponent("data")
        try DriveOffloadEngine.copy(from: source, to: copy)
        try Data("model weightz".utf8).write(to: copy.appendingPathComponent("model.bin"))
        XCTAssertThrowsError(try DriveOffloadEngine.verify(original: source, copy: copy))
    }

    func testVerifyCatchesAMissingFile() throws {
        let source = try makeFolder("data")
        let copy = drive.appendingPathComponent("data")
        try DriveOffloadEngine.copy(from: source, to: copy)
        try fm.removeItem(at: copy.appendingPathComponent("nested/deeper/empty"))
        XCTAssertThrowsError(try DriveOffloadEngine.verify(original: source, copy: copy))
    }

    func testCopyRefusesToRunTwice() throws {
        let source = try makeFolder("data")
        let item = record(for: source, destination: "data")
        try DriveOffloadEngine.copy(from: source, to: item.destinationURL())
        try fm.createDirectory(at: item.backupURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try DriveOffloadEngine.swapInLink(source: source, backup: item.backupURL, destination: item.destinationURL()))
        // The original stays a real folder.
        XCTAssertFalse(DriveOffloadEngine.isSymbolicLink(source))
        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("model.bin").path))
    }

    // MARK: Status and repairs

    func testStatusWhenDriveIsAway() throws {
        let source = try makeFolder("data")
        let item = record(for: source, destination: "data")
        try DriveOffloadEngine.copy(from: source, to: item.destinationURL())
        try DriveOffloadEngine.swapInLink(source: source, backup: item.backupURL, destination: item.destinationURL())
        XCTAssertEqual(DriveOffloadEngine.status(of: item, mountPath: nil), .driveOffline)

        // An app replaced the dangling link with a fresh folder.
        try fm.removeItem(at: source)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertEqual(DriveOffloadEngine.status(of: item, mountPath: nil), .conflict)
    }

    func testRemountedUnderAnotherNameNeedsRelinkThenHeals() throws {
        let source = try makeFolder("data")
        let item = record(for: source, destination: "data")
        try DriveOffloadEngine.copy(from: source, to: item.destinationURL())
        try DriveOffloadEngine.swapInLink(source: source, backup: item.backupURL, destination: item.destinationURL())

        let renamedMount = root.appendingPathComponent("drive 1")
        try fm.moveItem(at: drive, to: renamedMount)
        XCTAssertEqual(DriveOffloadEngine.status(of: item, mountPath: renamedMount.path), .needsRelink)

        try DriveOffloadEngine.repoint(link: source, to: item.destinationURL(mountPath: renamedMount.path))
        XCTAssertEqual(DriveOffloadEngine.status(of: item, mountPath: renamedMount.path), .healthy)
    }

    func testMergeNeverOverwrites() throws {
        let destination = drive.appendingPathComponent("data")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("drive".utf8).write(to: destination.appendingPathComponent("notes.txt"))
        try Data("same".utf8).write(to: destination.appendingPathComponent("same.txt"))

        let standIn = home.appendingPathComponent("data")
        try fm.createDirectory(at: standIn.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("mac".utf8).write(to: standIn.appendingPathComponent("notes.txt"))
        try Data("same".utf8).write(to: standIn.appendingPathComponent("same.txt"))
        try Data("fresh".utf8).write(to: standIn.appendingPathComponent("sub/fresh.txt"))

        let moved = try DriveOffloadEngine.merge(standIn: standIn, into: destination)
        XCTAssertEqual(moved, 2)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("notes.txt")), "drive")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("notes (Mac).txt")), "mac")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("sub/fresh.txt")), "fresh")
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("same (Mac).txt").path))
    }

    // MARK: Safety rules

    func testProtectedAndNestedFoldersAreBlocked() throws {
        for path in ["Library", "Library/Preferences", "Library/Containers/com.example", "Desktop", ".ssh"] {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            XCTAssertEqual(OffloadSafety.blockReason(for: url, home: home, moved: []), .protected, path)
        }
        let models = try makeFolder("models")
        XCTAssertNil(OffloadSafety.blockReason(for: models, home: home, moved: []))
        XCTAssertEqual(OffloadSafety.blockReason(for: models.appendingPathComponent("nested"), home: home, moved: [models.path]), .nested)
        XCTAssertEqual(OffloadSafety.blockReason(for: models.appendingPathComponent("model.bin"), home: home, moved: []), .notFolder)
        XCTAssertEqual(OffloadSafety.blockReason(for: drive, home: home, moved: []), .outsideHome)

        let link = home.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: drive)
        XCTAssertEqual(OffloadSafety.blockReason(for: link, home: home, moved: []), .alreadyLink)
    }

    func testRecordCodableRoundTrip() throws {
        let item = record(for: home.appendingPathComponent("x"), destination: "MacDash Offload/x", phase: .swapping)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OffloadRecord.self, from: encoder.encode(item))
        XCTAssertEqual(decoded.phase, .swapping)
        XCTAssertEqual(decoded.backupURL, item.backupURL)
    }
}
