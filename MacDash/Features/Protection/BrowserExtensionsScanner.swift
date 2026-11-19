// Browser extension handling adapted from Mac Sai (https://github.com/iliyami/MacSai)
// Copyright (c) 2026, Mac Sai Contributors. BSD 3-Clause License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Darwin
import Foundation

enum BrowserKind: String, CaseIterable, Identifiable, Sendable {
    case safari
    case chrome
    case brave
    case edge
    case arc
    case firefox

    var id: String { rawValue }

    var label: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .edge: return "Edge"
        case .arc: return "Arc"
        case .firefox: return "Firefox"
        }
    }

    /// Every app that can hold this browser's profiles open. Firefox Beta,
    /// Developer Edition and Nightly share the Firefox profiles folder.
    var bundleIdentifiers: Set<String> {
        switch self {
        case .safari: return ["com.apple.Safari"]
        case .chrome: return ["com.google.Chrome"]
        case .brave: return ["com.brave.Browser"]
        case .edge: return ["com.microsoft.edgemac"]
        case .arc: return ["company.thebrowser.Browser"]
        case .firefox:
            return ["org.mozilla.firefox", "org.mozilla.firefoxbeta", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
        }
    }

    var primaryBundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .arc: return "company.thebrowser.Browser"
        case .firefox: return "org.mozilla.firefox"
        }
    }

    /// Where to remove an extension inside the browser itself.
    var extensionsMenuPath: String {
        switch self {
        case .safari: return String(localized: "Safari › Settings › Extensions")
        case .firefox: return String(localized: "Tools › Add-ons and Themes")
        case .chrome, .brave, .edge, .arc: return String(localized: "Window › Extensions")
        }
    }

    /// User data folder under ~/Library/Application Support for Chromium browsers.
    var chromiumUserDataRelativePath: String? {
        switch self {
        case .chrome: return "Google/Chrome"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .edge: return "Microsoft Edge"
        case .arc: return "Arc/User Data"
        case .safari, .firefox: return nil
        }
    }

    /// Managed-preferences domain where admins force-install extensions.
    var policyDomain: String? {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.Edge"
        case .arc: return "company.thebrowser.Browser"
        case .safari, .firefox: return nil
        }
    }

    static let chromiumFamily: [BrowserKind] = [.chrome, .brave, .edge, .arc]
}

/// Why an extension can or can't be moved to the Trash.
enum BrowserExtensionOrigin: String, Hashable, Sendable {
    /// Installed by the user; the folder can be trashed while the browser is closed.
    case user
    /// Force-installed by an admin or configuration profile; the browser would reinstall it.
    case policy
    /// Ships with the browser.
    case component
    /// Safari extensions live inside apps and are managed by macOS.
    case safariApp
}

struct BrowserExtensionRecord: Identifiable, Hashable, Sendable {
    /// Browser + profile + extension, so the same extension in two profiles is two rows.
    var id: String { "\(browser.rawValue)|\(profile)|\(identifier)" }

    let browser: BrowserKind
    /// Profile folder name ("Default", "Profile 1", "abcd.default-release"); empty for Safari.
    let profile: String
    let identifier: String
    let name: String
    let updatedAt: Date?
    let path: String
    let origin: BrowserExtensionOrigin
    /// The name matches a known adware family. A hint, not a verdict.
    let isSuspicious: Bool
}

struct BrowserExtensionScan: Sendable {
    let records: [BrowserExtensionRecord]
    /// Browsers found on this Mac, so an empty list can say what was checked.
    let installedBrowsers: [BrowserKind]
}

enum BrowserExtensionsScanner {
    enum RemovalOutcome: Equatable, Sendable {
        case trashed
        case removeInBrowser(BrowserKind)
        case managedByPolicy(BrowserKind)
        case builtIn(BrowserKind)
        case openedSafariSettings
        case refused
        case failed(String)
    }

    /// Long-lived macOS adware families, matched against extension names.
    static let adwarePatterns = [
        "genio", "pirrit", "shlayer", "bundlore", "adload",
        "mackeeper", "macdefender", "macprotector", "macguard",
        "maccleaner", "macshiny", "advancedmaccleaner",
        "searchbaron", "searchmarquis", "searchmine",
        "crossrider", "operatormac", "cimpli",
    ]

