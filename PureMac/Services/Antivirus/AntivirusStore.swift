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

    var lastScan: AntivirusScanRecord? { history.first }

    var nextScheduledScan: Date? {
        guard let interval = schedule.interval else { return nil }
        guard let last = history.first(where: { !$0.wasCancelled })?.startedAt else { return Date() }
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
        phase = .finished(record)
        save()
        if scheduled, !fresh.isEmpty { notify(count: fresh.count) }
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
            case .success(let items):
                pending.removeAll { $0.id == detection.id }
                quarantine.insert(QuarantineRecord(id: detection.id, detection: detection, items: items, quarantinedAt: Date()), at: 0)
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
            case .success:
                quarantine.removeAll { $0.id == record.id }
                try? FileManager.default.removeItem(at: quarantineFolder.appendingPathComponent(record.id.uuidString))
                if andTrust {
                    let rules = record.detection.components.compactMap { component in
                        component.sha256.map { TrustRule(kind: .hash, value: $0, label: component.path, addedAt: Date()) }
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
    }

    private var loading = false

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        loading = true
        pending = saved.pending
        quarantine = saved.quarantine
        trusted = saved.trusted
        history = saved.history
        schedule = saved.schedule
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let saved = Saved(pending: pending, quarantine: quarantine, trusted: trusted, history: history, schedule: schedule)
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

/// File operations for quarantine. Items the user can't move (root-owned
/// launch daemons, apps installed by another account) go through one
/// administrator prompt.
enum AntivirusVault {
    struct VaultError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func quarantine(_ detection: Detection, into vault: URL) -> Result<[QuarantinedItem], Error> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }
        // 1. Unload launch items so they can't start the program again.
        let uid = getuid()
        for item in detection.launchItems {
            if item.path.hasPrefix(NSHomeDirectory()) {
                _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", item.path])
            }
        }
        var adminCommands: [String] = detection.launchItems
            .filter { !$0.path.hasPrefix(NSHomeDirectory()) }
            .map { "/bin/launchctl bootout system \(quoted($0.path)) || true" }

        // 2. Stop processes running the threat's programs.
        for component in detection.components where component.role == .program || component.role == .file {
            for pid in AntivirusScanner.processIDs(runningAt: component.path) where kill(pid, SIGTERM) != 0 {
                adminCommands.append("/bin/kill -TERM \(pid) || true")
            }
        }

        // 3. Move each component into the vault, keeping its permissions.
        var items: [QuarantinedItem] = []
        var adminMoves: [(String, String)] = []
        for (index, component) in detection.components.enumerated() {
            guard fm.fileExists(atPath: component.path) else { continue }
            let stored = vault.appendingPathComponent("\(index)-\(URL(fileURLWithPath: component.path).lastPathComponent)").path
            let permissions = (try? fm.attributesOfItem(atPath: component.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o644
            do {
                try fm.moveItem(atPath: component.path, toPath: stored)
                // Not executable or readable while it waits.
                _ = chmod(stored, 0)
                items.append(QuarantinedItem(originalPath: component.path, storedPath: stored, permissions: permissions, needsAdministrator: false))
            } catch {
                adminMoves.append((component.path, stored))
                items.append(QuarantinedItem(originalPath: component.path, storedPath: stored, permissions: permissions, needsAdministrator: true))
            }
        }
        for (from, to) in adminMoves {
            adminCommands.append("/bin/mv \(quoted(from)) \(quoted(to)) && /bin/chmod 0 \(quoted(to))")
        }
        if !adminCommands.isEmpty, let failure = runAsAdministrator(adminCommands) {
            // Roll back what moved without a password, so nothing is half done.
            for item in items where !item.needsAdministrator {
                _ = chmod(item.storedPath, mode_t(item.permissions))
                try? fm.moveItem(atPath: item.storedPath, toPath: item.originalPath)
            }
            return .failure(failure)
        }
        return .success(items)
    }

    static func restore(_ items: [QuarantinedItem]) -> Result<Void, Error> {
        let fm = FileManager.default
        var adminCommands: [String] = []
        for item in items {
            if fm.fileExists(atPath: item.originalPath) {
                return .failure(VaultError(message: String(format: String(localized: "A file already exists at %@."), item.originalPath)))
            }
            if item.needsAdministrator {
                adminCommands.append("/bin/chmod \(String(item.permissions, radix: 8)) \(quoted(item.storedPath)) && /bin/mv \(quoted(item.storedPath)) \(quoted(item.originalPath))")
                continue
            }
            do {
                _ = chmod(item.storedPath, mode_t(item.permissions))
                try fm.createDirectory(at: URL(fileURLWithPath: item.originalPath).deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(atPath: item.storedPath, toPath: item.originalPath)
            } catch {
                return .failure(error)
            }
        }
        if !adminCommands.isEmpty, let failure = runAsAdministrator(adminCommands) { return .failure(failure) }
        return .success(())
    }

    static func delete(_ vault: URL, items: [QuarantinedItem]) -> Result<Void, Error> {
        if items.contains(where: \.needsAdministrator) {
            if let failure = runAsAdministrator(["/bin/rm -rf \(quoted(vault.path))"]) { return .failure(failure) }
            return .success(())
        }
        // Folders were locked with chmod 0; open them up so they can be removed.
        _ = Shell.run("/bin/chmod", ["-R", "u+rwx", vault.path])
        do {
            try FileManager.default.removeItem(at: vault)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One password prompt for all commands; nil on success.
    private static func runAsAdministrator(_ commands: [String]) -> Error? {
        let script = commands.joined(separator: "; ")
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // osascript in its own process: NSAppleScript must stay on the main thread.
        let status = Shell.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"]).status
        return status == 0 ? nil : VaultError(message: String(localized: "The administrator password was not entered."))
    }
}
