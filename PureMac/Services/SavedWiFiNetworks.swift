// Wi-Fi handling adapted from Mac Sai (https://github.com/iliyami/MacSai)
// Copyright (c) 2026, Mac Sai Contributors. BSD 3-Clause License.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// A Wi-Fi network this Mac joins automatically.
struct SavedWiFiNetwork: Identifiable, Hashable, Sendable {
    let device: String
    let ssid: String

    var id: String { "\(device)|\(ssid)" }
}

/// Lists and forgets saved Wi-Fi networks through `networksetup`, the same
/// list System Settings › Wi-Fi › Known Networks shows.
enum SavedWiFiNetworks {
    enum ForgetError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return String(localized: "Administrator access was cancelled, so nothing changed.")
            case .failed(let message):
                return message.isEmpty ? String(localized: "The networks could not be forgotten.") : message
            }
        }
    }

    /// What the Mac knows about the network it is on now. macOS hides the
    /// network's name from apps, so this describes the link, not the SSID.
    struct ConnectionDetails: Sendable {
        let security: String?
        let channel: String?
        let standard: String?
        let rateMbps: Int?
        let signal: String?
        let country: String?
    }

    enum PasswordError: LocalizedError {
        case cancelled
        case notFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Authorization was cancelled.")
            case .notFound: return String(localized: "No password is saved for this network.")
            case .failed(let message):
                return message.isEmpty ? String(localized: "The password could not be read.") : message
            }
        }
    }

    struct Listing: Sendable {
        let connection: ConnectionDetails?
        /// False when the Mac has no Wi-Fi hardware.
        let hasWiFi: Bool
        let networks: [SavedWiFiNetwork]
        let currentSSID: String?
    }

    private static let networksetup = "/usr/sbin/networksetup"

    static func list() async -> Listing {
        await Task.detached(priority: .userInitiated) {
            let ports = run(networksetup, ["-listallhardwareports"]).output
            let devices = wifiDevices(fromHardwarePorts: ports)
            var networks: [SavedWiFiNetwork] = []
            var current: String?
            for device in devices {
                let output = run(networksetup, ["-listpreferredwirelessnetworks", device]).output
                networks += ssids(fromPreferredList: output).map { SavedWiFiNetwork(device: device, ssid: $0) }
                if current == nil {
                    current = currentSSID(fromAirportNetwork: run(networksetup, ["-getairportnetwork", device]).output)
                }
            }
            return Listing(connection: nil, hasWiFi: !devices.isEmpty, networks: networks, currentSSID: current)
        }.value
    }

    /// Link details for the current connection. `system_profiler` takes a few
    /// seconds, so this is read after the list is already on screen.
    static func connectionDetails() async -> ConnectionDetails? {
        await Task.detached(priority: .utility) { currentConnection() }.value
    }

    /// The ways macOS has stored Wi-Fi passwords over the years: by kind,
    /// by the "AirPort" service, or labeled with the network's name.
    private static func lookups(for ssid: String) -> [[String]] {
        [
            ["find-generic-password", "-D", "AirPort network password", "-a", ssid],
            ["find-generic-password", "-s", "AirPort", "-a", ssid],
            ["find-generic-password", "-l", ssid],
        ]
    }

    /// Reads a saved password from the keychain, the way Keychain Access
    /// does: macOS shows its own prompt and the user approves each read.
    static func password(for ssid: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            for lookup in SavedWiFiNetworks.lookups(for: ssid) {
                let result = SavedWiFiNetworks.run("/usr/bin/security", lookup + ["-w"])
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                switch result.status {
                case 0 where !output.isEmpty:
                    return output
                case 44:
                    continue // Not stored this way; try the next one.
                case 51, 128:
                    throw PasswordError.cancelled
                default:
                    if output.localizedCaseInsensitiveContains("could not be found") { continue }
                    if output.localizedCaseInsensitiveContains("cancel") || output.localizedCaseInsensitiveContains("denied")
                        || output.localizedCaseInsensitiveContains("interaction") {
                        throw PasswordError.cancelled
                    }
                    throw PasswordError.failed(output)
                }
            }
            throw PasswordError.notFound
        }.value
    }

    /// When each network was saved, read from its keychain entry's creation
    /// date. This reads only the entry's details, never the password, so
    /// macOS doesn't ask for anything.
    static func addedDates(for ssids: [String]) async -> [String: Date] {
        await Task.detached(priority: .utility) {
            var dates: [String: Date] = [:]
            for ssid in ssids {
                for lookup in SavedWiFiNetworks.lookups(for: ssid) {
                    let result = SavedWiFiNetworks.run("/usr/bin/security", lookup)
                    guard result.status == 0 else { continue }
                    if let date = SavedWiFiNetworks.creationDate(fromKeychainAttributes: result.output) {
                        dates[ssid] = date
                    }
                    break
                }
            }
            return dates
        }.value
    }

    /// `"cdat"<timedate>=0x… "20231012183000Z\000"` → that date.
    static func creationDate(fromKeychainAttributes output: String) -> Date? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("\"cdat\"") }),
              let match = line.range(of: #""\d{14}Z"#, options: .regularExpression)
        else { return nil }
        let digits = line[match].dropFirst().prefix(14)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(digits))
    }

    private static func currentConnection() -> ConnectionDetails? {
        let output = run("/usr/sbin/system_profiler", ["SPAirPortDataType", "-json"]).output
        guard let root = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let airport = (root["SPAirPortDataType"] as? [[String: Any]])?.first,
              let interfaces = airport["spairport_airport_interfaces"] as? [[String: Any]],
              let info = interfaces.compactMap({ $0["spairport_current_network_information"] as? [String: Any] }).first
        else { return nil }
        return ConnectionDetails(
            security: (info["spairport_security_mode"] as? String).map(securityName),
            channel: info["spairport_network_channel"] as? String,
            standard: info["spairport_network_phymode"] as? String,
            rateMbps: info["spairport_network_rate"] as? Int,
            signal: info["spairport_signal_noise"] as? String,
            country: info["spairport_network_country_code"] as? String
        )
    }

    /// "spairport_security_mode_wpa2_personal" → "WPA2 Personal".
    static func securityName(_ code: String) -> String {
        let trimmed = code.replacingOccurrences(of: "spairport_security_mode_", with: "")
        return trimmed.split(separator: "_").map { word in
            word.hasPrefix("wpa") || word.hasPrefix("wep") ? word.uppercased() : word.capitalized
        }.joined(separator: " ")
    }

    /// Removes the networks from the preferred list. macOS requires an
    /// administrator for this, so the standard password prompt appears once.
    static func forget(_ networks: [SavedWiFiNetwork]) async throws {
        let valid = networks.filter { isValidDevice($0.device) && !$0.ssid.isEmpty }
        guard !valid.isEmpty else { return }
        let command = valid
            .map { commandLine(networksetup, ["-removepreferredwirelessnetwork", $0.device, $0.ssid]) }
            .joined(separator: " ; ")
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let result = await Task.detached(priority: .userInitiated) {
            run("/usr/bin/osascript", ["-e", script])
        }.value
        guard result.status != 0 else { return }
        if result.output.contains("User canceled") || result.output.contains("-128") {
            throw ForgetError.cancelled
        }
        throw ForgetError.failed(humanReadableError(result.output))
    }

    // MARK: Parsing

    /// Devices of every "Wi-Fi" (or older "AirPort") hardware port.
    static func wifiDevices(fromHardwarePorts output: String) -> [String] {
        var devices: [String] = []
        var isWiFiPort = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let port = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
                isWiFiPort = port == "Wi-Fi" || port == "AirPort"
            } else if line.hasPrefix("Device:"), isWiFiPort {
                let device = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                if isValidDevice(device), !devices.contains(device) { devices.append(device) }
                isWiFiPort = false
            }
        }
        return devices
    }

    /// SSIDs are the tab-indented lines under "Preferred networks on …:".
    static func ssids(fromPreferredList output: String) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> String? in
            guard line.hasPrefix("\t") else { return nil }
            let ssid = String(line.dropFirst()).trimmingCharacters(in: .newlines)
            guard !ssid.trimmingCharacters(in: .whitespaces).isEmpty, seen.insert(ssid).inserted else { return nil }
            return ssid
        }
    }

    /// "Current Wi-Fi Network: Name". macOS hides the name from apps without
    /// Location access, in which case this returns nil.
    static func currentSSID(fromAirportNetwork output: String) -> String? {
        let prefix = "Current Wi-Fi Network: "
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let ssid = String(line.dropFirst(prefix.count))
        return ssid.isEmpty ? nil : ssid
    }

    /// Interface names like "en1": a letter first, then letters or digits.
    static func isValidDevice(_ device: String) -> Bool {
        guard let first = device.unicodeScalars.first, device.count <= 16,
              CharacterSet.letters.contains(first)
        else { return false }
        return device.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Strips osascript's "1:92: execution error: … (1)" wrapper.
    static func humanReadableError(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "execution error: ") {
            text = String(text[range.upperBound...])
        }
        if let open = text.range(of: " (", options: .backwards), text.hasSuffix(")"),
           Int(text[open.upperBound...].dropLast()) != nil {
            text = String(text[..<open.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