    static func scan() async -> BrowserExtensionScan {
        await Task.detached(priority: .userInitiated) {
            var records: [BrowserExtensionRecord] = []
            for browser in BrowserKind.chromiumFamily {
                records += chromeFamily(browser)
            }
            records += firefox()
            records += safari()
            let sorted = records.sorted {
                if $0.isSuspicious != $1.isSuspicious { return $0.isSuspicious }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let installed = BrowserKind.allCases.filter { browser in
                browser.bundleIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            }
            return BrowserExtensionScan(records: sorted, installedBrowsers: installed)
        }.value
    }

    static func isSuspicious(name: String) -> Bool {
        adwarePatterns.contains { name.localizedCaseInsensitiveContains($0) }
    }

    // MARK: Removal

    /// Moves a user-installed extension to the Trash, but only while its
    /// browser is closed and only from the browser's own extensions folder.
    static func remove(_ record: BrowserExtensionRecord) async -> RemovalOutcome {
        switch record.origin {
        case .safariApp:
            await MainActor.run { _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Safari-Settings")!) }
            return .openedSafariSettings
        case .policy:
            return .managedByPolicy(record.browser)
        case .component:
            return .builtIn(record.browser)
        case .user:
            break
        }
        guard record.browser != .safari else { return .openedSafariSettings }
        if await browserIsRunning(record) {
            await bringForward(record.browser)
            return .removeInBrowser(record.browser)
        }
        guard isSafeDeletionPath(record) else { return .refused }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: record.path), resultingItemURL: nil)
            return .trashed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Only `<profile>/Extensions/<32 a–p id>` (Chromium) or a direct child of
    /// `<profile>/extensions/` (Firefox) may ever be trashed.
    static func isSafeDeletionPath(_ record: BrowserExtensionRecord) -> Bool {
        guard !record.path.contains("/../") else { return false }
        let components = URL(fileURLWithPath: record.path).standardizedFileURL.pathComponents
        guard components.count >= 4 else { return false }
        let leaf = components[components.count - 1]
        let parent = components[components.count - 2]
        let profile = components[components.count - 3]
        guard profile == record.profile else { return false }
        switch record.browser {
        case .chrome, .brave, .edge, .arc:
            return parent == "Extensions" && leaf == record.identifier && isValidChromiumID(leaf)
        case .firefox:
            return parent == "extensions" && !leaf.isEmpty && leaf != "." && leaf != ".."
        case .safari:
            return false
        }
    }

    /// Chromium extension IDs are 32 characters from a to p.
    static func isValidChromiumID(_ id: String) -> Bool {
        id.count == 32 && id.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 112 }
    }

