import SwiftUI
import Combine
import UserNotifications
import AppKit

// InstalledApp is defined in AppInfoFetcher.swift

enum AppSection: Hashable {
    case smartCare
    case protection
    case antivirus
    case apps
    case duplicates
    case similarPhotos
    case cleanup
    case spaceLens
    case processes
    case settings
}

extension Notification.Name {
    /// Posted by the Finder Services handler ("Uninstall with MacDash") with a
    /// `["path": String]` userInfo pointing at the right-clicked .app bundle.
    static let pureMacExternalUninstall = Notification.Name("MacDash.ExternalUninstall")
}

/// Cold-launch buffer for Finder Services. A "Uninstall with MacDash" request
/// can arrive before the SwiftUI scene (and thus AppState) exists; the posted
/// notification then has no subscriber and is lost (NotificationCenter has no
/// replay). AppDelegate stashes the path here and AppState drains it in init.
enum ExternalUninstallBuffer {
    // Written by the Finder Services handler and drained by AppState — both
    // run on the main thread, so a plain static is sufficient here.
    static var pendingPath: String?
}

/// Standalone observable for the live scan-path ticker. The scan engine reports
/// the filesystem path it is touching ~10×/sec. Routing that through AppState's
/// own `@Published` storage republished the *entire* view tree at that rate,
/// which surfaced as window-drag / button-hover lag and a Smart Scan that
/// looked frozen until you switched sidebar sections and forced a fresh render
/// (issues #119, #120). Isolating the high-frequency value here means only the
/// small ticker label observes it, so the rest of the UI stays still.
@MainActor
final class ScanProgressTicker: ObservableObject {
    @Published var path: String = ""
}

@MainActor
final class AppState: ObservableObject {
    let languageAtLaunch = AppLanguage.current
    @Published var settingsNeedLanguageRestart = false
    @Published var showUpdateSettings = false
    typealias AppFileScanner = @MainActor (
        _ app: InstalledApp,
        _ locations: Locations,
        _ completion: @escaping (Set<URL>) -> Void
    ) -> Void
    typealias AppFileTrasher = @MainActor (
        _ urls: [URL],
        _ completion: @escaping ([URL], Bool, [URL], [URL]) -> Void
    ) -> Void

    // MARK: - Scan / Clean State

    @Published var selectedCategory: CleaningCategory = .smartScan
    @Published var scanState: ScanState = .idle
    @Published var categoryResults: [CleaningCategory: CategoryResult] = [:]
    @Published var diskInfo = DiskInfo()
    @Published var totalJunkSize: Int64 = 0
    @Published var totalFreedSpace: Int64 = 0
    @Published var scanProgress: Double = 0
    @Published var scanWasCancelled = false
    /// Saved for the menu bar's recommendation, which outlives this object.
    static let lastScanDefaultsKey = "MacTidy.lastScanDate"
    static let lastCleanDefaultsKey = "MacTidy.lastCleanDate"
    @Published var lastScanDate: Date? {
        didSet { if let lastScanDate { UserDefaults.standard.set(lastScanDate, forKey: Self.lastScanDefaultsKey) } }
    }
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var cleanupGeneration = UUID()
    @Published var cleanProgress: Double = 0
    @Published var currentScanCategory: String = ""
    /// Live filesystem path the scan engine is touching, feeding the dashboard's
    /// ticker. Deliberately NOT a `@Published` on AppState — it updates ~10×/sec
    /// and would otherwise invalidate the whole view tree (issues #119, #120).
    /// Only the ticker label observes this object directly.
    let scanTicker = ScanProgressTicker()
    @Published var showCleanConfirmation = false
    @Published var lastCleanedDate: Date? {
        didSet { if let lastCleanedDate { UserDefaults.standard.set(lastCleanedDate, forKey: Self.lastCleanDefaultsKey) } }
    }
    @Published var selectedCleanupItems: Set<UUID> = []
    @Published var deselectedItems: Set<UUID> = []
    @Published var hasFullDiskAccess: Bool = true
    @Published var fdaBannerDismissed: Bool = false
    @Published var cleanError: String?
    @Published private(set) var lastCleanupHadFailures = false
    /// True when the most recent clean error is rooted in a TCC/FDA refusal
    /// (i.e. items survived even the admin pass). MainWindow uses this to
    /// route the user into the PermissionSheet instead of the generic alert.
    @Published var cleanErrorIsFDAFixable: Bool = false
    /// Items that survived the most recent clean attempt — used to re-run the
    /// operation after the user grants Full Disk Access without forcing them
    /// to re-select anything.
    @Published var pendingPermissionRetryItems: [CleanableItem] = []

    // MARK: - App Uninstaller State

    @Published var installedApps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp?
    @Published var discoveredFiles: [URL] = []
    /// Sizes the app files view has measured, so removals can report the
    /// space they freed.
    var appFileSizeHints: [URL: Int64] = [:]
    @Published var selectedFiles: Set<URL> = []
    @Published var orphanedFiles: [URL] = []
    @Published var isSearchingOrphans: Bool = false
    @Published var hasSearchedOrphans: Bool = false
    /// Sizes measured off the main thread when an orphan scan finishes.
    @Published private(set) var orphanSizes: [URL: Int64] = [:]
    @Published var selectedOrphans: Set<URL> = []
    @Published private(set) var isRemovingOrphans = false
    /// Which Applications tab is showing (uninstall, startup items, updates).
    @Published var applicationsTab: ApplicationsTab = .uninstall
    /// Search text for the app list; the field lives in the window toolbar.
    @Published var appSearchText = ""
    /// Which Protection tab is showing (security, permissions, extensions, Wi-Fi).
    @Published var protectionTab: ProtectionTab = .permissions
    /// True while General Cleanup shows its scan and results instead of the overview.
    @Published var cleanupDetailOpen = false
    /// The screen that started the current scan.
    @Published private(set) var scanScope: ScanScope = .smartCare
    @Published var isLoadingApps: Bool = false
    @Published var isScanningAppFiles: Bool = false
    @Published var isRemovingAppFiles = false
    @Published var removalError: String?
    @Published var removalNeedsFullDiskAccess = false
    /// Snapshot of the URLs that failed the most recent uninstall due to a
    /// permission denial. Frozen at finishRemoval time so AppFilesView's
    /// retry path operates on the failed batch even if the user clicks a
    /// different app or mutates selection while the FDA sheet is open.
    @Published var lastFailedRemovalURLs: [URL] = []
    @Published var appFileScanLocationCount: Int = 0
    /// Set when a right-clicked app arrives via the Finder Services handler.
    /// MainWindow consumes it on both onChange AND onAppear so a request that
    /// lands before MainWindow mounts (cold launch, or while onboarding is
    /// still showing) is still surfaced — a one-shot token would be missed.
    @Published var pendingExternalApp: InstalledApp?

    private var externalUninstallObserver: AnyCancellable?
    private var appFileScanGeneration = UUID()
    private var orphanScanTask: Task<Void, Never>?
    private var orphanScanGeneration = UUID()

    // MARK: - Services

    var scheduler = SchedulerService()
    private let scanEngine = ScanEngine()
    private let cleaningEngine = CleaningEngine()
    private let locationsProvider: () -> Locations
    private let appFileScanner: AppFileScanner
    private let appFileTrasher: AppFileTrasher

    // MARK: - Computed

    var totalItemCount: Int {
        categoryResults.values.reduce(0) { $0 + $1.itemCount }
    }

