// Permission reading adapted from Mac Sai (https://github.com/iliyami/MacSai)
// Copyright (c) 2026, Mac Sai Contributors. BSD 3-Clause License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation
import SQLite3

/// Privacy permissions macOS records in its TCC databases that are worth
/// reviewing app by app.
enum PrivacyPermission: String, CaseIterable, Identifiable, Sendable {
    case fullDiskAccess
    case accessibility
    case screenRecording
    case camera
    case microphone
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: return String(localized: "Full Disk Access")
        case .accessibility: return String(localized: "Accessibility")
        case .screenRecording: return String(localized: "Screen Recording")
        case .camera: return String(localized: "Camera")
        case .microphone: return String(localized: "Microphone")
        case .automation: return String(localized: "Automation")
        }
    }

    var detail: String {
        switch self {
        case .fullDiskAccess: return String(localized: "Can read every file, including mail, messages and other apps' data.")
        case .accessibility: return String(localized: "Can control your Mac and read what's on screen.")
        case .screenRecording: return String(localized: "Can record or capture your screen.")
        case .camera: return String(localized: "Can use the camera.")
        case .microphone: return String(localized: "Can use the microphone.")
        case .automation: return String(localized: "Can control other apps.")
        }
    }

    var icon: String {
        switch self {
        case .fullDiskAccess: return "externaldrive.fill.badge.person.crop"
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .camera: return "video.fill"
        case .microphone: return "mic.fill"
        case .automation: return "gearshape.2.fill"
        }
    }

    /// Powerful permissions are listed first and highlighted.
    var isSensitive: Bool {
        switch self {
        case .fullDiskAccess, .accessibility, .screenRecording: return true
        case .camera, .microphone, .automation: return false
        }
    }

    fileprivate var tccServices: Set<String> {
        switch self {
        case .fullDiskAccess: return ["kTCCServiceSystemPolicyAllFiles"]
        case .accessibility: return ["kTCCServiceAccessibility"]
        case .screenRecording: return ["kTCCServiceScreenCapture"]
        case .camera: return ["kTCCServiceCamera"]
        case .microphone: return ["kTCCServiceMicrophone"]
        case .automation: return ["kTCCServiceAppleEvents"]
        }
    }

    /// The matching pane in System Settings › Privacy & Security.
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        case .automation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static func matching(service: String) -> PrivacyPermission? {
        allCases.first { $0.tccServices.contains(service) }
    }
}

/// One permission macOS has granted to one app.
struct PermissionGrant: Identifiable, Hashable, Sendable {
    let permission: PrivacyPermission
    let client: String
    let clientIsPath: Bool
    /// "Limited" access, which macOS offers for a few services.
    let isLimited: Bool
    /// For Automation: the app this client is allowed to control.
    let target: String?

    var id: String { "\(permission.rawValue)|\(client)|\(target ?? "")" }
}

/// Every permission one app holds, with the app resolved for display.
struct PermissionApp: Identifiable, Sendable {
    let client: String
    let clientIsPath: Bool
    let name: String
    let appURL: URL?
    let grants: [PermissionGrant]
    /// Names of the apps this one may control through Automation, resolved
    /// once while reading instead of on every redraw.
    let automationTargets: [String]

    var id: String { "\(clientIsPath ? "path" : "bundle")|\(client)" }

    var permissions: [PrivacyPermission] {
        PrivacyPermission.allCases.filter { permission in grants.contains { $0.permission == permission } }
    }

    /// A real app bundle, as opposed to a command-line tool or background program.
    var isApplication: Bool { appURL?.pathExtension.lowercased() == "app" }

    var hasSensitivePermission: Bool { permissions.contains { $0.isSensitive } }

}

/// Reads the permissions macOS has granted from the user and system TCC
/// databases. Read-only: macOS doesn't let apps change these, so changes are
/// made in System Settings.
enum AppPermissionsReader {
    enum Result: Sendable {
        case loaded([PermissionApp])
        /// The databases are protected by Full Disk Access.
        case needsFullDiskAccess
    }

    struct Row: Sendable {
        let service: String
        let client: String
        let clientType: Int
        let authValue: Int
        let indirectObject: String?
    }

    static func read() -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let databases = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        var rows: [Row] = []
        var readAny = false
        for path in databases {
            if let found = readRows(at: path) {
                rows += found
                readAny = true
            }
        }
        guard readAny else { return .needsFullDiskAccess }
        return .loaded(apps(from: grants(from: rows)))
    }

    // MARK: Parsing

    /// `auth_value` 2 is allowed and 3 limited; denied rows are skipped.
    static func grants(from rows: [Row]) -> [PermissionGrant] {
        var seen = Set<String>()
        var result: [PermissionGrant] = []
        for row in rows {
            guard let permission = PrivacyPermission.matching(service: row.service),
                  row.authValue == 2 || row.authValue == 3
            else { continue }
            let client = row.client.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !client.isEmpty else { continue }
            var target: String?
            if permission == .automation, let raw = row.indirectObject, !raw.isEmpty, raw != "UNUSED", raw != "NONE" {
                target = raw
            }
            let grant = PermissionGrant(
                permission: permission,
                client: client,
                clientIsPath: row.clientType == 1,
                isLimited: row.authValue == 3,
                target: target
            )
            if seen.insert(grant.id).inserted { result.append(grant) }
        }
        return result
    }

    /// Groups grants by app, apps with powerful permissions first.
    static func apps(from grants: [PermissionGrant]) -> [PermissionApp] {
        let grouped = Dictionary(grouping: grants) { "\($0.clientIsPath ? "path" : "bundle")|\($0.client)" }
        return grouped.values.compactMap { grants -> PermissionApp? in
            guard let first = grants.first else { return nil }
            let url = appURL(client: first.client, isPath: first.clientIsPath)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? (first.clientIsPath ? URL(fileURLWithPath: first.client).lastPathComponent : first.client)
            let targets = grants.compactMap { grant -> String? in
                guard grant.permission == .automation, let target = grant.target else { return nil }
                return displayName(forBundleIdentifier: target) ?? target
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return PermissionApp(client: first.client, clientIsPath: first.clientIsPath, name: name, appURL: url, grants: grants, automationTargets: targets)
        }
        .sorted {
            if $0.hasSensitivePermission != $1.hasSensitivePermission { return $0.hasSensitivePermission }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func displayName(forBundleIdentifier identifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func appURL(client: String, isPath: Bool) -> URL? {
        if isPath {
            return FileManager.default.fileExists(atPath: client) ? URL(fileURLWithPath: client) : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: client)
    }

    // MARK: SQLite

    /// nil when the database can't be opened or read (no Full Disk Access).
    private static func readRows(at path: String) -> [Row]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Older schemas have no indirect object column.
        let queries = [
            "SELECT service, client, client_type, auth_value, indirect_object_identifier FROM access",
            "SELECT service, client, client_type, auth_value, NULL FROM access",
        ]
        for sql in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                continue
            }
            defer { sqlite3_finalize(statement) }
            var rows: [Row] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                rows.append(Row(
                    service: text(statement, 0) ?? "",
                    client: text(statement, 1) ?? "",
                    clientType: Int(sqlite3_column_int(statement, 2)),
                    authValue: Int(sqlite3_column_int(statement, 3)),
                    indirectObject: text(statement, 4)
                ))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { return nil }
            return rows
        }
        return nil
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}
