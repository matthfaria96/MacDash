import CryptoKit
import Foundation
import Security

/// Detection rules. Everything here comes from public sources: the EICAR
/// test standard, adware family names (`ThreatSignatures`, ported from
/// Mac Sai), and launch-item heuristics. No vendor database.
enum AntivirusRules {
    /// Bumped whenever the rules change, so cached "clean" verdicts expire.
    static let version = "2026.10.17"

    // MARK: Test file

    /// The EICAR standard test string, split so MacDash's own binary never
    /// contains it in one piece and isn't flagged by other scanners.
    static var eicar: Data {
        Data(("X5O!P%@AP[4\\PZX54(P^)7CC)7}$" + "EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*").utf8)
    }

    /// The standard allows trailing whitespace up to 128 bytes in total.
    static func isEICAR(_ head: Data, fileSize: Int64) -> Bool {
        guard fileSize >= 68, fileSize <= 128, head.starts(with: eicar) else { return false }
        return head.dropFirst(eicar.count).allSatisfy { [0x20, 0x09, 0x0A, 0x0D, 0x1A].contains($0) }
    }

    // MARK: Hashes

    /// SHA-256 of known malicious files. Starts with the EICAR file; a signed,
    /// updatable list replaces this in phase 2.
    static let knownHashes: [String: String] = [
        "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f": "EICAR test file",
    ]

    /// nil for files over `limit`: hashing every large binary would make
    /// a scan read gigabytes for a list that holds small payloads.
    static func sha256(of url: URL, limit: Int64 = 100 * 1_048_576) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > UInt64(limit) { return nil }
        try? handle.seek(toOffset: 0)
        var hasher = SHA256()
        while true {
            // Each chunk is released right away; scans run for minutes on a
            // background thread whose pool would otherwise never drain.
            let more: Bool = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: File kinds

    enum FileKind {
        case machO
        case script
        case zip
        case other
    }

    static func kind(of head: Data) -> FileKind {
        guard head.count >= 4 else { return .other }
        let magic = head.prefix(4).map { $0 }
        switch magic {
        case [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE]:
            return .machO
        case [0xCA, 0xFE, 0xBA, 0xBE]:
            // Universal binaries share this magic with Java classes. A fat
            // header continues with a small architecture count; a class file
            // with its version (45 and up).
            guard head.count >= 8 else { return .other }
            let count = head[4..<8].reduce(0) { $0 << 8 | Int($1) }
            return (1...20).contains(count) ? .machO : .other
        case [0x50, 0x4B, 0x03, 0x04]:
            return .zip
        default:
            return head.starts(with: Data("#!".utf8)) ? .script : .other
        }
    }

    // MARK: Adware names

    /// Known adware family names, from `ThreatSignatures`.
    static func adwareFamily(in name: String) -> String? {
        ThreatSignatures.knownPatterns.first { name.localizedCaseInsensitiveContains($0) }
    }

    // MARK: Script content

    /// Script fragments that download and run code, decode hidden payloads or
    /// fake a password prompt. Only judged on scripts a launch item runs.
    static let suspiciousScriptFragments: [(rule: String, all: [String])] = [
        ("script.download-exec", ["curl ", "| sh"]),
        ("script.download-exec", ["curl ", "|sh"]),
        ("script.download-exec", ["curl ", "| bash"]),
        ("script.download-exec", ["wget ", "| sh"]),
        ("script.base64-exec", ["base64 -d", "| sh"]),
        ("script.base64-exec", ["base64 --decode", "| bash"]),
        ("script.base64-exec", ["base64 -D", "| sh"]),
        ("script.fake-password", ["osascript", "with hidden answer"]),
        ("script.quarantine-strip", ["xattr -d", "com.apple.quarantine"]),
        ("script.quarantine-strip", ["xattr -c", "/tmp/"]),
    ]

    static func suspiciousScriptRule(_ text: String) -> String? {
        let lowered = text.lowercased()
        return suspiciousScriptFragments.first { entry in
            entry.all.allSatisfy { lowered.contains($0.lowercased()) }
        }?.rule
    }

    // MARK: Locations

    /// Places programs aren't normally installed. An unsigned or ad-hoc
    /// program here, started by a launch item, is worth a look.
    static func isUnusualProgramLocation(_ path: String, home: String) -> Bool {
        let unusual = ["/tmp/", "/private/tmp/", "/private/var/tmp/", "/var/tmp/", "/Users/Shared/", "\(home)/Downloads/"]
        if unusual.contains(where: path.hasPrefix) { return true }
        // A hidden folder anywhere in the path (~/.local/bin is common for
        // developer tools, so only hidden folders inside Library count).
        let components = path.split(separator: "/")
        if let library = components.firstIndex(of: "Library") {
            return components[(library + 1)...].dropLast().contains { $0.hasPrefix(".") }
        }
        return false
    }

    /// Package managers sign with ad-hoc linker signatures; their programs
    /// are not suspicious for that alone.
    static func isPackageManagerPath(_ path: String) -> Bool {
        ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/", "/opt/local/", "/nix/"].contains(where: path.hasPrefix)
    }

    // MARK: Code signature

    static func signingStatus(of url: URL) -> SigningStatus {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return .unsigned
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return .unsigned }
        if dict[kSecCodeInfoIdentifier as String] == nil { return .unsigned }
        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        // kSecCodeSignatureAdhoc = 0x2
        if flags & 0x2 != 0 { return .adHoc }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            return .invalid
        }
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess {
            return .apple
        }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String {
            return .developerID(teamID: team)
        }
        return .adHoc
    }
}
