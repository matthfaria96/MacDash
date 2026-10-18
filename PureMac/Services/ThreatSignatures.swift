// Signature rules adapted from Mac Sai (https://github.com/iliyami/MacSai)
// Copyright (c) 2026, Mac Sai Contributors. BSD 3-Clause License.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Adware family names and launch-agent heuristics, used by the Antivirus
/// scanner (`AntivirusRules`). A small list of well-known macOS families; it
/// makes no claim to catch new or targeted malware on its own.
enum ThreatSignatures {
    /// Name fragments of long-lived macOS adware and scareware families.
    /// Matched case-insensitively against file and folder names.
    static let knownPatterns: [String] = [
        "genio", "pirrit", "shlayer", "bundlore", "adload",
        "mackeeper", "macdefender", "macprotector", "macguard",
        "maccleaner", "macshiny", "advancedmaccleaner",
        "searchbaron", "searchmarquis", "searchmine",
        "crossrider", "operatormac", "cimpli",
    ]

    /// Fragments that, inside a launch item's `ProgramArguments`, point to a
    /// downloaded or inline payload.
    static let suspiciousLaunchArguments: [String] = [
        "/tmp/", "curl ", "wget ", "python -c", "osascript", "base64",
    ]

    enum Reason: Equatable {
        /// The name matches a known adware family.
        case knownFamily
        /// A launch item runs something that looks like a dropped payload.
        case suspiciousLaunchItem
    }

    static func nameMatchesKnownPattern(_ name: String) -> Bool {
        knownPatterns.contains { name.localizedCaseInsensitiveContains($0) }
    }

    static func launchItemLooksSuspicious(plist: [String: Any]) -> Bool {
        var arguments = plist["ProgramArguments"] as? [String] ?? []
        if let program = plist["Program"] as? String { arguments.insert(program, at: 0) }
        guard !arguments.isEmpty else { return false }
        let joined = arguments.joined(separator: " ").lowercased()
        return suspiciousLaunchArguments.contains { joined.contains($0) }
    }

    /// Why `url` was flagged, or nil when it looks fine. Launch plists are also
    /// read for their arguments; every other file is judged by name only.
    static func reason(for url: URL, ignoringLabelPrefixes ignored: [String] = []) -> Reason? {
        let name = url.lastPathComponent
        if ignored.contains(where: { name.hasPrefix($0) }) { return nil }
        if nameMatchesKnownPattern(name) { return .knownFamily }
        guard url.pathExtension.lowercased() == "plist",
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        if let label = plist["Label"] as? String {
            if ignored.contains(where: { label.hasPrefix($0) }) { return nil }
            if nameMatchesKnownPattern(label) { return .knownFamily }
        }
        return launchItemLooksSuspicious(plist: plist) ? .suspiciousLaunchItem : nil
    }
}
