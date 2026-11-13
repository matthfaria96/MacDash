import Foundation

// The Assistant: a diagnosis MacDash runs on its own. It measures the Mac,
// applies fixed rules to what it measured and writes down what it found, what
// it suggested and what was done. No model, no network, nothing in the
// background: it only works while an analysis is running.

/// How urgent a finding is.
enum AssistantSeverity: String, Codable, CaseIterable, Sendable {
    case critical
    case attention
    case suggestion
    case info

    /// Lower sorts first.
    var rank: Int {
        switch self {
        case .critical: return 0
        case .attention: return 1
        case .suggestion: return 2
        case .info: return 3
        }
    }
}

/// The part of the Mac a finding is about.
enum AssistantArea: String, Codable, CaseIterable, Sendable {
    case disk
    case growth
    case projects
    case editors
    case claude
    case devTools
    case apps
    case caches
}

/// What can be done about a finding.
enum AssistantActionKind: String, Codable, Sendable {
    /// The Assistant moves the listed items to the Trash, after checking each
    /// one again and asking.
    case trash
    /// Another MacDash tool handles it with its own fresh scan and confirmation.
    case openTool
    /// Nothing to run: it explains what is going on.
    case advice
}

/// The MacDash tool a finding hands over to.
enum AssistantTool: String, Codable, Sendable {
    case smartCare
    case cleanup
    case apps
    case driveOffload
    case spaceLens

    var section: AppSection {
        switch self {
        case .smartCare: return .smartCare
        case .cleanup: return .cleanup
        case .apps: return .apps
        case .driveOffload: return .driveOffload
        case .spaceLens: return .spaceLens
        }
    }

    var title: String {
        switch self {
        case .smartCare: return String(localized: "Smart Care")
        case .cleanup: return String(localized: "Advanced Cleanup")
        case .apps: return String(localized: "Applications")
        case .driveOffload: return String(localized: "Drive Offload")
        case .spaceLens: return String(localized: "Space Lens")
        }
    }
}

/// Where a finding stands in its report.
enum AssistantFindingStatus: String, Codable, Sendable {
    case pending
    /// Everything listed went to the Trash.
    case done
    /// Some items moved; the rest is still listed.
    case partial
    case ignored
    /// Handed over to another tool.
    case opened

    var isOpen: Bool { self == .pending || self == .partial }
}

/// One file or folder a finding points at. `fileID` and `modified` are what
/// the item looked like when the analysis ran: an item that no longer matches
/// is never touched.
struct AssistantTarget: Codable, Identifiable, Hashable, Sendable {
    let path: String
    /// What the row is called: "KAZE › build", "Bun · install/cache".
    let label: String
    var size: Int64
    let fileID: UInt64?
    let isDirectory: Bool
    let modified: Date?
    /// Why it is listed, shown under its name.
    var note: String
    /// Ticked by default when the items are reviewed.
    var suggested: Bool
    /// The catalog rule that allows this path to go to the Trash. Checked
    /// again right before it moves.
    let rule: String

    var id: String { path }
}

struct AssistantFinding: Codable, Identifiable, Sendable {
    let id: String
    let area: AssistantArea
    var severity: AssistantSeverity
    let symbol: String
    let title: String
    /// What was found and why it matters.
    let explanation: String
    /// What MacDash suggests doing.
    let recommendation: String
    let action: AssistantActionKind
    var tool: AssistantTool?
    var targets: [AssistantTarget] = []
    /// Items left out of `targets` to keep the report small.
    var omittedCount = 0
    /// Size of everything the finding is about.
    var total: Int64 = 0
    /// Space the suggestion would recover as it stands: for a list to review,
    /// only the items ticked by default.
    var reclaimable: Int64 = 0
    /// Apps that must be closed before the items can move (bundle identifiers).
    var requiresQuit: [String] = []
    var status: AssistantFindingStatus = .pending
    /// What happened when it was handled.
    var outcome: String?
}

