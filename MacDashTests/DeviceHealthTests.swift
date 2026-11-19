import XCTest
@testable import MacDash

final class DeviceHealthTests: XCTestCase {
    private static let gb: Int64 = 1_000_000_000
    private var gb: Int64 { Self.gb }

    private func internalDrive(wear: NVMeWear? = NVMeWear(temperatureCelsius: 45, availableSpare: 100, spareThreshold: 99, percentUsed: 1)) -> DriveFacts {
        DriveFacts(id: "disk0", model: "APPLE SSD", isInternal: true, interconnect: "Apple Fabric", capacity: 256 * gb,
                   wear: wear, smart: .verified,
                   volumes: [DriveVolume(name: "Macintosh HD", path: "/", total: 245 * gb, available: 120 * gb)])
    }

    private func usbDrive(errors: UInt64 = 0, available: Int64 = 900 * DeviceHealthTests.gb, excluded: Bool? = nil) -> DriveFacts {
        DriveFacts(id: "disk4", model: "SSD 2TB", isInternal: false, interconnect: "USB", capacity: 2000 * gb,
                   readErrors: errors,
                   volumes: [DriveVolume(name: "Midias", path: "/Volumes/Midias", total: 2000 * gb, available: available, excludedFromBackup: excluded)])
    }

    private let timeMachine = [BackupFacts.Destination(name: "Backup", mountPoint: "/Volumes/Backup")]

    // MARK: - Wear log

    func testParsesTheNVMeWearLog() throws {
        var log = [UInt8](repeating: 0, count: 512)
        log[1] = 0x46; log[2] = 0x01          // 326 K
        log[3] = 100; log[4] = 99; log[5] = 7
        log[48] = 0x10; log[49] = 0x27         // 10 000 data units
        log[128] = 0x08; log[129] = 0x02       // 520 hours
        log[160] = 2
        let wear = try XCTUnwrap(NVMeWear(log: log))
        XCTAssertEqual(wear.temperatureCelsius, 53)
        XCTAssertEqual(wear.availableSpare, 100)
        XCTAssertEqual(wear.spareThreshold, 99)
        XCTAssertEqual(wear.percentUsed, 7)
        XCTAssertEqual(wear.bytesWritten, 10_000 * 512_000)
        XCTAssertEqual(wear.powerOnHours, 520)
        XCTAssertEqual(wear.mediaErrors, 2)
        XCTAssertNil(NVMeWear(log: [0, 1, 2]))
    }

    // MARK: - Drives

    func testHealthyInternalDriveShowsItsLifeLeft() {
        let item = DeviceHealthRules.drive(internalDrive())
        XCTAssertEqual(item.level, .good)
        XCTAssertEqual(item.lifeLeft, 0.99)
        XCTAssertEqual(item.title, String(localized: "Internal disk"))
        XCTAssertEqual(item.caption, String(format: String(localized: "%@ life left"), "99%"))
    }

    func testDriveWarningsPutItAtRisk() {
        XCTAssertEqual(DeviceHealthRules.drive(internalDrive(wear: NVMeWear(criticalWarning: 1))).level, .act)
        XCTAssertEqual(DeviceHealthRules.drive(internalDrive(wear: NVMeWear(availableSpare: 5, spareThreshold: 10))).level, .act)
        XCTAssertEqual(DeviceHealthRules.drive(internalDrive(wear: NVMeWear(mediaErrors: 1))).level, .act)
        var failing = internalDrive(wear: nil)
        failing.smart = .failing
        XCTAssertEqual(DeviceHealthRules.drive(failing).level, .act)
    }

    func testWornDriveAsksForAttention() {
        let item = DeviceHealthRules.drive(internalDrive(wear: NVMeWear(percentUsed: 85)))
        XCTAssertEqual(item.level, .watch)
        XCTAssertEqual(item.lifeLeft, 0.15)
    }

    func testUSBDriveWithoutWearIsJudgedOnItsErrors() {
        let clean = DeviceHealthRules.drive(usbDrive())
        XCTAssertEqual(clean.level, .good)
        XCTAssertNil(clean.lifeLeft)
        XCTAssertEqual(clean.title, "Midias")
        XCTAssertEqual(clean.caption, String(localized: "No errors"))

        let few = DeviceHealthRules.drive(usbDrive(errors: 3))
        XCTAssertEqual(few.level, .watch)
        XCTAssertTrue(few.advice.contains(String(localized: "Errors on a USB disk often come from the cable or the dock. Try another cable, or plug it straight into the Mac.")))

        XCTAssertEqual(DeviceHealthRules.drive(usbDrive(errors: 12)).level, .act)
    }

    func testAlmostFullDriveSaysSoInsteadOfLookingBroken() {
        let full = DeviceHealthRules.drive(usbDrive(available: 30 * gb))
        XCTAssertEqual(full.level, .watch)
        XCTAssertEqual(full.status, String(localized: "Almost full"))
        // 5% of a big disk is still 100 GB: not worth a warning.
        XCTAssertEqual(DeviceHealthRules.drive(usbDrive(available: 100 * gb)).level, .good)
        // Full and with errors: the errors are what the status says.
        XCTAssertEqual(DeviceHealthRules.drive(usbDrive(errors: 2, available: 30 * gb)).status, String(localized: "Attention"))
    }

    // MARK: - Backup

