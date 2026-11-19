import XCTest
@testable import MacDash

final class LegacyMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MacDashTests.LegacyMigration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testOldKeysMoveToTheirNewNames() {
        defaults.set(true, forKey: "MacTidy.OnboardingComplete")
        defaults.set(true, forKey: "MacTidy.SidebarCompact")

        LegacyMigration.renameKeys(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: "MacDash.OnboardingComplete"))
        XCTAssertTrue(defaults.bool(forKey: "MacDash.SidebarCompact"))
        XCTAssertNil(defaults.object(forKey: "MacTidy.OnboardingComplete"))
        XCTAssertNil(defaults.object(forKey: "MacTidy.SidebarCompact"))
    }

    func testANewValueIsNeverOverwritten() {
        defaults.set(false, forKey: "MacTidy.SidebarCompact")
        defaults.set(true, forKey: "MacDash.SidebarCompact")

        LegacyMigration.renameKeys(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: "MacDash.SidebarCompact"))
        XCTAssertNil(defaults.object(forKey: "MacTidy.SidebarCompact"))
    }

    func testEveryNewKeyIsAMacDashKey() {
        for (old, new) in LegacyMigration.renamedKeys {
            XCTAssertNotEqual(old, new)
            XCTAssertTrue(new.contains("MacDash"), new)
        }
    }
}