    var currentCategoryResult: CategoryResult? {
        categoryResults[selectedCategory]
    }

    /// Smart Care's own slice of the results; Advanced Cleanup areas never count here.
    var smartCareResults: [CategoryResult] {
        CleaningCategory.smartCare.compactMap { categoryResults[$0] }.filter { $0.totalSize > 0 }
    }

    var smartCareJunkSize: Int64 {
        CleaningCategory.smartCare.reduce(0) { $0 + (categoryResults[$1]?.totalSize ?? 0) }
    }

    var smartCareSelectedSize: Int64 {
        smartCareResults.flatMap(\.items).filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    /// Clears Smart Care's categories only, leaving Advanced Cleanup untouched.
    private func clearSmartCareResults() {
        for category in CleaningCategory.smartCare {
            clearSelectionState(for: category)
            categoryResults[category] = nil
        }
        totalJunkSize = smartCareJunkSize
    }

    var allResults: [CategoryResult] {
        CleaningCategory.scannable.compactMap { categoryResults[$0] }.filter { $0.totalSize > 0 }
    }

    var totalSelectedSize: Int64 {
        allResults.flatMap { $0.items }.filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    var currentAppFileSearchLocationCount: Int {
        if isScanningAppFiles && appFileScanLocationCount > 0 {
            return appFileScanLocationCount
        }
        return discoveredFiles.count
    }

    // MARK: - Init

    init(
        performStartupTasks: Bool = true,
        locationsProvider: @escaping () -> Locations = Locations.init,
        appFileScanner: @escaping AppFileScanner = AppState.defaultAppFileScanner,
        appFileTrasher: @escaping AppFileTrasher = AppState.defaultAppFileTrasher
    ) {
        self.locationsProvider = locationsProvider
        self.appFileScanner = appFileScanner
        self.appFileTrasher = appFileTrasher

        // Listen for right-click "Uninstall with MacDash" hand-offs from the
        // Finder Services handler in AppDelegate.
        externalUninstallObserver = NotificationCenter.default
            .publisher(for: .pureMacExternalUninstall)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let path = (note.userInfo?["path"] as? String) ?? ExternalUninstallBuffer.pendingPath
                ExternalUninstallBuffer.pendingPath = nil
                guard let path else { return }
                Task { @MainActor in self?.presentExternalUninstall(appPath: path) }
            }
        // Drain a request that arrived before this AppState existed (cold launch
        // via Finder Services — the notification fired with no subscriber).
        if let buffered = ExternalUninstallBuffer.pendingPath {
            ExternalUninstallBuffer.pendingPath = nil
            presentExternalUninstall(appPath: buffered)
        }

        if DemoMode.isActive {
            loadDiskInfo()
            loadInstalledApps()
            if let scope = DemoMode.initialResults { applyDemoResults(scope) }
        } else if performStartupTasks {
            loadDiskInfo()
            checkFullDiskAccess()
            loadInstalledApps()
            scheduler.setTrigger { [weak self] in
                await self?.runScheduledScan()
            }
            // Only arm the scheduler once onboarding has completed. Before
            // the first launch the defaults plist may have been
            // attacker-planted with autoClean=true; wait for human consent
            // via onboarding.
            if UserDefaults.standard.bool(forKey: "MacDash.OnboardingComplete") {
                scheduler.start()
            }
        }
    }

    // MARK: - App Loading

    func loadInstalledApps() {
        if DemoMode.isActive { installedApps = DemoMode.installedApps(); return }

        isLoadingApps = true
        Task.detached(priority: .userInitiated) {
            let apps = AppInfoFetcher.shared.fetchInstalledApps()
            await MainActor.run { [weak self] in
                self?.installedApps = apps
                self?.isLoadingApps = false
            }
        }
    }

    /// Resolve a right-clicked .app (via the Finder Services handler) into the
    /// uninstaller: select it, kick off the related-files scan, and signal
    /// MainWindow to surface the Installed Apps section.
    func presentExternalUninstall(appPath: String) {
        let url = URL(fileURLWithPath: appPath)
        if let cached = installedApps.first(where: { $0.path.standardizedFileURL == url.standardizedFileURL }) {
            applyExternalUninstall(cached)
            return
        }
        // Not in the cached list (non-standard location, or a cold start before
        // loadInstalledApps finished). Resolve off the main thread — fetchApp
        // walks the entire bundle to size it, which would beachball the UI for
        // a multi-gigabyte app.
        Task.detached(priority: .userInitiated) {
            let app = AppInfoFetcher.shared.fetchApp(at: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let app else {
                    Logger.shared.log("Finder uninstall request rejected (non-app or protected): \(appPath)", level: .warning)
                    return
                }
                self.applyExternalUninstall(app)
            }
        }
    }

    private func applyExternalUninstall(_ app: InstalledApp) {
        selectedApp = app
        pendingExternalApp = app
        scanForAppFiles(app)
    }

    func scanForAppFiles(_ app: InstalledApp) {
        guard !DemoMode.isActive else { return }  // demo: never touch the Mac

        discoveredFiles = []
        selectedFiles = []
        isScanningAppFiles = true
        let locations = locationsProvider()
        appFileScanLocationCount = locations.appSearch.paths.count
        let generation = UUID()
        appFileScanGeneration = generation
        appFileScanner(app, locations) { [weak self] urls in
            guard let self, self.appFileScanGeneration == generation else { return }
            let sorted = urls.sorted { $0.path < $1.path }
            self.discoveredFiles = sorted
            self.selectedFiles = urls
            self.isScanningAppFiles = false
            self.appFileScanLocationCount = 0
        }
    }

    /// Stops any related-file scan and closes the selected app, returning the
    /// Applications screen to its "Select an app" state.
    func closeSelectedApp() {
        guard !isRemovingAppFiles else { return }
        appFileScanGeneration = UUID()
        isScanningAppFiles = false
        appFileScanLocationCount = 0
        discoveredFiles = []
        selectedFiles = []
        selectedApp = nil
    }

    func removeSelectedFiles(confirmedURLs: Set<URL>? = nil) {
        guard !DemoMode.isActive else { return }  // demo: never touch the Mac

        // Re-entrance guard: if a previous removal is still resolving and
        // the FDA sheet/retry hasn't finished, a second call would race-
        // overwrite `lastFailedRemovalURLs` before the first batch's retry
        // closure read it. We can't gate on `removalNeedsFullDiskAccess`
        // alone — AppFilesView clears that flag the moment it hands off to
        // the coordinator, leaving a window where a second remove call
        // would pass the guard while the coordinator is still polling.
        // PermissionCoordinator.isRequesting covers the full sheet-open +
        // retry-pending span.
        guard !isRemovingAppFiles, !removalNeedsFullDiskAccess,
              !PermissionCoordinator.shared.isRequesting else {
            Logger.shared.log("Refused duplicate removeSelectedFiles while FDA flow is active", level: .info)
            return
        }
        // Safety guard: never allow a high-risk home dotpath (listed in
        // Conditions.swift) to be trashed no matter how it ended up in the
        // selection. Catches selection-time additions that slipped past the
        // scanner-side filters.
        let allURLs = Array(confirmedURLs ?? selectedFiles)
        let (urls, blocked): ([URL], [URL]) = allURLs.reduce(into: ([], [])) { acc, url in
            let resolved = url.resolvingSymlinksInPath().path
            let isBlocked = highRiskHomeDotPaths.contains { root in
                resolved == root || resolved.hasPrefix(root + "/")
            }
            if isBlocked {
                acc.1.append(url)
            } else {
                acc.0.append(url)
            }
        }
        removalError = nil
        removalNeedsFullDiskAccess = false
        if !blocked.isEmpty {
            let blockedList = blocked.map(\.path).joined(separator: ", ")
            Logger.shared.log("Refused to delete \(blocked.count) high-risk home dotpath(s): \(blockedList)", level: .warning)
            selectedFiles.subtract(blocked)
        }
        guard !urls.isEmpty else {
            if !blocked.isEmpty {
                removalError = String(localized: "Refused to delete \(blocked.count) protected item(s) (home credential directory or similar).")
            }
            return
        }
        isRemovingAppFiles = true
        appFileTrasher(urls) { [weak self] removed, needsFullDiskAccess, needsAdmin, failed in
            Task { @MainActor in
                guard let self else { return }

                self.applyRemovedAppFiles(removed)

                guard !needsAdmin.isEmpty else {
                    self.finishRemoval(
                        removedAny: !removed.isEmpty,
                        needsFullDiskAccess: needsFullDiskAccess,
                        attemptedAdmin: false,
                        failed: failed,
                        adminError: nil
                    )
                    return
                }

                let items = needsAdmin.map { self.cleanableUninstallItem(for: $0) }
                let adminResult = await self.cleaningEngine.cleanWithAdminPrivileges(items: items)
                let adminRemoved = needsAdmin.filter { adminResult.cleanedPaths.contains($0.path) }
                let adminFailed = needsAdmin.filter { !adminResult.cleanedPaths.contains($0.path) }

                self.applyRemovedAppFiles(adminRemoved)
                for url in adminRemoved {
                    Logger.shared.log("Removed \(url.path) with administrator privileges", level: .info)
                }

                self.finishRemoval(
                    removedAny: !removed.isEmpty || !adminRemoved.isEmpty,
                    needsFullDiskAccess: needsFullDiskAccess,
                    attemptedAdmin: true,
                    failed: failed + adminFailed,
                    adminError: adminResult.errors.joined(separator: "; ")
                )
            }
        }
    }

    /// Move files to the Trash via FileManager.trashItem so the syscall
    /// originates from MacDash itself - TCC then registers MacDash in the
    /// Full Disk Access list. The previous AppleScript-via-Finder bridge
    /// caused the syscall to originate from Finder, which is why granting
    /// FDA to MacDash made no difference (issue #75).
    private static func defaultAppFileTrasher(urls: [URL], completion: @escaping ([URL], Bool, [URL], [URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let hasFullDiskAccess = FullDiskAccessManager.shared.hasFullDiskAccess
            var removed: [URL] = []
            var needsFullDiskAccess = false
            var needsAdmin: [URL] = []
            var failed: [URL] = []

            for url in urls {
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                    removed.append(url)
                } catch {
                    let nsError = error as NSError
                    if Self.isMissingFileError(nsError) {
                        Logger.shared.log("Trash skipped for \(url.path): file no longer exists", level: .info)
                        removed.append(url)
                    } else if Self.isPermissionDeniedError(nsError) {
                        if hasFullDiskAccess || Self.isLikelyAdministratorRemovalPath(url) {
                            needsAdmin.append(url)
                        } else {
                            needsFullDiskAccess = true
                            failed.append(url)
                        }
                    } else {
                        Logger.shared.log("Trash failed for \(url.path): \(error.localizedDescription)", level: .error)
                        failed.append(url)
                    }
                }
            }
            completion(removed, needsFullDiskAccess, needsAdmin, failed)
        }
    }

    private func applyRemovedAppFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Animate the row sweep-out (AppFilesView attaches the per-row
        // transitions). NSWorkspace is the Reduce Motion check available
        // outside a View's Environment.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            discoveredFiles.removeAll { urls.contains($0) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                discoveredFiles.removeAll { urls.contains($0) }
            }
        }
        selectedFiles.subtract(urls)
        UsageStats.shared.recordCleanup(.uninstall, bytes: urls.reduce(0) { $0 + (appFileSizeHints[$1] ?? 0) })
        Logger.shared.log("Removed \(urls.count) file\(urls.count == 1 ? "" : "s")", level: .info)
    }

    private func finishRemoval(
        removedAny: Bool,
        needsFullDiskAccess: Bool,
        attemptedAdmin: Bool,
        failed: [URL],
        adminError: String?
    ) {
        // Freeze the failed batch before the FDA sheet opens so the retry
        // path can't be poisoned by later selection edits or app switches.
        isRemovingAppFiles = false
        lastFailedRemovalURLs = needsFullDiskAccess ? failed : []
        removalNeedsFullDiskAccess = needsFullDiskAccess
        if let message = removalFailureMessage(
            needsFullDiskAccess: needsFullDiskAccess,
            attemptedAdmin: attemptedAdmin,
            failed: failed,
            adminError: adminError
        ) {
            removalError = message
            Logger.shared.log(message, level: .error)
        }
        if removedAny {
            pruneMissingInstalledApps()
        }
    }

    /// Public bridge so views (e.g. AppFilesView) can build CleanableItem rows
    /// from raw URLs when retrying via the PermissionCoordinator.
    func makeUninstallCleanableItem(for url: URL) -> CleanableItem {
        cleanableUninstallItem(for: url)
    }

    private func cleanableUninstallItem(for url: URL) -> CleanableItem {
        let values = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .contentModificationDateKey,
        ])
        let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        return CleanableItem(
            name: url.lastPathComponent,
            path: url.path,
            size: size,
            category: .systemJunk,
            isSelected: true,
            lastModified: values?.contentModificationDate
        )
    }

    private func removalFailureMessage(
        needsFullDiskAccess: Bool,
        attemptedAdmin: Bool,
        failed: [URL],
        adminError: String?
    ) -> String? {
        if needsFullDiskAccess {
            let prefix = failed.isEmpty ? String(localized: "Some selected files") : Self.fileCountLabel(failed.count)
            return String(localized: "\(prefix) could not be removed because MacDash does not have Full Disk Access. Grant Full Disk Access in System Settings, then try again.")
        }

        if !failed.isEmpty {
            if attemptedAdmin {
                return String(localized: "\(Self.fileCountLabel(failed.count)) could not be removed with administrator privileges. The items may have changed or macOS denied access.")
            }
            return String(localized: "\(Self.fileCountLabel(failed.count)) could not be removed. Check that the items still exist and are not in use.")
        }

        if let adminError, !adminError.isEmpty {
            return String(localized: "Administrator removal failed: \(adminError)")
        }
        return nil
    }

    private static func fileCountLabel(_ count: Int) -> String {
        count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    private nonisolated static func isMissingFileError(_ nsError: NSError) -> Bool {
        (nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)) ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
    }

    private nonisolated static func isPermissionDeniedError(_ nsError: NSError) -> Bool {
        (nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError)) ||
            (nsError.domain == NSPOSIXErrorDomain &&
                (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)))
    }

    private nonisolated static func isLikelyAdministratorRemovalPath(_ url: URL) -> Bool {
        let path = (url.resolvingSymlinksInPath().path as NSString).standardizingPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return hasAppBundleComponent(path, rootedAt: "/Applications")
            || hasAppBundleComponent(path, rootedAt: "\(home)/Applications")
            || isDirectFile(path, in: "/private/var/db/receipts", extensions: ["plist", "bom"])
            || isDirectFile(path, in: "/var/db/receipts", extensions: ["plist", "bom"])
            || isDirectFile(path, in: "/Library/LaunchDaemons", extensions: ["plist"])
            || isDirectFile(path, in: "/Library/LaunchAgents", extensions: ["plist"])
    }

    private nonisolated static func hasAppBundleComponent(_ path: String, rootedAt root: String) -> Bool {
        let normalizedRoot = (root as NSString).standardizingPath
        guard path != normalizedRoot else { return false }
        let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard path.hasPrefix(rootWithSeparator) else { return false }
        let relative = String(path.dropFirst(rootWithSeparator.count))
        return relative.split(separator: "/").contains { component in
            component.lowercased().hasSuffix(".app")
        }
    }

    private nonisolated static func isDirectFile(_ path: String, in root: String, extensions: Set<String>) -> Bool {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath
        guard parent == (root as NSString).standardizingPath else { return false }
        return extensions.contains((path as NSString).pathExtension.lowercased())
    }

    private func pruneMissingInstalledApps() {
        let fileManager = FileManager.default
        installedApps.removeAll { !fileManager.fileExists(atPath: $0.path.path) }

        if let selectedApp, !fileManager.fileExists(atPath: selectedApp.path.path) {
            self.selectedApp = nil
            discoveredFiles = []
            selectedFiles = []
        }
    }

    func findOrphans() {
        guard !DemoMode.isActive else { return }  // demo: never touch the Mac

        orphanScanTask?.cancel()
        orphanScanGeneration = UUID()
        let generation = orphanScanGeneration
        isSearchingOrphans = true
        hasSearchedOrphans = false
        orphanedFiles = []
        orphanSizes = [:]
        selectedOrphans = []
        orphanScanTask = Task.detached(priority: .userInitiated) {
            let locations = Locations()
            let knownApps = await MainActor.run { self.installedApps }
            let knownIDs = Set(knownApps.map { $0.bundleIdentifier.normalizedForMatching() })
            let knownNames = Set(knownApps.map { $0.appName.normalizedForMatching() })
            // Paths the user marked "Always Ignore" (issue #114). These were
            // false positives for them, so they stay hidden from every scan
            // until the user forgets the list in Settings.
            let ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey) ?? [])

            var orphans: [URL] = []
            let fm = FileManager.default

            for path in locations.reverseSearch.paths {
                guard !Task.isCancelled else { return }
                guard let contents = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for item in contents {
                    guard !Task.isCancelled else { return }
                    let normalized = item.normalizedForMatching()

                    // Skip known system items
                    if skipReverse.contains(where: { normalized.hasPrefix($0) }) { continue }

                    // Check if this item belongs to any known app
                    let belongsToApp = knownIDs.contains(where: { normalized.contains($0) }) ||
                                       knownNames.contains(where: { normalized.contains($0) })

                    if !belongsToApp {
                        let fullPath = URL(fileURLWithPath: path).appendingPathComponent(item)
                        if ignored.contains(fullPath.path) { continue }
                        if OrphanSafetyPolicy.isSafeCandidate(fullPath) {
                            orphans.append(fullPath)
                        }
                    }
                }
            }

            let sorted = orphans.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var sizes: [URL: Int64] = [:]
            for url in sorted {
                guard !Task.isCancelled else { return }
                sizes[url] = FileSizeCalculator.size(of: url) ?? 0
            }
            await MainActor.run { [weak self] in
                guard let self, self.orphanScanGeneration == generation else { return }
                self.orphanSizes = sizes
                self.orphanedFiles = sorted
                self.hasSearchedOrphans = true
                self.isSearchingOrphans = false
                self.orphanScanTask = nil
            }
        }
    }

    func cancelOrphanScan() {
        orphanScanGeneration = UUID()
        orphanScanTask?.cancel()
        orphanScanTask = nil
        isSearchingOrphans = false
        hasSearchedOrphans = false
        orphanedFiles = []
        orphanSizes = [:]
        selectedOrphans = []
    }

    var totalOrphanSize: Int64 {
        orphanedFiles.reduce(0) { $0 + (orphanSizes[$1] ?? 0) }
    }

    var selectedOrphanSize: Int64 {
        selectedOrphans.reduce(0) { $0 + (orphanSizes[$1] ?? 0) }
    }

    // MARK: - Orphan ignore list (#114)

    static let ignoredOrphansKey = "settings.orphans.ignored"

    /// Number of paths currently on the "always ignore" list. Read from
    /// UserDefaults each access so the Settings row tracks live changes.
    var ignoredOrphanCount: Int {
        UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey)?.count ?? 0
    }

    /// Permanently hide the given orphans from future scans and sweep them out
    /// of the current results.
    func ignoreOrphans(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey) ?? [])
        for url in urls { ignored.insert(url.path) }
        UserDefaults.standard.set(Array(ignored), forKey: Self.ignoredOrphansKey)

        let urlSet = Set(urls)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            orphanedFiles.removeAll { urlSet.contains($0) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                orphanedFiles.removeAll { urlSet.contains($0) }
            }
        }
        selectedOrphans.subtract(urlSet)
        for url in urlSet { orphanSizes[url] = nil }
        Logger.shared.log("Ignoring \(urls.count) orphan(s) in future scans", level: .info)
    }

    /// Moves the given orphans to the Trash, asking for administrator rights
    /// only for items that need them. Returns a message when some items fail.
    func removeOrphans(_ batch: Set<URL>) async -> String? {
        guard !DemoMode.isActive else { return nil }  // demo: never touch the Mac

        guard !isRemovingOrphans, !batch.isEmpty else { return nil }
        isRemovingOrphans = true
        defer { isRemovingOrphans = false }

        var failedPaths: [String] = []
        var removedURLs: Set<URL> = []
        var needsAdminURLs: [URL] = []

        for url in batch {
            guard OrphanSafetyPolicy.isSafeCandidate(url) else {
                failedPaths.append("\(url.path) (\(String(localized: "blocked by safety policy")))")
                continue
            }
            let outcome = await Task.detached(priority: .userInitiated) { Self.removeOrphan(url) }.value
            switch outcome {
            case .removed: removedURLs.insert(url)
            case .needsAdmin: needsAdminURLs.append(url)
            case .failed: failedPaths.append(url.path)
            }
        }

        if !needsAdminURLs.isEmpty {
            let adminURLs = needsAdminURLs
            let adminSucceeded = await Task.detached(priority: .userInitiated) { Self.removeWithAdminPrivileges(adminURLs) }.value
            for url in needsAdminURLs {
                if adminSucceeded && !FileManager.default.fileExists(atPath: url.path) {
                    removedURLs.insert(url)
                } else {
                    failedPaths.append(url.path)
                }
            }
        }

        orphanedFiles.removeAll { removedURLs.contains($0) }
        selectedOrphans.subtract(removedURLs)
        for url in removedURLs { orphanSizes[url] = nil }

        guard !failedPaths.isEmpty else { return nil }
        let preview = failedPaths.prefix(3).joined(separator: "\n")
        let suffix = failedPaths.count > 3 ? "\n…" : ""
        return String(
            format: String(localized: "%lld item(s) failed to delete.\n\n%@"),
            Int64(failedPaths.count),
            preview + suffix
        )
    }

    private enum OrphanRemoveOutcome: Sendable {
        case removed
        case needsAdmin
        case failed
    }

    private nonisolated static func removeOrphan(_ url: URL) -> OrphanRemoveOutcome {
        guard OrphanSafetyPolicy.isSafeCandidate(url) else { return .failed }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return .removed
        } catch {
            let nsError = error as NSError
            let permissionDeniedCodes = [
                NSFileReadNoPermissionError,
                NSFileWriteNoPermissionError,
                NSFileWriteUnknownError,
                257,
                513,
            ]

            guard permissionDeniedCodes.contains(nsError.code) else {
                return .failed
            }

            return .needsAdmin
        }
    }

    private nonisolated static func removeWithAdminPrivileges(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return true }
        guard urls.allSatisfy({ OrphanSafetyPolicy.isSafeCandidate($0) }) else { return false }

        // Quote path for a POSIX shell command.
        let quotedPaths = urls.map { url in
            "'\(url.path.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
        }
        let shellCommand = "rm -rf -- \(quotedPaths.joined(separator: " "))"
        let appleScriptCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptCommand)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Forget every ignored path so they can surface again on the next scan.
    func clearIgnoredOrphans() {
        UserDefaults.standard.removeObject(forKey: Self.ignoredOrphansKey)
        objectWillChange.send()
    }

    var excludedCleanupPaths: [String] {
        CleanupExclusions.paths()
    }

    func excludeFromCleanup(_ item: CleanableItem) {
        guard !item.isActionItem, !scanState.isActive else { return }
        CleanupExclusions.add(item.path)
        for (category, result) in categoryResults {
            categoryResults[category] = applyingCleanupExclusions(to: result)
        }
        totalJunkSize = smartCareJunkSize
    }

    func removeCleanupExclusion(_ path: String) {
        UserDefaults.standard.set(excludedCleanupPaths.filter { $0 != path }, forKey: CleanupExclusions.defaultsKey)
        objectWillChange.send()
    }

    private func applyingCleanupExclusions(to result: CategoryResult) -> CategoryResult {
        let excluded = excludedCleanupPaths
        guard !excluded.isEmpty else { return result }
        let items = result.items.filter { !CleanupExclusions.excludes($0.path, paths: excluded) }
        return CategoryResult(category: result.category, items: items, totalSize: items.reduce(0) { $0 + $1.size })
    }

    func setSelection(_ selected: Bool, for items: [CleanableItem]) {
        guard !scanState.isActive else { return }
        for item in items where isItemSelected(item) != selected {
            toggleItem(item)
        }
    }

    // MARK: - Selection

    func isItemSelected(_ item: CleanableItem) -> Bool {
        if item.isSelected {
            return !deselectedItems.contains(item.id)
        }
        return selectedCleanupItems.contains(item.id)
    }

    func toggleItem(_ item: CleanableItem) {
        if isItemSelected(item) {
            if item.isSelected {
                deselectedItems.insert(item.id)
            } else {
                selectedCleanupItems.remove(item.id)
            }
        } else {
            if item.isSelected {
                deselectedItems.remove(item.id)
            } else {
                selectedCleanupItems.insert(item.id)
            }
        }
    }

    func selectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            if item.isSelected {
                deselectedItems.remove(item.id)
            } else {
                selectedCleanupItems.insert(item.id)
            }
        }
    }

    func deselectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            if item.isSelected {
                deselectedItems.insert(item.id)
            } else {
                selectedCleanupItems.remove(item.id)
            }
        }
    }

    func selectedSizeInCategory(_ category: CleaningCategory) -> Int64 {
        guard let result = categoryResults[category] else { return 0 }
        return result.items.filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    func selectedCountInCategory(_ category: CleaningCategory) -> Int {
        guard let result = categoryResults[category] else { return 0 }
        return result.items.filter { isItemSelected($0) }.count
    }

    // MARK: - Helper Methods

    func categorySize(for category: CleaningCategory) -> String {
        guard let result = categoryResults[category], result.totalSize > 0 else { return "" }
        return result.formattedSize
    }

    func categoryBinding(for category: CleaningCategory) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                guard let self else { return false }
                return self.selectedCountInCategory(category) > 0
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if newValue {
                    self.selectAllInCategory(category)
                } else {
                    self.deselectAllInCategory(category)
                }
            }
        )
    }

    func itemBinding(for item: CleanableItem) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                self?.isItemSelected(item) ?? false
            },
            set: { [weak self] _ in
                self?.toggleItem(item)
            }
        )
    }

    private func clearSelectionState() {
        selectedCleanupItems.removeAll()
        deselectedItems.removeAll()
    }

    private func clearSelectionState(for category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            selectedCleanupItems.remove(item.id)
            deselectedItems.remove(item.id)
        }
    }

    // MARK: - Full Disk Access

    func checkFullDiskAccess() {
        Task.detached {
            let granted = FullDiskAccessManager.shared.hasFullDiskAccess
            await MainActor.run { [weak self] in
                self?.hasFullDiskAccess = granted
            }
        }
    }

    func openFullDiskAccessSettings() {
        FullDiskAccessManager.shared.openFullDiskAccessSettings()
    }

    /// Request Full Disk Access via the rich PermissionCoordinator sheet and
    /// retry the supplied items once the user grants permission. Used by both
    /// the cleanup and app-uninstall flows so they share a single UI surface.
    ///
    /// The retry callback captures `items` directly rather than reading
    /// `pendingPermissionRetryItems` at fire time — that field is mutable
    /// app-wide and a second permission request would clobber it before the
    /// first callback resolves, sending the wrong items to retryCleanItems.
    func requestFullDiskAccessAndRetry(items: [CleanableItem], context: PermissionCoordinator.PromptContext) {
        pendingPermissionRetryItems = items
        let capturedItems = items
        PermissionCoordinator.shared.requestAccess(
            context: context,
            failedPaths: items.map { $0.path }
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.retryAfterFullDiskAccess(items: capturedItems, context: context)
            }
        }
    }

    func retryAfterFullDiskAccess(items: [CleanableItem], context: PermissionCoordinator.PromptContext) async {
        pendingPermissionRetryItems = []
        cleanError = nil
        cleanErrorIsFDAFixable = false
        guard !items.isEmpty else { return }
        if case .uninstall = context {
            removeSelectedFiles(confirmedURLs: Set(items.map { URL(fileURLWithPath: $0.path) }))
        } else {
            await retryCleanItems(items)
        }
    }

    private func retryCleanItems(_ items: [CleanableItem]) async {
        guard !scanState.isActive else { return }
        let generation = UUID()
        cleanupGeneration = generation
        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        var result = await cleaningEngine.cleanItems(items) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.cleanupGeneration == generation, case .cleaning = self.scanState else { return }
                self.cleanProgress = progress
                self.scanState = .cleaning(progress: progress)
            }
        }
        if !result.requiresAdmin.isEmpty {
            let admin = await cleaningEngine.cleanWithAdminPrivileges(items: result.requiresAdmin)
            result.cleanedPaths.formUnion(admin.cleanedPaths)
            result.itemsCleaned += admin.itemsCleaned
            result.freedSpace += admin.freedSpace
            result.errors.append(contentsOf: admin.errors)
            result.protectedPaths.formUnion(admin.protectedPaths)
        }

        totalFreedSpace = result.freedSpace
        if result.itemsCleaned > 0 { lastCleanedDate = Date() }
        // The first attempt already counted as a task.
        UsageStats.shared.recordCleanup(.cleanup, bytes: result.freedSpace, countsAsTask: false)

        for (cat, catResult) in categoryResults {
            let remaining = catResult.items.filter { !result.cleanedPaths.contains($0.path) }
            let cleared = catResult.items.filter { result.cleanedPaths.contains($0.path) }
            for item in cleared {
                selectedCleanupItems.remove(item.id)
                deselectedItems.remove(item.id)
            }
            if remaining.isEmpty {
                categoryResults.removeValue(forKey: cat)
            } else {
                categoryResults[cat] = CategoryResult(
                    category: cat,
                    items: remaining,
                    totalSize: remaining.reduce(0) { $0 + $1.size }
                )
            }
        }
        totalJunkSize = smartCareJunkSize

        // Route survivors back through the same outcome path the original
        // cleanup uses. Without this, an FDA revocation between grant and
        // retry would silently drop errors instead of re-popping the sheet.
        let survivors = survivingItems(from: items, result: result)
        handleCleanOutcome(errors: result.errors, survivors: survivors)

        scanState = result.itemsCleaned > 0 ? .cleaned : .completed
        loadDiskInfo()
    }

    // MARK: - Disk Info

    func loadDiskInfo() {
        if DemoMode.isActive { diskInfo = DemoMode.diskInfo; return }

        Task {
            let info = await scanEngine.getDiskInfo()
            self.diskInfo = info
        }
    }

    // MARK: - Scanning

    func startSmartScan() {
        if DemoMode.isActive { applyDemoResults(.smartCare); return }

        guard !scanState.isActive else { return }
        scanScope = .smartCare
        clearSmartCareResults()
        beginScan(categories: CleaningCategory.smartCare, replacingResults: false)
    }

    func resetSmartCareToStart() {
        guard !scanState.isActive else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration = UUID()
        scanTicker.path = ""
        selectedCategory = .smartScan
        clearSmartCareResults()
        totalFreedSpace = 0
        scanProgress = 0
        cleanProgress = 0
        currentScanCategory = ""
        scanWasCancelled = false
        cleanError = nil
        showCleanConfirmation = false
        scanState = .idle
    }

    // MARK: - Bundle scans

    /// The scan state as seen by one screen: another screen's run reads as idle.
    func scanState(in scope: ScanScope) -> ScanState {
        scanScope == scope ? scanState : .idle
    }

    /// True while a different screen is scanning or cleaning.
    func isBusy(outside scope: ScanScope) -> Bool {
        scanState.isActive && scanScope != scope
    }

    // MARK: - General Cleanup

    /// Id used for the orphaned-files area in the General Cleanup selection.
    static let orphanAreaID = "orphans"
    /// Id used for the unused-apps area in the General Cleanup selection.
    static let unusedAppsAreaID = "unusedApps"
    private static let disabledCleanupAreasKey = "cleanup.disabledAreas"

    /// Every category General Cleanup can scan, System first, then Developer.
    static let generalCleanupCategories: [CleaningCategory] = CleanupBundle.allCases.flatMap(\.categories)

    /// Areas the user switched off: category raw values, or `orphanAreaID`.
    @Published var disabledCleanupAreas: Set<String> = AppState.initialDisabledCleanupAreas() {
        didSet {
            UserDefaults.standard.set(Array(disabledCleanupAreas), forKey: Self.disabledCleanupAreasKey)
        }
    }

    /// Riskier areas start switched off, once, for everyone; after that the
    /// user's own choice is kept.
    private static func initialDisabledCleanupAreas() -> Set<String> {
        let defaults = UserDefaults.standard
        var disabled = Set(defaults.stringArray(forKey: disabledCleanupAreasKey) ?? [])
        let seenKey = "cleanup.riskyAreasIntroduced"
        if !defaults.bool(forKey: seenKey) {
            disabled.formUnion(CleaningCategory.allCases.filter(\.isRisky).map(\.rawValue))
            defaults.set(Array(disabled), forKey: disabledCleanupAreasKey)
            defaults.set(true, forKey: seenKey)
        }
        return disabled
    }

    func isCleanupAreaEnabled(_ id: String) -> Bool {
        !disabledCleanupAreas.contains(id)
    }

    func setCleanupArea(_ id: String, enabled: Bool) {
        if enabled { disabledCleanupAreas.remove(id) } else { disabledCleanupAreas.insert(id) }
    }

    var enabledCleanupCategories: [CleaningCategory] {
        Self.generalCleanupCategories.filter { isCleanupAreaEnabled($0.rawValue) }
    }

    var cleanupIncludesOrphans: Bool { isCleanupAreaEnabled(Self.orphanAreaID) }

    var cleanupIncludesUnusedApps: Bool { isCleanupAreaEnabled(Self.unusedAppsAreaID) }

    var hasEnabledCleanupAreas: Bool {
        !enabledCleanupCategories.isEmpty || cleanupIncludesOrphans || cleanupIncludesUnusedApps
    }

    // MARK: - Unused apps

    @Published private(set) var unusedApps: [UnusedAppRecord] = []
    @Published private(set) var isSearchingUnusedApps = false
    @Published private(set) var hasSearchedUnusedApps = false
    @Published var selectedUnusedApps: Set<String> = []
    @Published private(set) var isRemovingUnusedApps = false
    private var unusedAppsTask: Task<Void, Never>?

    var totalUnusedAppsSize: Int64 { unusedApps.reduce(0) { $0 + $1.totalSize } }

    var selectedUnusedAppsSize: Int64 {
        unusedApps.filter { selectedUnusedApps.contains($0.id) }.reduce(0) { $0 + $1.totalSize }
    }

    func findUnusedApps() {
        guard !DemoMode.isActive else { return }  // demo: never touch the Mac

        unusedAppsTask?.cancel()
        isSearchingUnusedApps = true
        hasSearchedUnusedApps = false
        unusedApps = []
        selectedUnusedApps = []
        let months = UnusedAppsFinder.configuredMonths
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        unusedAppsTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                UnusedAppsFinder.find(olderThanMonths: months, runningPaths: running)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.unusedApps = found
            self.hasSearchedUnusedApps = true
            self.isSearchingUnusedApps = false
            self.unusedAppsTask = nil
        }
    }

    func cancelUnusedAppsScan() {
        unusedAppsTask?.cancel()
        unusedAppsTask = nil
        isSearchingUnusedApps = false
        hasSearchedUnusedApps = false
        unusedApps = []
        selectedUnusedApps = []
    }

    /// Moves the chosen apps and their support files to the Trash, asking for
    /// an administrator password only for items that need it. Returns the space
    /// freed and an error message when something could not be removed.
    func removeUnusedApps(_ ids: Set<String>) async -> (freed: Int64, error: String?) {
        guard !DemoMode.isActive else { return (0, nil) }  // demo: never touch the Mac

        guard !isRemovingUnusedApps else { return (0, nil) }
        let apps = unusedApps.filter { ids.contains($0.id) }
        guard !apps.isEmpty else { return (0, nil) }
        isRemovingUnusedApps = true
        defer { isRemovingUnusedApps = false }

        let urls = apps.flatMap(\.files).filter { url in
            let resolved = url.resolvingSymlinksInPath().path
            return !highRiskHomeDotPaths.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
        }
        let outcome: ([URL], Bool, [URL], [URL]) = await withCheckedContinuation { continuation in
            appFileTrasher(urls) { removed, needsFDA, needsAdmin, failed in
                continuation.resume(returning: (removed, needsFDA, needsAdmin, failed))
            }
        }
        var (removed, _, needsAdmin, failed) = outcome
        if !needsAdmin.isEmpty {
            let result = await cleaningEngine.cleanWithAdminPrivileges(items: needsAdmin.map { cleanableUninstallItem(for: $0) })
            removed += needsAdmin.filter { result.cleanedPaths.contains($0.path) }
            failed += needsAdmin.filter { !result.cleanedPaths.contains($0.path) }
        }

        let removedPaths = Set(removed.map(\.path))
        let goneApps = apps.filter { removedPaths.contains($0.appURL.path) }
        let freed = goneApps.reduce(Int64(0)) { $0 + $1.totalSize }
        unusedApps.removeAll { app in goneApps.contains(app) }
        selectedUnusedApps.subtract(goneApps.map(\.id))
        if !goneApps.isEmpty { loadInstalledApps() }

        guard !failed.isEmpty else { return (freed, nil) }
        let preview = failed.prefix(3).map(\.path).joined(separator: "\n")
        return (freed, String(
            format: String(localized: "%lld item(s) failed to delete.\n\n%@"),
            Int64(failed.count),
            preview + (failed.count > 3 ? "\n…" : "")
        ))
    }

    var isRunningGeneralCleanup: Bool {
        guard scanScope == .generalCleanup else { return false }
        if case .scanning = scanState { return true }
        return isSearchingOrphans || isSearchingUnusedApps
    }

    /// True while results from an earlier General Cleanup scan are still around.
    var hasStoredCleanupResults: Bool {
        Self.generalCleanupCategories.contains { categoryResults[$0] != nil } || hasSearchedOrphans || hasSearchedUnusedApps
    }

    /// Makes General Cleanup the owner of the next clean, so progress shows there.
    func claimGeneralCleanupScope() {
        guard !scanState.isActive else { return }
        if scanScope != .generalCleanup {
            scanScope = .generalCleanup
            scanState = .completed
        }
    }

    /// One scan for every selected System and Developer area.
    func startGeneralCleanup() {
        if DemoMode.isActive { applyDemoResults(.generalCleanup); return }

        guard !scanState.isActive, !isSearchingOrphans, !isSearchingUnusedApps, !isRemovingOrphans,
              !isRemovingUnusedApps, hasEnabledCleanupAreas else { return }
        scanScope = .generalCleanup
        clearGeneralCleanupResults()
        cleanError = nil
        if cleanupIncludesOrphans {
            findOrphans()
        }
        if cleanupIncludesUnusedApps {
            findUnusedApps()
        }
        beginScan(categories: enabledCleanupCategories, replacingResults: false)
    }

    /// Stops the scan, keeping category results found so far.
    func stopGeneralCleanup() {
        guard scanScope == .generalCleanup else { return }
        cancelScan()
        if isSearchingOrphans {
            cancelOrphanScan()
        }
        if isSearchingUnusedApps {
            cancelUnusedAppsScan()
        }
    }

    /// Discards General Cleanup results so the screen returns to the start.
    func resetGeneralCleanup() {
        guard !scanState.isActive, !isRemovingOrphans, !isRemovingUnusedApps else { return }
        clearGeneralCleanupResults()
        if scanScope == .generalCleanup {
            scanState = .idle
            scanWasCancelled = false
            totalFreedSpace = 0
            cleanError = nil
        }
    }

    private func clearGeneralCleanupResults() {
        for category in Self.generalCleanupCategories {
            clearSelectionState(for: category)
            categoryResults[category] = nil
        }
        totalJunkSize = smartCareJunkSize
        cancelOrphanScan()
        cancelUnusedAppsScan()
    }

    func cancelScan() {
        guard case .scanning = scanState else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration = UUID()
        scanWasCancelled = true
        scanTicker.path = ""
        scanState = categoryResults.isEmpty ? .idle : .completed
    }

    private func beginScan(categories: [CleaningCategory], replacingResults: Bool) {
        let generation = UUID()
        scanGeneration = generation
        scanWasCancelled = false
        totalFreedSpace = 0
        scanProgress = 0
        scanState = .scanning(progress: 0, currentCategory: "Preparing...")
        if replacingResults {
            categoryResults = [:]
            totalJunkSize = 0
            clearSelectionState()
        }
        scanTask = Task {
            for (index, category) in categories.enumerated() {
                guard !Task.isCancelled, scanGeneration == generation else { return }
                let progress = Double(index) / Double(categories.count)
                scanProgress = progress
                currentScanCategory = category.rawValue
                scanState = .scanning(progress: progress, currentCategory: category.rawValue)
                clearSelectionState(for: category)
                let result = await scanEngine.scanCategory(category) { [weak self] path in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanGeneration == generation else { return }
                        self.scanTicker.path = path
                    }
                }
                guard !Task.isCancelled, scanGeneration == generation else { return }
                categoryResults[category] = applyingCleanupExclusions(to: result)
                totalJunkSize = smartCareJunkSize
            }
            scanProgress = 1
            scanTicker.path = ""
            lastScanDate = Date()
            scanState = .completed
            scanTask = nil
            UsageStats.shared.recordScan(
                scanScope == .generalCleanup ? .advancedScan : .smartCareScan,
                filesChecked: categories.reduce(0) { $0 + (categoryResults[$1]?.itemCount ?? 0) }
            )
            loadDiskInfo()
        }
    }

    // MARK: - Cleaning

    func cleanAll(itemIDs: Set<UUID>? = nil, scheduled: Bool = false) {
        guard !DemoMode.isActive else { return }  // demo: never touch the Mac

        guard !scanState.isActive else { return }

        let itemsToClean = allResults.flatMap { $0.items }.filter { item in
            guard itemIDs?.contains(item.id) ?? true else { return false }
            guard isItemSelected(item) else { return false }
            if scheduled && XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(item.path) {
                // Scheduled XcodeBuildMCP cleanup is intentionally stricter
                // than ordinary Xcode Junk: only old, unlocked rows qualify.
                return XcodeBuildMCPDerivedDataSupport.isEligibleForScheduledAutoClean(item)
            }
            return true
        }
        guard !itemsToClean.isEmpty else { return }
        let generation = UUID()
        cleanupGeneration = generation

        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        Task {
            var result = await cleaningEngine.cleanItems(itemsToClean) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.cleanupGeneration == generation, case .cleaning = self.scanState else { return }
                    self.cleanProgress = progress
                    self.scanState = .cleaning(progress: progress)
                }
            }

            // Escalate root-owned items via "with administrator privileges".
            // One auth prompt covers the entire batch.
            if !result.requiresAdmin.isEmpty {
                let admin = await cleaningEngine.cleanWithAdminPrivileges(items: result.requiresAdmin)
                result.cleanedPaths.formUnion(admin.cleanedPaths)
                result.itemsCleaned += admin.itemsCleaned
                result.freedSpace += admin.freedSpace
                result.errors.append(contentsOf: admin.errors)
                result.protectedPaths.formUnion(admin.protectedPaths)
            }

            totalFreedSpace = result.freedSpace
            if result.itemsCleaned > 0 { lastCleanedDate = Date() }
            if result.itemsCleaned > 0 { Haptics.successWithSound() }
            if result.itemsCleaned > 0 { UsageStats.shared.recordCleanup(.cleanup, bytes: result.freedSpace) }

            let survivors = survivingItems(from: itemsToClean, result: result)

            for (cat, catResult) in categoryResults {
                let remaining = catResult.items.filter { !result.cleanedPaths.contains($0.path) }
                let cleared = catResult.items.filter { result.cleanedPaths.contains($0.path) }
                for item in cleared {
                    selectedCleanupItems.remove(item.id)
                    deselectedItems.remove(item.id)
                }
                if remaining.isEmpty {
                    categoryResults.removeValue(forKey: cat)
                } else {
                    categoryResults[cat] = CategoryResult(
                        category: cat,
                        items: remaining,
                        totalSize: remaining.reduce(0) { $0 + $1.size }
                    )
                }
            }
            totalJunkSize = smartCareJunkSize

            handleCleanOutcome(errors: result.errors, survivors: survivors)

            scanState = result.itemsCleaned > 0 ? .cleaned : .completed
            loadDiskInfo()
        }
    }

    /// Items that neither got cleaned nor were skipped as SIP-protected.
    /// Protected paths can't be removed even as root, so treating them as
    /// failures only produces a "Couldn't clean everything" alert the user
    /// can do nothing about (e.g. /private/var/log/wifi.log) — log and move on.
    private func survivingItems(from items: [CleanableItem], result: CleaningEngine.CleaningResult) -> [CleanableItem] {
        if result.skippedProtected > 0 {
            let protectedList = result.protectedPaths.sorted().joined(separator: ", ")
            Logger.shared.log("Skipped \(result.skippedProtected) macOS-protected item(s): \(protectedList)", level: .info)
        }
        return items.filter {
            !$0.isActionItem &&
                !result.cleanedPaths.contains($0.path) &&
                !result.protectedPaths.contains($0.path)
        }
    }

    /// Inspect a clean batch's leftovers and either route the user into the
    /// PermissionSheet (FDA is the most likely cause) or surface a richer
    /// error alert that lists actual paths instead of "Check the log".
    private func handleCleanOutcome(errors: [String], survivors: [CleanableItem]) {
        lastCleanupHadFailures = !errors.isEmpty || !survivors.isEmpty
        guard !errors.isEmpty || !survivors.isEmpty else {
            cleanError = nil
            cleanErrorIsFDAFixable = false
            pendingPermissionRetryItems = []
            return
        }

        let fdaGranted = FullDiskAccessManager.shared.hasFullDiskAccess
        // App-modifying survivors (thinning, localization stripping) fail on
        // root-owned bundles that Full Disk Access cannot make writable, so
        // they must not steer the user into a Grant Access loop that can
        // never succeed. Only junk-file survivors count toward that hint.
        // Virtual machines and Docker data fail for their own reasons (a tool
        // still running), which Full Disk Access doesn't fix either.
        let fdaFixableSurvivors = survivors.filter { !CleaningCategory.appModifying.contains($0.category) && !$0.category.isRisky }
        let likelyFDA = !fdaGranted && !fdaFixableSurvivors.isEmpty
        cleanErrorIsFDAFixable = likelyFDA
        pendingPermissionRetryItems = survivors

        if likelyFDA {
            cleanError = String(
                format: String(localized: "%lld item(s) need Full Disk Access to remove. Tap Grant Access to fix in one step."),
                Int64(fdaFixableSurvivors.count)
            )
        } else if !survivors.isEmpty, survivors.allSatisfy(\.category.isRisky), !errors.isEmpty {
            cleanError = errors.joined(separator: "\n")
        } else if !survivors.isEmpty {
            let preview = survivors.prefix(2).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            let extra = survivors.count > 2 ? String(format: String(localized: " and %lld more"), Int64(survivors.count - 2)) : ""
            cleanError = String(
                format: String(localized: "Couldn't remove %@%@. They may be in use or protected by macOS."),
                preview, extra
            )
        } else if let first = errors.first {
            cleanError = first
        }
    }

    // MARK: - Purgeable

    func purgePurgeable() {
        guard !DemoMode.isActive else { return }  // demo: never touch the Mac

        loadDiskInfo()
    }

    // MARK: - Scheduled Scan

    func canRunScheduledScan(isAppActive: Bool) -> Bool {
        !scanState.isActive && !(scanState == .completed && isAppActive)
            && !showCleanConfirmation && !isScanningAppFiles && !isRemovingAppFiles
            && !isSearchingOrphans && !PermissionCoordinator.shared.isRequesting
    }

    func runScheduledScan() async {
        guard !DemoMode.isActive else { return }

        guard canRunScheduledScan(isAppActive: NSApp.isActive) else { return }
        let categories = scheduler.config.categoriesToScan.filter { CleaningCategory.smartCare.contains($0) }
        guard !categories.isEmpty else { return }
        let generation = UUID()
        scanGeneration = generation
        // Smart Care owns scheduled runs, so its screen shows them.
        scanScope = .smartCare
        scanWasCancelled = false
        clearSmartCareResults()
        for (index, category) in categories.enumerated() {
            let progress = Double(index) / Double(categories.count)
            scanState = .scanning(progress: progress, currentCategory: category.rawValue)
            scanProgress = progress
            currentScanCategory = category.rawValue
            let result = applyingCleanupExclusions(to: await scanEngine.scanCategory(category))
            guard scanGeneration == generation, !Task.isCancelled else { return }
            categoryResults[category] = result
            totalJunkSize = smartCareJunkSize
        }
        scanProgress = 1
        lastScanDate = Date()
        scanState = .completed
        UsageStats.shared.recordScan(.smartCareScan, filesChecked: categories.reduce(0) { $0 + (categoryResults[$1]?.itemCount ?? 0) })
        let found = totalJunkSize
        if scheduler.config.autoClean && smartCareSelectedSize >= scheduler.config.minimumCleanSize {
            // Only Smart Care's own items: Advanced Cleanup results are never auto-cleaned.
            cleanAll(itemIDs: Set(smartCareResults.flatMap(\.items).map(\.id)), scheduled: true)
        }
        if scheduler.config.notifyOnCompletion {
            sendNotification(freed: found)
        }
    }

    private func sendNotification(freed: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "MacDash"
        let sizeStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        content.body = String(format: NSLocalizedString("Found %@ of junk files.", comment: ""), sizeStr)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private static func defaultAppFileScanner(
        app: InstalledApp,
        locations: Locations,
        completion: @escaping (Set<URL>) -> Void
    ) {
        let appInfo = AppPathFinder.AppInfo(
            appName: app.appName,
            bundleIdentifier: app.bundleIdentifier,
            path: app.path,
            entitlements: nil,
            teamIdentifier: nil
        )
        let finder = AppPathFinder(appInfo: appInfo, locations: locations)
        finder.findPathsAsync(completion: completion)
    }
}

// MARK: - Demo mode (MACDASH_DEMO=1, site screenshots)

extension AppState {
    /// Fills one screen with DemoMode's fictional findings, as if its scan had just finished.
    func applyDemoResults(_ scope: ScanScope) {
        scanScope = scope
        let categories = scope == .smartCare ? CleaningCategory.smartCare : enabledCleanupCategories
        for category in categories {
            guard let result = DemoMode.result(for: category) else { continue }
            categoryResults[category] = result
        }
        if scope == .generalCleanup {
            let orphans = DemoMode.orphans
            orphanedFiles = orphans.map(\.url)
            for orphan in orphans { orphanSizes[orphan.url] = orphan.size }
            hasSearchedOrphans = true
            unusedApps = DemoMode.unusedApps
            hasSearchedUnusedApps = true
            cleanupDetailOpen = DemoMode.initialReview != nil
        }
        totalJunkSize = smartCareJunkSize
        scanProgress = 1
        lastScanDate = Date()
        scanState = .completed
    }
}
