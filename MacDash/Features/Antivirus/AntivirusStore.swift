import AppKit
import Foundation
import UserNotifications

/// The antivirus state shared by the screen and scheduled scans: what is
/// waiting for review, what is in quarantine, what the user trusts.
///
/// Rule of the product: MacDash never acts on a detection by itself. A scan
/// only fills `pending`; every move, unload, stop or delete starts from a
/// button the user pressed.
@MainActor
final class AntivirusStore: ObservableObject {
    static let shared = AntivirusStore()

    enum Phase: Equatable {
        case idle
        case scanning(AntivirusScanMode)
        case finished(AntivirusScanRecord)
    }

    enum Schedule: String, CaseIterable, Identifiable, Codable {
        case off, daily, weekly
        var id: String { rawValue }
        var interval: TimeInterval? {
            switch self {
            case .off: return nil
            case .daily: return 86_400
            case .weekly: return 7 * 86_400
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// Live progress lives in its own object: only the progress text
    /// redraws during a scan, not the whole screen and its lists.
    let ticker = AntivirusProgressTicker()
    @Published private(set) var pending: [Detection] = []
    @Published private(set) var quarantine: [QuarantineRecord] = []
    @Published private(set) var trusted: [TrustRule] = []
    @Published private(set) var history: [AntivirusScanRecord] = []
    @Published var schedule: Schedule = .off { didSet { save() } }
    /// When the last complete scan started. Kept apart from `history` so
    /// clearing the history doesn't make a scheduled scan run at once.
    @Published private(set) var lastCompletedScan: Date?
    @Published var lastError: String?
    /// Detections being quarantined or removed right now.
    @Published private(set) var busy: Set<UUID> = []

    let folder: URL
    var quarantineFolder: URL { folder.appendingPathComponent("Quarantine", isDirectory: true) }
    private var stateURL: URL { folder.appendingPathComponent("state.json") }
    private var scanTask: Task<Void, Never>?
    /// The background walk itself. A detached task doesn't inherit
    /// cancellation, so Stop cancels this one directly.
    private var scanWork: Task<AntivirusScanOutcome, Never>?
    private var scheduleTimer: Timer?
    /// Clean files from earlier scans this session; skipped while unchanged.
    private let cache = AntivirusCleanCache()

    init(folder: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? support.appendingPathComponent("MacDash/Antivirus", isDirectory: true)
        load()
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var nextScheduledScan: Date? {
        guard let interval = schedule.interval else { return nil }
        guard let last = lastCompletedScan else { return Date() }
        return last.addingTimeInterval(interval)
    }

    // MARK: Scanning

    func start(_ mode: AntivirusScanMode, custom: [URL] = [], scheduled: Bool = false) {
        guard !isScanning else { return }
        let scanner = AntivirusScanner(quarantineFolder: quarantineFolder.path)
        let trust = AntivirusScanner.Trust(rules: trusted)
        let cache = self.cache
        let started = Date()
        phase = .scanning(mode)
        ticker.progress = AntivirusProgress()

        let work = Task.detached(priority: .utility) {
            await scanner.scan(mode: mode, custom: custom, trust: trust, cache: cache) { update in
                Task { @MainActor [weak self] in
                    guard let self, self.isScanning else { return }
                    self.ticker.progress = update
                }
            }
        }
        scanWork = work
        scanTask = Task { [weak self] in
            let outcome = await work.value
            self?.finish(outcome, mode: mode, started: started, scheduled: scheduled)
        }
    }

    func stop() {
        scanWork?.cancel()
    }

    /// Writes the EICAR test file into MacDash's own folder and scans just
    /// that file, so the whole review flow can be tried safely.
    func testProtection() {
        let testFolder = folder.appendingPathComponent("Test", isDirectory: true)
        let file = testFolder.appendingPathComponent("eicar-test.com")
        do {
            try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
            try AntivirusRules.eicar.write(to: file)
        } catch {
            lastError = error.localizedDescription
            return
        }
        start(.custom, custom: [file])
    }

    private func finish(_ outcome: AntivirusScanOutcome, mode: AntivirusScanMode, started: Date, scheduled: Bool) {
        scanTask = nil
        scanWork = nil
        // A threat already waiting keeps its place; quarantined paths can't
        // be found again.
        let known = Set(pending.map(\.fingerprint))
        let fresh = outcome.detections.filter { !known.contains($0.fingerprint) }
        pending = (fresh + pending).sorted { ($0.severity, $0.detectedAt) > ($1.severity, $1.detectedAt) }

        let record = AntivirusScanRecord(
            id: UUID(),
            mode: mode,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            filesChecked: outcome.filesChecked,
            detections: outcome.detections.count,
            wasCancelled: outcome.wasCancelled,
            wasScheduled: scheduled
        )
        history.insert(record, at: 0)
        history = Array(history.prefix(50))
        // A Custom scan (and the protection test) covers a few files; only
        // full scans count for the schedule and the Assistant.
        if !record.wasCancelled, mode != .custom { lastCompletedScan = started }
        phase = .finished(record)
        save()
        if scheduled, !fresh.isEmpty { notify(count: fresh.count) }
    }

    /// Erases the list of past scans. Quarantine, trusted items and what is
    /// waiting for review are not touched.
    func clearHistory() {
        history.removeAll()
        save()
    }

    func reset() {
        guard !isScanning else { return }
        phase = .idle
    }

    // MARK: Review actions (each one is a user click)

    /// Leaves the files alone this time; a later scan can find them again.
    func dismiss(_ detection: Detection) {
        pending.removeAll { $0.id == detection.id }
        save()
    }

    func trust(_ detection: Detection, by kind: TrustRule.Kind) {
        let rules: [TrustRule]
        switch kind {
        case .hash:
            rules = detection.components.compactMap { component in
                component.sha256.map { TrustRule(kind: .hash, value: $0, label: component.path, addedAt: Date()) }
            }
        case .path:
            rules = detection.components.map { TrustRule(kind: .path, value: $0.path, label: $0.path, addedAt: Date()) }
        case .teamID:
            rules = detection.signing?.teamID.map { [TrustRule(kind: .teamID, value: $0, label: detection.name, addedAt: Date())] } ?? []
        }
        let existing = Set(trusted.map(\.id))
        trusted.append(contentsOf: rules.filter { !existing.contains($0.id) })
        pending.removeAll { $0.id == detection.id }
        save()
    }

    func removeTrust(_ rule: TrustRule) {
        trusted.removeAll { $0.id == rule.id }
        // Its files go back to being checked from scratch.
        cache.removeAll()
        save()
    }

    /// Unloads the launch items, stops processes running the threat's
    /// programs and moves every component into MacDash's quarantine.
    func quarantine(_ detection: Detection) {
        guard !busy.contains(detection.id) else { return }
        busy.insert(detection.id)
        let vault = quarantineFolder.appendingPathComponent(detection.id.uuidString, isDirectory: true)
        Task {
            let result = await Task.detached { AntivirusVault.quarantine(detection, into: vault) }.value
            busy.remove(detection.id)
            switch result {
            case .success(let outcome):
                pending.removeAll { $0.id == detection.id }
                if !outcome.items.isEmpty {
                    quarantine.insert(QuarantineRecord(id: detection.id, detection: detection, items: outcome.items, quarantinedAt: Date()), at: 0)
                }
                if !outcome.notMoved.isEmpty {
                    // What stayed behind waits for review again.
                    let left = detection.components.filter { outcome.notMoved.contains($0.path) }
                    pending.insert(detection.with(components: left), at: 0)
                    lastError = String(format: String(localized: "Some items couldn't be moved: %@"), outcome.notMoved.joined(separator: ", "))
                }
                cache.removeAll()
                save()
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
    }

    func restore(_ record: QuarantineRecord, andTrust: Bool) {
        guard !busy.contains(record.id) else { return }
        busy.insert(record.id)
        Task {
            let result = await Task.detached { AntivirusVault.restore(record.items) }.value
            busy.remove(record.id)
            switch result {
            case .success(let remaining):
                if remaining.isEmpty {
                    quarantine.removeAll { $0.id == record.id }
                    AntivirusVault.removeEmptyVault(quarantineFolder.appendingPathComponent(record.id.uuidString))
                } else if let index = quarantine.firstIndex(where: { $0.id == record.id }) {
                    quarantine[index] = QuarantineRecord(id: record.id, detection: record.detection, items: remaining, quarantinedAt: record.quarantinedAt)
                    lastError = String(format: String(localized: "Some items couldn't be restored: %@"), remaining.map(\.originalPath).joined(separator: ", "))
                }
                if andTrust {
                    // By fingerprint when there is one; app bundles have none,
                    // so they're trusted by location.
                    let rules = record.detection.components.map { component in
                        component.sha256.map { TrustRule(kind: .hash, value: $0, label: component.path, addedAt: Date()) }
                            ?? TrustRule(kind: .path, value: component.path, label: component.path, addedAt: Date())
                    }
                    let existing = Set(trusted.map(\.id))
                    trusted.append(contentsOf: rules.filter { !existing.contains($0.id) })
                }
                save()
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
    }

    func deleteForever(_ record: QuarantineRecord) {
        guard !busy.contains(record.id) else { return }
        busy.insert(record.id)
        let vault = quarantineFolder.appendingPathComponent(record.id.uuidString)
        Task {
            let result = await Task.detached { AntivirusVault.delete(vault, items: record.items) }.value
            busy.remove(record.id)
            switch result {
            case .success:
                quarantine.removeAll { $0.id == record.id }
                save()
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Schedule

    /// Checks every 30 minutes whether a scheduled Quick scan is due. Runs
    /// only while MacDash is open; findings still wait for review.
    func startScheduler() {
        guard scheduleTimer == nil else { return }
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runScheduledScanIfDue() }
        }
        runScheduledScanIfDue()
    }

    private func runScheduledScanIfDue() {
        guard let next = nextScheduledScan, next <= Date(), !isScanning else { return }
        start(.quick, scheduled: true)
    }

    private func notify(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Antivirus found something to review")
        content.body = String(format: String(localized: "%lld items are waiting for your decision. Nothing was moved."), Int64(count))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "antivirus.scheduled", content: content, trigger: nil))
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var pending: [Detection]
        var quarantine: [QuarantineRecord]
        var trusted: [TrustRule]
        var history: [AntivirusScanRecord]
        var schedule: Schedule
        /// Optional so state saved before it existed still loads.
        var lastCompletedScan: Date?
    }

    private var loading = false

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            // Never overwrite what can't be read: the quarantine records in it
            // are the only way to restore those files. Keep a copy aside.
            let backup = folder.appendingPathComponent("state-\(Int(Date().timeIntervalSince1970)).json.bak")
            try? FileManager.default.moveItem(at: stateURL, to: backup)
            lastError = String(format: String(localized: "Couldn't read the saved antivirus data. A copy was kept at %@."), backup.path)
            return
        }
        loading = true
        pending = saved.pending
        quarantine = saved.quarantine
        trusted = saved.trusted
        history = saved.history
        schedule = saved.schedule
        lastCompletedScan = saved.lastCompletedScan ?? saved.history.first { !$0.wasCancelled }?.startedAt
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let saved = Saved(pending: pending, quarantine: quarantine, trusted: trusted, history: history, schedule: schedule, lastCompletedScan: lastCompletedScan)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

@MainActor
final class AntivirusProgressTicker: ObservableObject {
    @Published var progress = AntivirusProgress()
}

/// File operations for quarantine. Each operation is planned first, then
/// done either entirely as the user or, when anything needs it, entirely in
/// one administrator command chained with `&&`. Cancelling the password
/// prompt therefore changes nothing. Afterwards the disk is checked, so the
/// result reports what really moved, not what a command claimed.
enum AntivirusVault {
    struct VaultError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What moved into the vault, and what could not be moved.
    struct QuarantineOutcome {
        let items: [QuarantinedItem]
        let notMoved: [String]
    }

    static func quarantine(_ detection: Detection, into vault: URL) -> Result<QuarantineOutcome, Error> {
        let fm = FileManager.default
        let components = detection.components.filter { exists($0.path) }
        guard !components.isEmpty else { return .success(QuarantineOutcome(items: [], notMoved: [])) }

        // The files must still be the ones the scan judged.
        for component in components where component.role != .archive || component.archiveEntry == nil {
            guard let expected = component.sha256, !isSymlink(component.path) else { continue }
            if AntivirusRules.sha256(of: URL(fileURLWithPath: component.path)) != expected {
                return .failure(VaultError(message: String(format: String(localized: "%@ changed since the scan. Scan again before moving it."), component.path)))
            }
        }
        do {
            try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }

        let planned: [QuarantinedItem] = components.enumerated().map { index, component in
            let stored = vault.appendingPathComponent("\(index)-\(URL(fileURLWithPath: component.path).lastPathComponent)").path
            var info = stat()
            lstat(component.path, &info)
            return QuarantinedItem(
                originalPath: component.path,
                storedPath: stored,
                permissions: Int16(info.st_mode & 0o7777),
                needsAdministrator: !canMove(component.path) || component.path.contains("/LaunchDaemons/"),
                isSymlink: (info.st_mode & S_IFMT) == S_IFLNK
            )
        }
        let launchItems = detection.launchItems.map(\.path).filter(exists)
        let processes = detection.components
            .filter { $0.role == .program || $0.role == .file }
            .flatMap { component in AntivirusScanner.processIDs(runningAt: component.path).map { (pid: $0, path: component.path) } }

        if planned.contains(where: \.needsAdministrator) {
            var commands = launchItems.map { "/bin/launchctl bootout \(domain(for: $0)) \(quoted($0)) 2>/dev/null || true" }
            // The password prompt can sit open for minutes, and a process id
            // can be reused in that time: only stop it if it still runs the
            // threat's program.
            commands += processes.map { "[ \"$(/bin/ps -o comm= -p \($0.pid))\" = \(quoted($0.path)) ] && /bin/kill -TERM \($0.pid) 2>/dev/null || true" }
            commands += planned.map { item in
                "/bin/mv -n \(quoted(item.originalPath)) \(quoted(item.storedPath)) && /bin/chmod -h 0 \(quoted(item.storedPath))"
            }
            if let failure = runAsAdministrator(commands) {
                // Nothing moved unless the chain got that far; keep what did.
                let moved = planned.filter { exists($0.storedPath) && !exists($0.originalPath) }
                if moved.isEmpty { return .failure(failure) }
                return .success(QuarantineOutcome(items: moved, notMoved: planned.filter { !moved.contains($0) }.map(\.originalPath)))
            }
        } else {
            for path in launchItems { _ = Shell.run("/bin/launchctl", ["bootout", domain(for: path), path]) }
            for process in processes { kill(process.pid, SIGTERM) }
            for item in planned {
                guard (try? fm.moveItem(atPath: item.originalPath, toPath: item.storedPath)) != nil else { continue }
                // Not readable or runnable while it waits. A link keeps its
                // target untouched.
                _ = item.isSymlink == true ? lchmod(item.storedPath, 0) : chmod(item.storedPath, 0)
            }
        }
        let moved = planned.filter { exists($0.storedPath) && !exists($0.originalPath) }
        let notMoved = planned.filter { !moved.contains($0) }.map(\.originalPath)
        if moved.isEmpty {
            return .failure(VaultError(message: String(format: String(localized: "Some items couldn't be moved: %@"), notMoved.joined(separator: ", "))))
        }
        return .success(QuarantineOutcome(items: moved, notMoved: notMoved))
    }

    /// Puts items back exactly where they were. Never overwrites: if any
    /// original location is taken, nothing is restored. Returns the items
    /// still in the vault (empty when everything is back).
    static func restore(_ items: [QuarantinedItem]) -> Result<[QuarantinedItem], Error> {
        let fm = FileManager.default
        if let taken = items.first(where: { exists($0.originalPath) }) {
            return .failure(VaultError(message: String(format: String(localized: "A file already exists at %@."), taken.originalPath)))
        }

        if items.contains(where: \.needsAdministrator) {
            let commands = items.map { item in
                let original = quoted(item.originalPath)
                let parent = quoted((item.originalPath as NSString).deletingLastPathComponent)
                let mode = String(item.permissions, radix: 8)
                return "[ ! -e \(original) ] && [ ! -L \(original) ] && /bin/mkdir -p \(parent) && /bin/chmod -h \(mode) \(quoted(item.storedPath)) && /bin/mv -n \(quoted(item.storedPath)) \(original)"
            }
            if let failure = runAsAdministrator(commands) {
                let remaining = items.filter { exists($0.storedPath) }
                if remaining.count == items.count { return .failure(failure) }
                return .success(remaining)
            }
        } else {
            var restored: [QuarantinedItem] = []
            for item in items {
                do {
                    try fm.createDirectory(at: URL(fileURLWithPath: item.originalPath).deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = item.isSymlink == true ? lchmod(item.storedPath, mode_t(item.permissions)) : chmod(item.storedPath, mode_t(item.permissions))
                    try fm.moveItem(atPath: item.storedPath, toPath: item.originalPath)
                    restored.append(item)
                } catch {
                    // Undo, so the record and the disk keep agreeing.
                    _ = item.isSymlink == true ? lchmod(item.storedPath, 0) : chmod(item.storedPath, 0)
                    for done in restored {
                        try? fm.moveItem(atPath: done.originalPath, toPath: done.storedPath)
                        _ = done.isSymlink == true ? lchmod(done.storedPath, 0) : chmod(done.storedPath, 0)
                    }
                    return .failure(error)
                }
            }
        }
        return .success(items.filter { exists($0.storedPath) })
    }

    static func delete(_ vault: URL, items: [QuarantinedItem]) -> Result<Void, Error> {
        if items.contains(where: \.needsAdministrator) {
            if let failure = runAsAdministrator(["/bin/rm -rf \(quoted(vault.path))"]) { return .failure(failure) }
            return exists(vault.path) ? .failure(VaultError(message: String(format: String(localized: "Some items couldn't be moved: %@"), vault.path))) : .success(())
        }
        // Items were locked with chmod 0; open them up so they can be removed.
        // chmod -R doesn't follow links.
        _ = Shell.run("/bin/chmod", ["-R", "u+rwx", vault.path])
        do {
            try FileManager.default.removeItem(at: vault)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Removes an emptied vault folder; never anything still inside it.
    static func removeEmptyVault(_ vault: URL) {
        rmdir(vault.path)
    }

    // MARK: Helpers

    /// True for files, folders and links, including links to nothing.
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Moving needs write access to the parent folder, and to a folder
    /// itself when it is the thing being moved.
    private static func canMove(_ path: String) -> Bool {
        guard access((path as NSString).deletingLastPathComponent, W_OK) == 0 else { return false }
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { return access(path, W_OK) == 0 }
        return true
    }

    /// Daemons live in the system domain; agents, even in /Library, load
    /// in the logged-in user's GUI domain.
    private static func domain(for plist: String) -> String {
        plist.contains("/LaunchDaemons/") ? "system" : "gui/\(getuid())"
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One password prompt; the commands stop at the first failure. nil on
    /// success.
    private static func runAsAdministrator(_ commands: [String]) -> Error? {
        let script = commands.map { "( \($0) )" }.joined(separator: " && ")
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // osascript in its own process: NSAppleScript must stay on the main thread.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return error
        }
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        // -128 is "User canceled" in the password prompt.
        if message.contains("-128") { return VaultError(message: String(localized: "The administrator password was not entered.")) }
        return VaultError(message: String(format: String(localized: "The command run as administrator failed: %@"), message))
    }
}
