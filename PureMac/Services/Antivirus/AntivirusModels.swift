import Foundation

/// How much of the Mac a scan covers. The scopes follow what was measured on
/// a commercial scanner (see Clones/Moonlock/SPEC.md §5.7), not its rules.
enum AntivirusScanMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Downloads, Application Support, launch items and what they start,
    /// mounted disk images. About a minute.
    case quick
    /// Quick + every app, system extensions, login items and the programs
    /// running right now. A few minutes.
    case balanced
    /// Balanced + the whole user Library, Documents, Desktop, the Trash and
    /// the contents of ZIP archives.
    case deep
    /// Only the files and folders the user picked, archives included.
    case custom

    var id: String { rawValue }

    var scansArchives: Bool { self == .deep || self == .custom }
}

enum ThreatCategory: String, Codable, Sendable {
    case testFile
    case knownMalware
    case adware
    case persistence
    case unsignedProgram
    case script
}

enum ThreatSeverity: Int, Codable, Comparable, Sendable {
    /// Worth a look; often legitimate.
    case suspicious
    /// Matches something known to be unwanted.
    case high

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which check produced a detection, shown to the user as "Detected by".
enum DetectionSource: String, Codable, Sendable {
    case testSignature
    case fileHash
    case familyName
    case launchItem
    case codeSignature
    case scriptContent
}

/// How a program is signed, read with the Security framework.
enum SigningStatus: Codable, Hashable, Sendable {
    case apple
    case developerID(teamID: String)
    case adHoc
    case unsigned
    case invalid

    var teamID: String? {
        if case .developerID(let team) = self { return team }
        return nil
    }

    var isTrustworthy: Bool {
        switch self {
        case .apple, .developerID: return true
        case .adHoc, .unsigned, .invalid: return false
        }
    }
}

/// One file or folder that belongs to a threat. A launch agent and the
/// program it starts are two components of the same threat.
struct ThreatComponent: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable {
        case file
        case appBundle
        case launchItem
        case program
        case archive
    }

    var id: String { path }
    let path: String
    let role: Role
    let sha256: String?
    let size: Int64
    /// For a match inside a ZIP: the entry's path in the archive.
    var archiveEntry: String? = nil
}

struct Detection: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// "EICAR test file", "Adware: Pirrit", "Suspicious launch agent"…
    let name: String
    let category: ThreatCategory
    let severity: ThreatSeverity
    let source: DetectionSource
    /// Stable rule id, e.g. "test.eicar" or "launch.args.curl".
    let rule: String
    /// Plain-language reason shown under the name.
    let reason: String
    let components: [ThreatComponent]
    let signing: SigningStatus?
    let detectedAt: Date
    let mode: AntivirusScanMode

    var primary: ThreatComponent { components[0] }

    /// Launch items that the proposed action will unload first.
    var launchItems: [ThreatComponent] { components.filter { $0.role == .launchItem } }

    /// Two detections are the same threat when they cover the same files.
    var fingerprint: String { components.map(\.path).sorted().joined(separator: "\n") }
}

struct QuarantinedItem: Codable, Hashable, Sendable {
    let originalPath: String
    let storedPath: String
    let permissions: Int16
    /// Root-owned items need an administrator password to move back.
    let needsAdministrator: Bool
}

struct QuarantineRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let detection: Detection
    let items: [QuarantinedItem]
    let quarantinedAt: Date
}

/// Something the user said is safe. Hash survives renames and moves; a path
/// trusts whatever sits there; a Team ID trusts everything that developer signs.
struct TrustRule: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hash
        case path
        case teamID
    }

    var id: String { "\(kind.rawValue):\(value)" }
    let kind: Kind
    let value: String
    /// What the user saw when they trusted it.
    let label: String
    let addedAt: Date
}

struct AntivirusScanRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let mode: AntivirusScanMode
    let startedAt: Date
    let duration: TimeInterval
    let filesChecked: Int
    let detections: Int
    let wasCancelled: Bool
    var wasScheduled = false
}

struct AntivirusProgress: Sendable {
    enum Phase: Sendable {
        case preparing
        case launchItems
        case files
        case processes
    }

    var phase: Phase = .preparing
    var filesChecked = 0
    var detections = 0
    var currentPath = ""
}

/// What a scan is allowed to skip without opening the file again.
struct AntivirusCacheEntry: Hashable, Sendable {
    let inode: UInt64
    let modified: TimeInterval
    let size: Int64
}

struct AntivirusScanOutcome: Sendable {
    let detections: [Detection]
    let filesChecked: Int
    let cleanFiles: [String: AntivirusCacheEntry]
    let wasCancelled: Bool
}
