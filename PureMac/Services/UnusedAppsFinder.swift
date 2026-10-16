// Detection rules adapted from Mac Sai (https://github.com/iliyami/MacSai)
// Copyright (c) 2026, Mac Sai Contributors. BSD 3-Clause License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import CoreServices
import Foundation

/// An installed app nobody has opened for a while, with everything that
/// belongs to it (the app plus its support files).
struct UnusedAppRecord: Identifiable, Hashable, Sendable {
    let appURL: URL
    let name: String
    let bundleIdentifier: String
    let lastUsed: Date
    let files: [URL]
    let totalSize: Int64

    var id: String { appURL.path }
}

enum UnusedAppsFinder {
    /// Months an app must sit unused before it is listed. The user picks the
    /// value in Settings › General.
    static let monthsKey = "cleanup.unusedAppsMonths"
    static let monthOptions = [3, 6, 12, 24, 48]

    static var configuredMonths: Int {
        let stored = UserDefaults.standard.integer(forKey: monthsKey)
        return monthOptions.contains(stored) ? stored : 6
    }

    /// Non-Apple apps whose Spotlight "last used" date is older than the
    /// cutoff, largest first. Apps running now, apps with no recorded last-used
    /// date (macOS can't prove they're idle) and MacFresh itself are
    /// never listed.
    static func find(olderThanMonths months: Int, runningPaths: Set<String>, now: Date = Date()) -> [UnusedAppRecord] {
        guard let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: now) else { return [] }
        let fileManager = FileManager.default
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        let locations = Locations()
        var seen = Set<String>()
        var records: [UnusedAppRecord] = []

        for root in roots {
            guard let contents = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in contents where url.pathExtension == "app" {
                if Task.isCancelled { return [] }
                let path = url.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted, !runningPaths.contains(path) else { continue }
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.hasPrefix("com.apple."),
                      bundleID != ownBundleID,
                      let lastUsed = spotlightLastUsed(at: url),
                      lastUsed <= cutoff
                else { continue }

                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let finder = AppPathFinder(
                    appInfo: AppPathFinder.AppInfo(appName: name, bundleIdentifier: bundleID, path: url, entitlements: nil, teamIdentifier: nil),
                    locations: locations
                )
                var files = Array(finder.findPaths())
                if !files.contains(url) { files.insert(url, at: 0) }
                let size = files.reduce(Int64(0)) { $0 + (FileSizeCalculator.size(of: $1) ?? 0) }
                records.append(UnusedAppRecord(
                    appURL: url,
                    name: name,
                    bundleIdentifier: bundleID,
                    lastUsed: lastUsed,
                    files: files,
                    totalSize: size
                ))
            }
        }
        return records.sorted { $0.totalSize > $1.totalSize }
    }

    /// The date macOS last recorded the app being opened. A bundle's file
    /// access date is not updated on launch, so it can't be used instead.
    static func spotlightLastUsed(at url: URL) -> Date? {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
