import XCTest
@testable import MacDash

/// What the on-device model is told. The model only words these facts, so
/// they must carry the numbers and never invite it to act.
final class AssistantChatTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    private func report() -> AssistantReport {
        var report = AssistantReport(date: Date(timeIntervalSince1970: 1_000_000))
        report.diskTotal = 245 * gb
        report.diskFree = 11 * gb
        report.headline = "Space is running low."

        var builds = AssistantFinding(
            id: "builds", area: .devTools, severity: .attention, symbol: "hammer.fill", title: "Xcode build folders",
            explanation: "Build output Xcode can recreate.", recommendation: "Move old DerivedData to the Trash.", action: .trash
        )
        builds.reclaimable = 18 * gb
        builds.targets = [
            AssistantTarget(path: NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData/Small-1", label: "Small-1", size: 1 * gb,
                            fileID: nil, isDirectory: true, modified: nil, note: "", suggested: true, rule: "derivedData"),
            AssistantTarget(path: NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData/Big-2", label: "Big-2", size: 9 * gb,
                            fileID: nil, isDirectory: true, modified: nil, note: "", suggested: true, rule: "derivedData"),
        ]
        var done = AssistantFinding(
            id: "npm", area: .caches, severity: .suggestion, symbol: "shippingbox", title: "npm cache",
            explanation: "", recommendation: "Safe to clear.", action: .trash
        )
        done.status = .done
        var urgent = AssistantFinding(
            id: "disk", area: .disk, severity: .critical, symbol: "internaldrive", title: "Disk almost full",
            explanation: "", recommendation: "Free space first.", action: .advice
        )
        urgent.reclaimable = 0
        report.findings = [builds, done, urgent]
        return report
    }

    func testSummaryCarriesTheNumbersMostUrgentFirst() throws {
        let summary = AssistantChatFacts.summary(report: report(), now: Date(timeIntervalSince1970: 1_000_120))
        XCTAssertTrue(summary.contains("Disk almost full"))
        XCTAssertTrue(summary.contains("Xcode build folders, frees up to \(AssistantChatFacts.size(18 * gb))"))
        let urgent = try XCTUnwrap(summary.range(of: "Disk almost full"))
        let builds = try XCTUnwrap(summary.range(of: "Xcode build folders"))
        XCTAssertLessThan(urgent.lowerBound, builds.lowerBound)
        // The largest items come first, with paths shortened to the home folder.
        let big = try XCTUnwrap(summary.range(of: "Big-2"))
        let small = try XCTUnwrap(summary.range(of: "Small-1"))
        XCTAssertLessThan(big.lowerBound, small.lowerBound)
        XCTAssertTrue(summary.contains("~/Library/Developer/Xcode/DerivedData/Big-2"))
        XCTAssertFalse(summary.contains(NSHomeDirectory() + "/Library"))
        // Each recommendation says which button handles it.
        XCTAssertTrue(summary.contains("Button: \(AssistantChatFacts.reviewLabel)."))
        // A handled finding is mentioned as handled, not as open.
        XCTAssertTrue(summary.contains("Already handled: npm cache."))
    }

    func testWithoutAnAnalysisTheModelIsToldSo() {
        XCTAssertTrue(AssistantChatFacts.summary(report: nil).hasPrefix("No analysis has been run yet."))
    }

    func testInstructionsSetTheLanguageAndForbidActing() {
        let instructions = AssistantChatFacts.instructions(report: report(), language: "Portuguese (Brazil)")
        XCTAssertTrue(instructions.contains("Always answer in Portuguese (Brazil)."))
        XCTAssertTrue(instructions.contains("You cannot delete, move, quit or change anything"))
        XCTAssertTrue(instructions.contains("Never invent"))
    }

    func testEachQuestionCarriesTheLiveReading() {
        let prompt = AssistantChatFacts.prompt(question: "Why is my Mac slow?", activity: "CPU in use: 71%.")
        XCTAssertTrue(prompt.contains("CPU in use: 71%."))
        XCTAssertTrue(prompt.hasSuffix("Question: Why is my Mac slow?"))
    }

    @MainActor
    func testClosingTheChatForgetsTheConversation() {
        let chat = AssistantChat.shared
        chat.begin(report())
        chat.end()
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(chat.isResponding)
        XCTAssertNil(chat.notice)
    }
}

/// The Assistant as the whole Mac's doctor: disk health and the backup show
/// up in its diagnosis, judged by the same rules as Processes' Health card.
final class AssistantHealthTests: XCTestCase {
    private func facts(_ backup: BackupFacts?) -> AssistantFacts {
        var facts = AssistantFacts(home: "/Users/fixture", now: Date(timeIntervalSince1970: 2_000_000_000))
        facts.health = backup.map { DeviceHealthFacts(drives: [], backup: $0) }
        return facts
    }

    func testNoBackupBecomesAFindingThatOpensProcesses() throws {
        let findings = AssistantRules.healthFindings(facts(BackupFacts()))
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(finding.id, "health.backup")
        XCTAssertEqual(finding.area, .health)
        XCTAssertEqual(finding.severity, .attention)
        XCTAssertEqual(finding.action, .openTool)
        XCTAssertEqual(finding.tool, .processes)
        XCTAssertEqual(AssistantTool.processes.section, .processes)
    }

    func testARecentBackupStaysQuiet() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let backup = BackupFacts(destinations: [.init(name: "Backup", mountPoint: "/Volumes/Backup")],
                                 lastBackup: now.addingTimeInterval(-3_600), checkedDetails: true)
        XCTAssertTrue(AssistantRules.healthFindings(facts(backup)).isEmpty)
    }

    func testWithoutHealthReadingsNothingIsSaid() {
        XCTAssertTrue(AssistantRules.healthFindings(facts(nil)).isEmpty)
        XCTAssertFalse(AssistantRules.probes(facts(nil)).contains { $0.id == "health" })
        XCTAssertTrue(AssistantRules.probes(facts(BackupFacts())).contains { $0.id == "health" })
    }

    func testTheChatKnowsWhichMacItIs() {
        let instructions = AssistantChatFacts.instructions(report: nil, language: "English")
        XCTAssertTrue(instructions.contains("This Mac: \(MacSystemInfo.current.productFamily)"))
    }
}
