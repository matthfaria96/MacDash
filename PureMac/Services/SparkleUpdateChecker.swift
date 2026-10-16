// Portions adapted from Mac Sai (https://github.com/iliyami/MacSai)
// Copyright (c) 2026, Mac Sai Contributors. BSD 3-Clause License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation

/// An app that ships its own Sparkle updater and whose feed offers a newer version.
struct SparkleAppUpdate: Identifiable, Hashable, Sendable {
    let appURL: URL
    let name: String
    let bundleIdentifier: String
    let installedVersion: String
    let availableVersion: String
    let downloadURL: URL?
    let isMacAppStore: Bool
    /// Space the app takes on disk.
    var size: Int64 = 0
    /// When the app arrived on this Mac (the bundle's creation date).
    var installedAt: Date?
    /// When the installed copy last changed, usually its last update.
    var updatedAt: Date?
    var lastOpenedAt: Date?
    var developer: String?
    var category: String?
    var minimumSystem: String?
    /// Where the app looks for updates.
    var feedHost: String?

    var id: String { appURL.path }
}

/// Checks every installed app that publishes a Sparkle appcast (`SUFeedURL`)
/// and reports the ones with a newer version, the way Mac Sai's updater does.
@MainActor
final class SparkleUpdateChecker: ObservableObject {
    @Published private(set) var updates: [SparkleAppUpdate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    @Published private(set) var appsChecked = 0
    /// Apps with an update feed found for the current check.
    @Published private(set) var appsTotal = 0
    @Published private(set) var lastCheckedAt: Date?

    private var task: Task<Void, Never>?

    // MARK: Installing

    enum InstallState: Equatable {
        case queued
        case downloading(Double)
        case failed(String)
    }

    /// Per-app progress while updates install, by `SparkleAppUpdate.id`.
    @Published private(set) var installStates: [String: InstallState] = [:]
    @Published private(set) var isBatchRunning = false
    @Published private(set) var batchDone = 0
    @Published private(set) var batchTotal = 0
    @Published private(set) var installedCount = 0
    private var installTask: Task<Void, Never>?

    /// Updates that can be installed here (not App Store, a supported download).
    var installable: [SparkleAppUpdate] { updates.filter(SparkleInstaller.canInstall) }

    var isInstalling: Bool { installTask != nil }

    /// Installs one update, or falls back to the old behavior (download page,
    /// App Store or the app's own updater) when it can't be done here.
    func update(_ update: SparkleAppUpdate) {
        guard SparkleInstaller.canInstall(update) else { perform(update); return }
        guard installTask == nil else { return }
        installTask = Task { [weak self] in
            await self?.runInstall(update)
            self?.installTask = nil
        }
    }

    /// Installs every update that can be installed here, one after another.
    func updateAll() {
        guard installTask == nil else { return }
        let queue = installable
        guard !queue.isEmpty else { return }
        isBatchRunning = true
        batchDone = 0
        batchTotal = queue.count
        for item in queue { installStates[item.id] = .queued }
        installTask = Task { [weak self] in
            for item in queue {
                guard let self, !Task.isCancelled else { break }
                await self.runInstall(item)
                self.batchDone += 1
            }
            guard let self else { return }
            for item in queue where self.installStates[item.id] == .queued { self.installStates[item.id] = nil }
            self.isBatchRunning = false
            self.installTask = nil
        }
    }

    /// Stops after the app being installed right now finishes or is cancelled.
    func cancelInstalls() {
        installTask?.cancel()
        installTask = nil
        isBatchRunning = false
        for (id, state) in installStates where state == .queued || { if case .downloading = state { return true } else { return false } }() {
            installStates[id] = nil
        }
    }

    private func runInstall(_ item: SparkleAppUpdate) async {
        installStates[item.id] = .downloading(0)
        do {
            try await SparkleInstaller.install(item) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.installStates[item.id] else { return }
                    self.installStates[item.id] = .downloading(fraction)
                }
            }
            installStates[item.id] = nil
            updates.removeAll { $0.id == item.id }
            installedCount += 1
        } catch is CancellationError {
            installStates[item.id] = nil
        } catch {
            installStates[item.id] = .failed(error.localizedDescription)
        }
    }

    /// Starts a check. Each app's result is published as soon as its feed
    /// answers, so updates appear one by one instead of all at the end.
    func start() {
        guard !isChecking else { return }
        isChecking = true
        appsChecked = 0
        appsTotal = 0
        updates = []
        task = Task { [weak self] in
            let apps = await Task.detached(priority: .userInitiated) { Self.discoverFeedApps() }.value
            guard let self, !Task.isCancelled else { return }
            self.appsTotal = apps.count

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }

            // A few feeds at a time keeps it quick without flooding servers.
            await withTaskGroup(of: SparkleAppUpdate?.self) { group in
                var next = 0
                for _ in 0..<min(8, apps.count) {
                    let app = apps[next]
                    next += 1
                    group.addTask { await Self.checkApp(app, session: session) }
                }
                for await result in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    self.appsChecked += 1
                    if let result {
                        self.updates.append(result)
                        self.updates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    }
                    if next < apps.count {
                        let app = apps[next]
                        next += 1
                        group.addTask { await Self.checkApp(app, session: session) }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.hasChecked = true
            self.lastCheckedAt = Date()
            self.isChecking = false
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isChecking = false
    }

    func reset() {
        cancel()
        updates = []
        hasChecked = false
        appsChecked = 0
    }

    /// What the Update button does, chosen by how the app was installed.
    func perform(_ update: SparkleAppUpdate) {
        if update.isMacAppStore, let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        } else if let url = update.downloadURL, Self.isSafeURL(url) {
            // Opens in the browser, which shows its own download progress.
            NSWorkspace.shared.open(url)
        } else {
            // No usable download link: open the app so its own updater runs.
            NSWorkspace.shared.openApplication(at: update.appURL, configuration: .init())
        }
    }

    // MARK: Discovery

    private struct FeedApp: Sendable {
        let url: URL
        let name: String
        let bundleIdentifier: String
        let version: String
        let feedURL: URL
        var developer: String?
        var category: String?
        var minimumSystem: String?
    }

    nonisolated private static func discoverFeedApps() -> [FeedApp] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var seen = Set<String>()
        var apps: [FeedApp] = []
        for root in roots {
            guard let contents = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in contents where url.pathExtension == "app" {
                let path = url.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted else { continue }
                let plistURL = url.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plistURL),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let bundleID = plist["CFBundleIdentifier"] as? String,
                      !bundleID.hasPrefix("com.apple."),
                      let feed = (plist["SUFeedURL"] as? String).flatMap(URL.init(string:)),
                      isSafeURL(feed)
                else { continue }
                let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? "0"
                let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
                let category = (plist["LSApplicationCategoryType"] as? String).map(Self.categoryName)
                apps.append(FeedApp(
                    url: url, name: name, bundleIdentifier: bundleID, version: version, feedURL: feed,
                    developer: plist["NSHumanReadableCopyright"] as? String,
                    category: category,
                    minimumSystem: plist["LSMinimumSystemVersion"] as? String
                ))
            }
        }
        return apps
    }

    // MARK: Checking

    nonisolated private static func checkApp(_ app: FeedApp, session: URLSession) async -> SparkleAppUpdate? {
        guard let (data, response) = try? await session.data(from: app.feedURL),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400
        else { return nil }
        let latest = AppcastParser().parseLatestItem(from: data)
        guard let available = latest.version, isNewer(available, than: app.version) else { return nil }
        let isMAS = FileManager.default.fileExists(atPath: app.url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        var update = SparkleAppUpdate(
            appURL: app.url,
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            installedVersion: app.version,
            availableVersion: available,
            downloadURL: latest.downloadURL.flatMap { isSafeURL($0) ? $0 : nil },
            isMacAppStore: isMAS
        )
        // Details for the table and the info popover, only for apps that do
        // have an update.
        let values = try? app.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        update.installedAt = values?.creationDate
        update.updatedAt = values?.contentModificationDate
        update.size = FileSizeCalculator.size(of: app.url) ?? 0
        update.lastOpenedAt = UnusedAppsFinder.spotlightLastUsed(at: app.url)
        update.developer = app.developer
        update.category = app.category
        update.minimumSystem = app.minimumSystem
        update.feedHost = app.feedURL.host
        return update
    }

    /// "public.app-category.developer-tools" → "Developer Tools".
    nonisolated static func categoryName(_ type: String) -> String {
        type.replacingOccurrences(of: "public.app-category.", with: "")
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    // MARK: Rules

    /// Feeds and downloads must use https: a plain-http feed could be
    /// tampered with to point at a malicious download.
    nonisolated static func isSafeURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    /// Numeric comparison: "1.10.0" is newer than "1.9.0". Each component uses
    /// its leading digits, so "3 (456)" reads as 3; garbage never reads as newer.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let lhs = parts(candidate), rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Minimal Sparkle appcast parser. Keeps the highest marketing version
/// (`sparkle:shortVersionString`) across all items, falling back to the build
/// version only when no marketing version exists. Delta enclosures are ignored.
final class AppcastParser: NSObject, XMLParserDelegate {
    private static let shortVersionKey = "sparkle:shortVersionString"
    private static let buildVersionKey = "sparkle:version"

    private var bestShortVersion: String?
    private var bestShortDownloadURL: URL?
    private var bestBuildVersion: String?
    private var bestBuildDownloadURL: URL?
    private var inItem = false
    private var inDeltas = false
    private var currentDownloadURL: URL?
    private var currentAttributeShortVersion: String?
    private var currentAttributeBuildVersion: String?
    private var currentElementShortVersion: String?
    private var currentElementBuildVersion: String?
    private var capturingElement: String?
    private var capturedText = ""

    func parseLatestItem(from data: Data) -> (version: String?, downloadURL: URL?) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        let version = bestShortVersion ?? bestBuildVersion
        let url = bestShortVersion == nil ? bestBuildDownloadURL : bestShortDownloadURL
        return (version, url)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "item":
            inItem = true
            resetCurrentItem()
        case "sparkle:deltas" where inItem:
            inDeltas = true
        case "enclosure" where inItem && !inDeltas:
            if currentDownloadURL == nil { currentDownloadURL = attributes["url"].flatMap(URL.init(string:)) }
            if currentAttributeShortVersion == nil { currentAttributeShortVersion = attributes[Self.shortVersionKey] }
            if currentAttributeBuildVersion == nil { currentAttributeBuildVersion = attributes[Self.buildVersionKey] }
        case Self.shortVersionKey where inItem && !inDeltas,
             Self.buildVersionKey where inItem && !inDeltas:
            capturingElement = elementName
            capturedText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingElement != nil { capturedText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "sparkle:deltas":
            inDeltas = false
        case Self.shortVersionKey where capturingElement == elementName:
            currentElementShortVersion = trimmedCapture()
        case Self.buildVersionKey where capturingElement == elementName:
            currentElementBuildVersion = trimmedCapture()
        case "item":
            finishItem()
        default:
            break
        }
    }

    private func trimmedCapture() -> String? {
        let text = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
        capturingElement = nil
        capturedText = ""
        return text.isEmpty ? nil : text
    }

    private func finishItem() {
        inItem = false
        // Appcasts are not guaranteed newest-first, so compare every item.
        if let version = currentElementShortVersion ?? currentAttributeShortVersion,
           bestShortVersion.map({ SparkleUpdateChecker.isNewer(version, than: $0) }) ?? true {
            bestShortVersion = version
            bestShortDownloadURL = currentDownloadURL
        }
        if let version = currentElementBuildVersion ?? currentAttributeBuildVersion,
           bestBuildVersion.map({ SparkleUpdateChecker.isNewer(version, than: $0) }) ?? true {
            bestBuildVersion = version
            bestBuildDownloadURL = currentDownloadURL
        }
        resetCurrentItem()
    }

    private func resetCurrentItem() {
        inDeltas = false
        currentDownloadURL = nil
        currentAttributeShortVersion = nil
        currentAttributeBuildVersion = nil
        currentElementShortVersion = nil
        currentElementBuildVersion = nil
        capturingElement = nil
        capturedText = ""
    }
}
