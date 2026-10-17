import AppKit
import Carbon
import CoreBluetooth
import CoreLocation
import Foundation
import SQLite3
import UserNotifications

/// Everything MacDash needs macOS to allow, checked for real: each status
/// comes from macOS itself, never from a remembered answer.
@MainActor
final class MacTidyPermissions: ObservableObject {
    static let shared = MacTidyPermissions()

    enum Item: String, CaseIterable, Identifiable {
        case fullDiskAccess
        case appManagement
        case automation
        case notifications
        case bluetooth
        case location

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fullDiskAccess: return String(localized: "Full Disk Access")
            case .appManagement: return String(localized: "App Management")
            case .automation: return String(localized: "Automation of System Events")
            case .notifications: return String(localized: "Notifications")
            case .bluetooth: return "Bluetooth"
            case .location: return String(localized: "Location")
            }
        }

        /// What stops working without it, in one line.
        var purpose: String {
            switch self {
            case .fullDiskAccess:
                return String(localized: "Lets scans reach Mail, Safari, app containers and the Trash, and lets Protection read app permissions.")
            case .appManagement:
                return String(localized: "Lets MacDash remove apps and install app updates.")
            case .automation:
                return String(localized: "Lets Startup Items turn login items on and off.")
            case .notifications:
                return String(localized: "Tells you when a scheduled scan finishes.")
            case .bluetooth:
                return String(localized: "Shows the battery of your keyboards, mice and headphones in the menu bar panel.")
            case .location:
                return String(localized: "Only to show the name of your Wi-Fi network. macOS files network names under location; MacDash never reads where you are.")
            }
        }

        var icon: String {
            switch self {
            case .fullDiskAccess: return "externaldrive.fill.badge.checkmark"
            case .appManagement: return "app.badge.checkmark.fill"
            case .automation: return "gearshape.2.fill"
            case .notifications: return "bell.badge.fill"
            case .bluetooth: return "dot.radiowaves.left.and.right"
            case .location: return "wifi"
            }
        }

        var isRequired: Bool { self == .fullDiskAccess }

        var settingsURL: URL {
            let anchor: String
            switch self {
            case .fullDiskAccess: anchor = "com.apple.preference.security?Privacy_AllFiles"
            case .appManagement: anchor = "com.apple.preference.security?Privacy_AppBundles"
            case .automation: anchor = "com.apple.preference.security?Privacy_Automation"
            case .notifications:
                anchor = "com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.macdash.app")"
            case .bluetooth: anchor = "com.apple.preference.security?Privacy_Bluetooth"
            case .location: anchor = "com.apple.preference.security?Privacy_LocationServices"
            }
            return URL(string: "x-apple.systempreferences:\(anchor)")!
        }
    }

    enum Status: Equatable {
        case checking
        case granted
        /// Never asked yet: MacDash can show the macOS prompt.
        case notAsked
        case denied
        /// App Management can only be read once Full Disk Access is on.
        case needsFullDiskAccess
    }

    @Published private(set) var statuses: [Item: Status] = Dictionary(uniqueKeysWithValues: Item.allCases.map { ($0, .checking) })
    @Published private(set) var requesting: Item?

    private var refreshTask: Task<Void, Never>?
    /// Kept alive while macOS shows its Bluetooth prompt.
    private var bluetoothRequest: BluetoothPermissionRequest?
    /// Kept alive while macOS shows its Location prompt.
    private var locationRequest: LocationPermissionRequest?
    private var watchers = 0
    private var pollTimer: Timer?

    private init() {}

    func status(_ item: Item) -> Status { statuses[item] ?? .checking }

    var allRequiredGranted: Bool { Item.allCases.filter(\.isRequired).allSatisfy { status($0) == .granted } }
    var grantedCount: Int { Item.allCases.filter { status($0) == .granted }.count }

    /// Reads every status again. Cheap enough to run whenever MacDash
    /// comes to the front.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.macdash.app"
            async let fda = Task.detached(priority: .userInitiated) { FullDiskAccessManager.shared.hasFullDiskAccess }.value
            async let automation = Task.detached(priority: .userInitiated) { Self.automationStatus(ask: false) }.value
            async let notifications = Self.notificationStatus()
            // Location Services can block for a moment, so it's read off the main thread.
            async let location = Task.detached(priority: .userInitiated) { Self.locationStatus() }.value
            let hasFDA = await fda
            let appManagement: Status = hasFDA
                ? await Task.detached(priority: .userInitiated) { Self.appManagementStatus(bundleID: bundleID) }.value
                : .needsFullDiskAccess
            let next: [Item: Status] = [
                .fullDiskAccess: hasFDA ? .granted : .denied,
                .appManagement: appManagement,
                .automation: await automation,
                .notifications: await notifications,
                .bluetooth: Self.bluetoothStatus(),
                .location: await location,
            ]
            guard !Task.isCancelled else { return }
            if next != statuses { statuses = next }
            if hasFDA != PermissionCoordinator.shared.hasFullDiskAccess { PermissionCoordinator.shared.refreshStatus() }
        }
    }

    /// While a permissions list is on screen, statuses follow System Settings
    /// within a second or two.
    func startWatching() {
        watchers += 1
        refresh()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in MacTidyPermissions.shared.refresh() }
        }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Asks macOS directly when it can (Automation, Notifications), and
    /// otherwise opens the right pane of System Settings with MacDash shown
    /// in Finder, ready to drag into the list.
    func request(_ item: Item) {
        switch (item, status(item)) {
        case (.notifications, .notAsked), (.notifications, .checking):
            requesting = item
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                requesting = nil
                refresh()
            }
        case (.automation, .notAsked), (.automation, .checking):
            requesting = item
            Task {
                _ = await Task.detached(priority: .userInitiated) { Self.automationStatus(ask: true) }.value
                requesting = nil
                refresh()
            }
        case (.bluetooth, .notAsked), (.bluetooth, .checking):
            requesting = item
            bluetoothRequest = BluetoothPermissionRequest { [weak self] in
                self?.bluetoothRequest = nil
                self?.requesting = nil
                self?.refresh()
            }
        case (.location, .notAsked), (.location, .checking):
            requesting = item
            locationRequest = LocationPermissionRequest { [weak self] in
                self?.locationRequest = nil
                self?.requesting = nil
                self?.refresh()
            }
        case (.fullDiskAccess, _):
            FullDiskAccessManager.shared.triggerRegistration()
            openSettings(for: item, revealApp: true)
        case (.appManagement, _):
            openSettings(for: item, revealApp: true)
        default:
            openSettings(for: item, revealApp: false)
        }
    }

    func openSettings(for item: Item, revealApp: Bool) {
        NSWorkspace.shared.open(item.settingsURL)
        guard revealApp else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            FullDiskAccessManager.shared.revealAppInFinder()
        }
    }

    // MARK: Reading the statuses

    /// Location Services turned off for the whole Mac counts as denied: only
    /// System Settings can fix it.
    nonisolated private static func locationStatus() -> Status {
        guard CLLocationManager.locationServicesEnabled() else { return .denied }
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        default: return .notAsked
        }
    }

    /// Read straight from macOS; asking is a separate step.
    nonisolated private static func bluetoothStatus() -> Status {
        switch CBManager.authorization {
        case .allowedAlways: return .granted
        case .denied, .restricted: return .denied
        default: return .notAsked
        }
    }

    private static func notificationStatus() async -> Status {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        default: return .notAsked
        }
    }

    /// Whether MacDash may send Apple Events to System Events. With `ask`,
    /// macOS shows its prompt when the user hasn't decided yet.
    nonisolated private static func automationStatus(ask: Bool) -> Status {
        let systemEvents = "com.apple.systemevents"
        if NSRunningApplication.runningApplications(withBundleIdentifier: systemEvents).isEmpty {
            guard ask else {
                // Not running, so macOS can't answer; the TCC record can.
                return automationRecord() ?? .notAsked
            }
            launchSystemEvents()
        }
        var target = AEAddressDesc()
        let identifier = Array(systemEvents.utf8)
        let created = identifier.withUnsafeBytes { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == noErr else { return .notAsked }
        defer { AEDisposeDesc(&target) }
        let result = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch result {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return automationRecord() ?? .notAsked
        }
    }

    nonisolated private static func launchSystemEvents() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    /// The user's own TCC record for MacDash → System Events, when readable.
    nonisolated private static func automationRecord() -> Status? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.macdash.app"
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        guard let value = authValue(
            database: path,
            service: "kTCCServiceAppleEvents",
            client: bundleID,
            indirectObject: "com.apple.systemevents"
        ) else { return nil }
        return value == 2 ? .granted : .denied
    }

    /// App Management lives in the system TCC database, which only Full Disk
    /// Access can read.
    nonisolated private static func appManagementStatus(bundleID: String) -> Status {
        for path in ["/Library/Application Support/com.apple.TCC/TCC.db",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path] {
            if let value = authValue(database: path, service: "kTCCServiceSystemPolicyAppBundles", client: bundleID, indirectObject: nil) {
                return value == 2 ? .granted : .denied
            }
        }
        return .notAsked
    }

    /// `auth_value` of one TCC row, or nil when there's no such row or the
    /// database can't be read.
    nonisolated private static func authValue(database: String, service: String, client: String, indirectObject: String?) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var sql = "SELECT auth_value FROM access WHERE service = ?1 AND client = ?2"
        if indirectObject != nil { sql += " AND indirect_object_identifier = ?3" }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, service, -1, transient)
        sqlite3_bind_text(statement, 2, client, -1, transient)
        if let indirectObject { sqlite3_bind_text(statement, 3, indirectObject, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }
}

/// The Mac account macOS asks for when it wants an administrator's name and
/// password, written the way the prompt accepts it.
enum MacAccount {
    static var shortName: String { NSUserName() }
    static var fullName: String { NSFullUserName() }
}

/// Shows macOS's Bluetooth prompt: creating a central manager is what asks.
/// Calls `done` once macOS has an answer.
private final class BluetoothPermissionRequest: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private let done: () -> Void

    init(done: @escaping () -> Void) {
        self.done = done
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        central.delegate = nil
        self.central = nil
        done()
    }
}

/// Shows macOS's Location prompt. MacDash only needs the answer, never a
/// location: with it, macOS hands over the Wi-Fi network's name.
private final class LocationPermissionRequest: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let done: () -> Void

    init(done: @escaping () -> Void) {
        self.done = done
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        manager.delegate = nil
        done()
    }
}