/// One slice of "what is using the disk".
struct AssistantUsage: Codable, Identifiable, Sendable {
    struct Item: Codable, Identifiable, Sendable {
        let name: String
        let path: String?
        let bytes: Int64
        var id: String { path ?? name }
    }

    let id: String
    let title: String
    let symbol: String
    let bytes: Int64
    /// The largest things inside, biggest first.
    var items: [Item] = []
}

/// One step of the analysis and what it covered.
struct AssistantProbe: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    /// False when macOS kept part of it out of reach.
    var complete = true
}

/// Something done from a report: items moved to the Trash, a tool opened or a
/// suggestion ignored.
struct AssistantActionRecord: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case trash
        case openTool
        case ignore
        case restore
    }

    struct Skipped: Codable, Hashable, Sendable {
        let path: String
        let reason: String
    }

    var id = UUID()
    let date: Date
    let findingID: String
    let findingTitle: String
    let kind: Kind
    var requested = 0
    var moved = 0
    var bytes: Int64 = 0
    var movedPaths: [String] = []
    var skipped: [Skipped] = []
}

/// One analysis: what the Mac looked like at that moment, what was found and
/// what was done about it. A report is a record. Nothing in it is acted on
/// later without a new check.
struct AssistantReport: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    var duration: TimeInterval = 0
    var appVersion = ""
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    /// One sentence summing the analysis up.
    var headline = ""
    var usage: [AssistantUsage] = []
    var probes: [AssistantProbe] = []
    var findings: [AssistantFinding] = []
    var actions: [AssistantActionRecord] = []
    /// Sizes of the larger folders, compared by the next analysis to tell
    /// what is growing.
    var folderSizes: [String: Int64] = [:]
    var filesChecked = 0
    /// True when macOS kept folders out of reach (no Full Disk Access).
    var limitedAccess = false

    var diskUsed: Int64 { max(0, diskTotal - diskFree) }

    /// Space the open suggestions would still recover.
    var reclaimable: Int64 {
        findings.filter { $0.status.isOpen }.reduce(0) { $0 + $1.reclaimable }
    }

    /// Space moved to the Trash from this report.
    var movedBytes: Int64 {
        actions.filter { $0.kind == .trash }.reduce(0) { $0 + $1.bytes }
    }

    func count(_ statuses: AssistantFindingStatus...) -> Int {
        findings.filter { statuses.contains($0.status) }.count
    }
}

// MARK: - Checking again before acting

/// What a fresh check says about one item.
enum AssistantItemState: Equatable, Sendable {
    case ready
    /// No longer there.
    case gone
    /// Not the item the analysis saw, or no longer what the rule expects.
    case changed(String)
    /// Still valid, but can't move right now.
    case blocked(String)

    var reason: String? {
        switch self {
        case .ready: return nil
        case .gone: return String(localized: "No longer there")
        case .changed(let text), .blocked(let text): return text
        }
    }
}

struct AssistantPlanItem: Identifiable, Equatable, Sendable {
    let target: AssistantTarget
    /// Measured again during the check.
    var size: Int64
    var state: AssistantItemState
    var selected: Bool

    var id: String { target.path }
}

/// The result of checking a finding's items again, shown for confirmation.
/// Only what is listed here, and still matches when the button is pressed,
/// goes to the Trash.
struct AssistantPlan: Identifiable, Equatable, Sendable {
    let findingID: String
    let title: String
    let checkedAt: Date
    var items: [AssistantPlanItem]

    var id: String { findingID }
    var ready: [AssistantPlanItem] { items.filter { $0.state == .ready } }
    var selected: [AssistantPlanItem] { ready.filter(\.selected) }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }
    var unavailable: [AssistantPlanItem] { items.filter { $0.state != .ready } }

    /// A check older than this is repeated before anything moves.
    static let lifetime: TimeInterval = 5 * 60
    func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(checkedAt) < Self.lifetime }
}