    func testNoBackupIsTheOneThingToFix() {
        let facts = DeviceHealthFacts(drives: [internalDrive(), usbDrive()], backup: BackupFacts())
        let report = DeviceHealthRules.report(facts, memory: nil, thermal: .nominal, temperature: nil)
        XCTAssertEqual(report.level, .watch)
        XCTAssertEqual(report.headline, String(localized: "Your disks are healthy"))
        let backup = report.items.first { $0.kind == .backup }
        XCTAssertEqual(backup?.status, String(localized: "No backup"))
        XCTAssertEqual(backup?.action, .openTimeMachine)
    }

    func testExcludedExternalDriveMakesTheBackupIncomplete() {
        let backup = BackupFacts(destinations: timeMachine, lastBackup: Date(), checkedDetails: true)
        let item = DeviceHealthRules.backup(backup, drives: [internalDrive(), usbDrive(excluded: true)])
        XCTAssertEqual(item.level, .watch)
        XCTAssertEqual(item.status, String(localized: "Incomplete"))
    }

    func testBackupAge() {
        let now = Date()
        let recent = BackupFacts(destinations: timeMachine, lastBackup: now.addingTimeInterval(-3_600), checkedDetails: true)
        XCTAssertEqual(DeviceHealthRules.backup(recent, drives: [usbDrive(excluded: false)], now: now).level, .good)
        let stale = BackupFacts(destinations: timeMachine, lastBackup: now.addingTimeInterval(-20 * 86_400), checkedDetails: true)
        XCTAssertEqual(DeviceHealthRules.backup(stale, drives: [], now: now).status, String(localized: "Out of date"))
    }

    func testUncheckedBackupOffersFullDiskAccess() {
        let item = DeviceHealthRules.backup(BackupFacts(destinations: timeMachine), drives: [usbDrive()])
        XCTAssertEqual(item.level, .good)
        XCTAssertEqual(item.action, .grantFullDiskAccess)
    }

    func testEverythingGood() {
        let backup = BackupFacts(destinations: timeMachine, lastBackup: Date(), checkedDetails: true)
        let report = DeviceHealthRules.report(DeviceHealthFacts(drives: [internalDrive(), usbDrive(excluded: false)], backup: backup),
                                              memory: nil, thermal: .nominal, temperature: 48)
        XCTAssertEqual(report.level, .good)
        XCTAssertEqual(report.headline, String(localized: "Everything looks good"))
    }

    func testADriveAtRiskLeadsTheReport() {
        let report = DeviceHealthRules.report(DeviceHealthFacts(drives: [internalDrive(), usbDrive(errors: 40)], backup: BackupFacts()),
                                              memory: nil, thermal: .nominal, temperature: nil)
        XCTAssertEqual(report.level, .act)
        XCTAssertEqual(report.headline, String(localized: "Something needs your attention now"))
        XCTAssertTrue(report.detail.hasPrefix("Midias"))
    }

    func testSeveralWarningsAreAllNamed() {
        var full = internalDrive()
        full.volumes = [DriveVolume(name: "Macintosh HD", path: "/", total: 245 * gb, available: 20 * gb)]
        let report = DeviceHealthRules.report(DeviceHealthFacts(drives: [full, usbDrive()], backup: BackupFacts()),
                                              memory: nil, thermal: .nominal, temperature: nil)
        XCTAssertEqual(report.level, .watch)
        XCTAssertEqual(report.detail, "\(String(localized: "Internal disk")): \(String(localized: "Almost full")) · \(String(localized: "Backup")): \(String(localized: "No backup"))")
    }

    func testThermalStateSetsTheTemperatureLevel() {
        XCTAssertEqual(DeviceHealthRules.temperature(.nominal, celsius: 50).level, .good)
        XCTAssertEqual(DeviceHealthRules.temperature(.serious, celsius: 95).level, .watch)
        XCTAssertEqual(DeviceHealthRules.temperature(.critical, celsius: nil).level, .act)
    }

    // MARK: - tmutil output

    func testParsesTimeMachineOutput() throws {
        let destinations = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Destinations</key><array>
        <dict><key>Name</key><string>Backup</string><key>Kind</key><string>Local</string><key>MountPoint</key><string>/Volumes/Backup</string></dict>
        <dict><key>Name</key><string>NAS</string><key>Kind</key><string>Network</string></dict>
        </array></dict></plist>
        """
        XCTAssertEqual(TimeMachineReader.parseDestinations(Data(destinations.utf8)), [
            BackupFacts.Destination(name: "Backup", mountPoint: "/Volumes/Backup"),
            BackupFacts.Destination(name: "NAS", mountPoint: nil)
        ])
        XCTAssertEqual(TimeMachineReader.parseDestinations(Data("<plist version=\"1.0\"><dict/></plist>".utf8)), [])

        let exclusions = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array>
        <dict><key>Path</key><string>/Volumes/Midias</string><key>IsExcluded</key><integer>1</integer></dict>
        <dict><key>Path</key><string>/Volumes/Work</string><key>IsExcluded</key><integer>0</integer></dict>
        </array></plist>
        """
        XCTAssertEqual(TimeMachineReader.parseExclusions(Data(exclusions.utf8)), ["/Volumes/Midias": true, "/Volumes/Work": false])

        let date = try XCTUnwrap(TimeMachineReader.parseBackupDate("/Volumes/.timemachine/ABC/2026-11-14-103000.backup/2026-11-14-103000.backup\n"))
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 11, 14, 10, 30])
        XCTAssertNil(TimeMachineReader.parseBackupDate("No machine directory found"))
    }
}
