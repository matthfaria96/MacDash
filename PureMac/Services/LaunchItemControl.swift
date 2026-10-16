// Login-item handling adapted from Mac Sai (https://github.com/iliyami/MacSai)
// Copyright (c) 2026, Mac Sai Contributors. BSD 3-Clause License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

/// Reads and changes what starts with the Mac: login items (through System
/// Events, as System Settings does) and launch agents in the user's own domain
/// (through launchd, without editing other apps' files).
enum LaunchItemControl {
    struct LoginItem: Hashable, Sendable {
        let name: String
        let path: String
    }

    enum ControlError: LocalizedError {
        case automationDenied
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .automationDenied:
                return String(localized: "MacFresh isn't allowed to control System Events. Allow it in System Settings › Privacy & Security › Automation.")
            case .commandFailed(let message):
                return message.isEmpty ? String(localized: "The change could not be made.") : message
            }
        }
    }

    // MARK: Login items

    /// Login items listed in System Settings › General › Login Items.
    static func loginItems() async throws -> [LoginItem] {
        let script = """
        tell application "System Events"
            set out to ""
            repeat with anItem in every login item
                set out to out & (name of anItem) & tab & (path of anItem) & linefeed
            end repeat
            return out
        end tell
        """
        let output = try await runAppleScript(script)
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            return LoginItem(name: name, path: parts.count > 1 ? parts[1] : "")
        }
    }

    static func removeLoginItem(named name: String) async throws {
        _ = try await runAppleScript("""
        tell application "System Events" to delete login item "\(escape(name))"
        """)
    }

    static func addLoginItem(path: String) async throws {
        _ = try await runAppleScript("""
        tell application "System Events" to make new login item at end with properties {path:"\(escape(path))", hidden:false}
        """)
    }

    // MARK: User launch agents

    /// launchd's own enabled/disabled overrides for the user's domain, by label.
    static func userAgentOverrides() async -> [String: Bool] {
        guard let result = try? await run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]), result.status == 0 else {
            return [:]
        }
        var disabled: [String: Bool] = [:]
        for line in result.output.split(separator: "\n") {
            // "com.example.agent" => disabled
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            disabled[label] = state == "disabled" || state == "true"
        }
        return disabled
    }

    /// Turns a user launch agent on or off. Off stops it now and keeps it from
    /// starting again; on lets launchd start it again. The agent's plist is
    /// left untouched.
    static func setUserAgent(label: String, plistURL: URL, enabled: Bool) async throws {
        let domain = "gui/\(getuid())"
        if enabled {
            let enable = try await run("/bin/launchctl", ["enable", "\(domain)/\(label)"])
            guard enable.status == 0 else { throw ControlError.commandFailed(enable.output) }
            // Already-loaded agents report an error here; that's fine.
            _ = try? await run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        } else {
            let disable = try await run("/bin/launchctl", ["disable", "\(domain)/\(label)"])
            guard disable.status == 0 else { throw ControlError.commandFailed(disable.output) }
            // Not-loaded agents report an error here; that's fine.
            _ = try? await run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        }
    }

    // MARK: Process helpers

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ script: String) async throws -> String {
        let result = try await run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            // -1743: the user (or policy) refused Automation access.
            if result.output.contains("-1743") || result.output.contains("Not authorized") {
                throw ControlError.automationDenied
            }
            throw ControlError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}
