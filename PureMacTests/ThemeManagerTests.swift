import AppKit
import XCTest
@testable import PureMac

@MainActor
final class AppAppearanceTests: XCTestCase {
    private var originalApplicationAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        originalApplicationAppearance = NSApp.appearance
    }

    override func tearDown() {
        NSApp.appearance = originalApplicationAppearance
        super.tearDown()
    }

    func testApplicationAppearanceIsAlwaysDark() {
        AppAppearance.enforceDark()
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
    }
}
