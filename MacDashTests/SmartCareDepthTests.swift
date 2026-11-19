import XCTest
@testable import MacDash

/// Smart Care's two depths: what each one scans, how results split into
/// "Safe to clean" and "To review", and what a scheduled run may clean.
@MainActor
final class SmartCareDepthTests: XCTestCase {
    func testEssentialScansOnlyTheSafeAreas() {
        XCTAssertEqual(ScanDepth.essential.categories(enabledAreas: [.largeFiles, .xcodeJunk]), CleaningCategory.smartCare)
    }

    func testCompleteAddsTheChosenAreasAfterTheEssentialOnes() {
        let categories = ScanDepth.complete.categories(enabledAreas: [.largeFiles, .xcodeJunk, .userCache])
        XCTAssertEqual(Array(categories.prefix(CleaningCategory.smartCare.count)), CleaningCategory.smartCare)
        XCTAssertEqual(Array(categories.dropFirst(CleaningCategory.smartCare.count)), [.largeFiles, .xcodeJunk])
        XCTAssertEqual(Set(categories).count, categories.count, "no area is scanned twice")
    }

    func testVirtualMachinesNeedTheirOwnSwitch() {
        let everyday = AppState.generalCleanupCategories.filter { !$0.isRisky }
        let categories = ScanDepth.complete.categories(enabledAreas: everyday)
        XCTAssertFalse(categories.contains(.virtualMachines))
        XCTAssertFalse(categories.contains(.dockerData))
    }

    func testEssentialAreasComeFirstInTheReview() {
        XCTAssertTrue(ReviewTarget.category(.userCache).isEssential)
        XCTAssertFalse(ReviewTarget.category(.largeFiles).isEssential)
        XCTAssertFalse(ReviewTarget.orphans.isEssential)

        let state = AppState(performStartupTasks: false)
        state.categoryResults[.largeFiles] = result(.largeFiles, size: 9_000)
        state.categoryResults[.userCache] = result(.userCache, size: 100)
        let targets = state.reviewTargets(categories: [.userCache, .largeFiles], includesOrphans: false, includesUnusedApps: false)
        XCTAssertEqual(targets, [.category(.userCache), .category(.largeFiles)])
    }

    func testScheduledRunsNeverCleanCompleteResults() {
        let state = AppState(performStartupTasks: false)
        let cache = result(.userCache, size: 100)
        state.categoryResults[.userCache] = cache
        state.categoryResults[.largeFiles] = result(.largeFiles, size: 9_000)
        state.categoryResults[.xcodeJunk] = result(.xcodeJunk, size: 5_000)
        XCTAssertEqual(state.scheduledCleanItemIDs, Set(cache.items.map(\.id)))
    }

    func testStoppingKeepsWhatWasFound() {
        let state = AppState(performStartupTasks: false)
        state.categoryResults[.userCache] = result(.userCache, size: 100)
        state.scanState = .scanning(progress: 0.4, currentCategory: "User Cache")
        state.stopSmartScan()
        XCTAssertTrue(state.scanWasCancelled)
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertFalse(state.isSmartScanRunning)
        XCTAssertEqual(state.smartCareResults.map(\.category), [.userCache])
    }

    func testAFreshStateShowsEssentialResults() {
        let state = AppState(performStartupTasks: false)
        XCTAssertEqual(state.resultsDepth, .essential)
        XCTAssertEqual(state.shownCategories, CleaningCategory.smartCare)
        XCTAssertTrue(state.reviewCategories.isEmpty)
        XCTAssertFalse(state.resultsIncludeOrphans)
    }

    func testSmartCareStartsOnEssentialAndReturnsToIt() {
        let state = AppState(performStartupTasks: false)
        XCTAssertEqual(state.scanDepth, .essential)
        state.scanDepth = .complete
        XCTAssertEqual(AppState(performStartupTasks: false).scanDepth, .essential, "the choice isn't carried to the next launch")
        state.resetSmartCareToStart()
        XCTAssertEqual(state.scanDepth, .essential)
    }

    func testTheFormerAdvancedCleanupSectionOpensSmartCare() {
        XCTAssertEqual(AppSection.remembered("cleanup"), .smartCare)
        XCTAssertEqual(AppSection.remembered("antivirus"), .antivirus)
        XCTAssertNil(AppSection.remembered("nothing"))
        XCTAssertEqual(AssistantTool.cleanup.section, .smartCare)
    }

    private func result(_ category: CleaningCategory, size: Int64) -> CategoryResult {
        let item = CleanableItem(name: "Fixture", path: "/fixtures/\(UUID().uuidString)", size: size,
                                 category: category, isSelected: true, lastModified: nil)
        return CategoryResult(category: category, items: [item], totalSize: size)
    }
}