    /// Running if any of the browser's apps is open or its profile lock is held.
    private static func browserIsRunning(_ record: BrowserExtensionRecord) async -> Bool {
        let ids = record.browser.bundleIdentifiers
        let appRunning = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier.map(ids.contains) ?? false }
        }
        if appRunning { return true }
        switch record.browser {
        case .chrome, .brave, .edge, .arc:
            guard let relative = record.browser.chromiumUserDataRelativePath else { return true }
            return chromiumUserDataIsLocked(applicationSupport.appendingPathComponent(relative))
        case .firefox:
            return firefoxProfileIsLocked(firefoxProfilesRoot.appendingPathComponent(record.profile))
        case .safari:
            return false
        }
    }

    @MainActor
    private static func bringForward(_ browser: BrowserKind) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.primaryBundleIdentifier) else { return }
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// Chromium keeps a `SingletonLock` symlink while running. A stale link
    /// after a crash also reads as "in use", which errs on the safe side.
    static func chromiumUserDataIsLocked(_ userData: URL) -> Bool {
        var info = stat()
        return lstat(userData.appendingPathComponent("SingletonLock").path, &info) == 0
    }

    /// Firefox holds a POSIX lock on `.parentlock` while running. F_GETLK only
    /// asks; it never takes the lock.
    static func firefoxProfileIsLocked(_ profile: URL) -> Bool {
        let fd = open(profile.appendingPathComponent(".parentlock").path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var query = flock()
        query.l_type = Int16(F_WRLCK)
        query.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &query) == 0 else { return true }
        return query.l_type != Int16(F_UNLCK)
    }

    // MARK: Chromium

    private static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    private static func chromeFamily(_ browser: BrowserKind) -> [BrowserExtensionRecord] {
        guard let relative = browser.chromiumUserDataRelativePath else { return [] }
        let fileManager = FileManager.default
        let base = applicationSupport.appendingPathComponent(relative)
        guard let profiles = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let forced = forcedExtensionIDs(for: browser)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var records: [BrowserExtensionRecord] = []

        for profile in profiles {
            guard let extensionFolders = try? fileManager.contentsOfDirectory(
                at: profile.appendingPathComponent("Extensions"),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }
            let locations = preferenceLocations(in: profile)

            for folder in extensionFolders {
                let id = folder.lastPathComponent
                let values = try? folder.resourceValues(forKeys: Set(keys))
                guard isValidChromiumID(id), values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let versions = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
                    var isDirectory: ObjCBool = false
                    return !name.hasPrefix(".")
                        && fileManager.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }
                guard let version = newestVersionFolder(versions) else { continue }
                let versionURL = folder.appendingPathComponent(version)
                guard let manifest = try? Data(contentsOf: versionURL.appendingPathComponent("manifest.json")),
                      let name = chromiumName(manifest: manifest, versionURL: versionURL)
                else { continue }
                let displayName = name.isEmpty ? id : name
                records.append(BrowserExtensionRecord(
                    browser: browser,
                    profile: profile.lastPathComponent,
                    identifier: id,
                    name: displayName,
                    updatedAt: values?.contentModificationDate,
                    path: folder.path,
                    origin: chromiumOrigin(id: id, location: locations[id], forced: forced),
                    isSuspicious: isSuspicious(name: displayName)
                ))
            }
        }
        return records
    }

    /// The manifest name, resolving `__MSG_key__` through `_locales`.
    private static func chromiumName(manifest data: Data, versionURL: URL) -> String? {
        struct Manifest: Decodable {
            let name: String?
            let default_locale: String?
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        let name = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), name.count > 8 else { return name }
        let key = String(name.dropFirst(6).dropLast(2))
        var locales: [String] = []
        if let preferred = manifest.default_locale, !preferred.isEmpty { locales.append(preferred) }
        locales += ["en", "en_US", "en_GB"]
        for locale in NSOrderedSet(array: locales).compactMap({ $0 as? String }) {
            let url = versionURL.appendingPathComponent("_locales/\(locale)/messages.json")
            if let data = try? Data(contentsOf: url), let message = localizedMessage(key: key, from: data) {
                return message
            }
        }
        return ""
    }

    private static func localizedMessage(key: String, from data: Data) -> String? {
        struct Entry: Decodable { let message: String? }
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return nil }
        // Message keys are case-insensitive: files use "extname" for "__MSG_extName__".
        let message = entries[key]?.message
            ?? entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value.message
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Picks the newest version folder ("1.10.0_0" beats "1.9.0_0").
    static func newestVersionFolder(_ names: [String]) -> String? {
        func numbers(_ name: String) -> [Int] {
            name.split(whereSeparator: { $0 == "." || $0 == "_" }).map { Int($0) ?? 0 }
        }
        return names.max { lhs, rhs in
            let a = numbers(lhs), b = numbers(rhs)
            for index in 0..<max(a.count, b.count) {
                let x = index < a.count ? a[index] : 0
                let y = index < b.count ? b[index] : 0
                if x != y { return x < y }
            }
            return lhs < rhs
        }
    }

    /// `extensions.settings.<id>.location` from Preferences and Secure Preferences.
    private static func preferenceLocations(in profile: URL) -> [String: Int] {
        var merged: [String: Int] = [:]
        for file in ["Preferences", "Secure Preferences"] {
            guard let data = try? Data(contentsOf: profile.appendingPathComponent(file)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let extensions = root["extensions"] as? [String: Any],
                  let settings = extensions["settings"] as? [String: Any]
            else { continue }
            for (id, value) in settings {
                if let entry = value as? [String: Any], let location = entry["location"] as? Int {
                    merged[id] = location
                }
            }
        }
        return merged
    }

    /// Chromium's ManifestLocation: 5/10 ship with the browser, 7/9 come from policy.
    static func chromiumOrigin(id: String, location: Int?, forced: Set<String>) -> BrowserExtensionOrigin {
        if forced.contains(id.lowercased()) { return .policy }
        guard let location else { return .user }
        if [7, 9].contains(location) { return .policy }
        if [5, 10].contains(location) { return .component }
        return .user
    }

    /// `ExtensionInstallForcelist` from managed preferences, the usual way
    /// adware pins an extension.
    private static func forcedExtensionIDs(for browser: BrowserKind) -> Set<String> {
        guard let domain = browser.policyDomain else { return [] }
        let managed = URL(fileURLWithPath: "/Library/Managed Preferences")
        let candidates = [
            managed.appendingPathComponent("\(domain).plist"),
            managed.appendingPathComponent(NSUserName()).appendingPathComponent("\(domain).plist"),
        ]
        var ids = Set<String>()
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let list = plist["ExtensionInstallForcelist"] as? [String]
            else { continue }
            for entry in list {
                if let id = entry.split(separator: ";").first {
                    ids.insert(id.trimmingCharacters(in: .whitespaces).lowercased())
                }
            }
        }
        return ids
    }

    // MARK: Firefox

    private static var firefoxProfilesRoot: URL {
        applicationSupport.appendingPathComponent("Firefox/Profiles")
    }

    private static func firefox() -> [BrowserExtensionRecord] {
        guard let profiles = try? FileManager.default.contentsOfDirectory(at: firefoxProfilesRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return profiles.flatMap { profile -> [BrowserExtensionRecord] in
            guard let data = try? Data(contentsOf: profile.appendingPathComponent("extensions.json")) else { return [] }
            return firefoxRecords(json: data, profile: profile)
        }
    }

    static func firefoxRecords(json: Data, profile: URL) -> [BrowserExtensionRecord] {
        struct Payload: Decodable {
            struct Addon: Decodable {
                struct Locale: Decodable { let name: String? }
                let id: String
                let type: String?
                let defaultLocale: Locale?
                let installDate: Double?
                let updateDate: Double?
                let path: String?
                let location: String?
            }
            let addons: [Addon]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else { return [] }
        let profileURL = profile.standardizedFileURL
        let extensionsFolder = profileURL.appendingPathComponent("extensions").standardizedFileURL
        return payload.addons.compactMap { addon in
            // Only user-installed profile add-ons. Built-in, system and temporary
            // add-ons point into Firefox.app or a developer's folder.
            guard (addon.type ?? "extension") == "extension",
                  addon.location == "app-profile",
                  let rawPath = addon.path,
                  !rawPath.split(separator: "/").contains("..")
            else { return nil }
            let fileURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard fileURL.deletingLastPathComponent().pathComponents == extensionsFolder.pathComponents else { return nil }
            let name = addon.defaultLocale?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (name?.isEmpty == false ? name : nil) ?? addon.id
            return BrowserExtensionRecord(
                browser: .firefox,
                profile: profileURL.lastPathComponent,
                identifier: addon.id,
                name: displayName,
                updatedAt: (addon.updateDate ?? addon.installDate).map { Date(timeIntervalSince1970: $0 / 1000) },
                path: fileURL.path,
                origin: .user,
                isSuspicious: isSuspicious(name: displayName)
            )
        }
    }

    // MARK: Safari

    private static let safariExtensionPoints: Set<String> = [
        "com.apple.Safari.extension",
        "com.apple.Safari.content-blocker",
        "com.apple.Safari.web-extension",
    ]

    /// Third-party Safari extensions: app extensions inside installed apps.
    private static func safari() -> [BrowserExtensionRecord] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var records: [BrowserExtensionRecord] = []
        var seen = Set<String>()
        for root in roots {
            guard let apps = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for app in apps where app.pathExtension == "app" {
                let plugIns = app.appendingPathComponent("Contents/PlugIns")
                guard let appexes = try? fileManager.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for appex in appexes where appex.pathExtension.lowercased() == "appex" {
                    guard let data = try? Data(contentsOf: appex.appendingPathComponent("Contents/Info.plist")),
                          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          let point = (plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                          safariExtensionPoints.contains(point)
                    else { continue }
                    let bundleID = (plist["CFBundleIdentifier"] as? String) ?? appex.lastPathComponent
                    guard !bundleID.hasPrefix("com.apple."), seen.insert(bundleID).inserted else { continue }
                    let name = (plist["CFBundleDisplayName"] as? String)
                        ?? (plist["CFBundleName"] as? String)
                        ?? appex.deletingPathExtension().lastPathComponent
                    records.append(BrowserExtensionRecord(
                        browser: .safari,
                        profile: "",
                        identifier: bundleID,
                        name: name,
                        updatedAt: (try? appex.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                        path: appex.path,
                        origin: .safariApp,
                        isSuspicious: isSuspicious(name: name)
                    ))
                }
            }
        }
        return records
    }
}
