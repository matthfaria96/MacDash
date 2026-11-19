import AppKit
import Foundation
import UserNotifications

/// A folder shown on the Drive Offload screen.
struct OffloadCandidate: Identifiable, Equatable {
    enum Verdict: Int, Comparable {
        case recommended, worthIt, clean, native, small, blocked
        static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }
    }

    let url: URL
    let title: String
    let detail: String
    let symbol: String
    let advice: OffloadAdvice
    var entry: OffloadCatalogEntry?
    var measure: FolderMeasure?
    var block: OffloadBlockReason?
    var isCustom = false

    var id: String { url.path }
    var size: Int64 { measure?.size ?? 0 }

    var verdict: Verdict {
        if case .nativeSetting = advice { return .native }
        if advice == .clean { return .clean }
        if block != nil || measure?.crossesVolumes == true { return .blocked }
        guard let measure else { return .worthIt }
        if measure.size >= 1_000_000_000 { return .recommended }
        if measure.size >= 300_000_000 || isCustom { return .worthIt }
        return .small
    }

    /// Changed within the last two days.
    var inDailyUse: Bool {
        guard let date = measure?.lastModified else { return false }
        return Date().timeIntervalSince(date) < 2 * 86_400
    }
}

/// What's running right now.
struct OffloadOperation: Equatable {
    enum Kind: Equatable { case move, restore, merge }
    enum Stage: Equatable { case checking, copying, verifying, swapping, finishing }
    let kind: Kind
    let title: String
    var stage: Stage
    var progress: Double?
}

@MainActor
final class DriveOffloadStore: ObservableObject {
    static let shared = DriveOffloadStore()

    @Published private(set) var volumes: [OffloadVolume] = []
    @Published var selectedVolumeID: String? {
        didSet { UserDefaults.standard.set(selectedVolumeID, forKey: Self.volumeKey) }
    }
    @Published private(set) var records: [OffloadRecord] = []
    @Published private(set) var statuses: [UUID: OffloadLinkStatus] = [:]
    @Published private(set) var candidates: [OffloadCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var operation: OffloadOperation?
    @Published private(set) var internalFree: Int64 = 0
    @Published private(set) var internalTotal: Int64 = 0
    /// Folders left in /Volumes by apps that wrote while a drive was away.
    @Published private(set) var ghostMounts: [String] = []
    @Published var message: (text: String, isError: Bool)?
    /// Without Full Disk Access, Desktop, Documents and Downloads are left
    /// alone: reading them would make macOS ask for permission again and again.
    @Published private(set) var skippedProtectedFolders = false
    /// Apps to quit before a move or restore can go on.
    @Published var busyApps: BusyPrompt?

    struct BusyPrompt: Identifiable {
        let id = UUID()
        let names: [String]
        let retry: () -> Void
    }

    private static let volumeKey = "DriveOffload.volume"
    private static let customKey = "DriveOffload.customPaths"
    private let manifestURL: URL
    private var observers: [NSObjectProtocol] = []
    private var process: Process?
    /// Read from the copy and verify threads, so it can't live on the main actor.
    private let cancelFlag = OffloadCancelFlag()
    private var cancelRequested: Bool {
        get { cancelFlag.value }
        set { cancelFlag.value = newValue }
    }
    private var scanTask: Task<Void, Never>?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        manifestURL = support.appendingPathComponent("MacDash/DriveOffload.json")
        selectedVolumeID = UserDefaults.standard.string(forKey: Self.volumeKey)
        if DemoMode.isActive {
            loadDemo()
            return
        }
        loadManifest()
        refreshVolumes()
        recoverInterrupted()
        observeVolumes()
    }

    // MARK: - Derived

    var selectedVolume: OffloadVolume? {
        volumes.first { $0.id == selectedVolumeID } ?? volumes.first { $0.supportsOffload } ?? volumes.first
    }

    var offloadedBytes: Int64 { records.filter { $0.phase == .active }.reduce(0) { $0 + $1.size } }

    func mountPath(for record: OffloadRecord) -> String? {
        volumes.first { $0.uuid == record.volumeUUID }?.url.path
    }

    var movedPaths: [String] { records.map(\.sourcePath) }

    // MARK: - Volumes

    func refreshVolumes() {
        guard !DemoMode.isActive else { return }
        volumes = OffloadVolumes.external()
        let space = OffloadVolumes.internalFreeSpace()
        internalFree = space.free
        internalTotal = space.total
        if selectedVolumeID == nil || !volumes.contains(where: { $0.id == selectedVolumeID }) {
            if let preferred = volumes.first(where: \.supportsOffload) ?? volumes.first {
                selectedVolumeID = preferred.id
            }
        }
        refreshStatuses()
    }

    private func refreshStatuses() {
        var result: [UUID: OffloadLinkStatus] = [:]
        var ghosts: [String] = []
        for index in records.indices {
            let record = records[index]
            let mount = mountPath(for: record)
            var status = DriveOffloadEngine.status(of: record, mountPath: mount)
            // The drive came back under another name ("Midias 1"): follow it.
            if status == .needsRelink, let mount {
                do {
                    try DriveOffloadEngine.repoint(link: record.sourceURL, to: record.destinationURL(mountPath: mount))
                    records[index].mountPath = mount
                    status = .healthy
                    saveManifest()
                } catch {}
            }
            if mount == nil, isGhost(record.mountPath) { ghosts.append(record.mountPath) }
            result[record.id] = status
        }
        statuses = result
        ghostMounts = Array(Set(ghosts)).sorted()
    }

    /// A plain folder sitting where a drive used to be mounted.
    private func isGhost(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem
        return volume == true
    }

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshVolumes()
                    self?.recoverInterrupted()
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            Task { @MainActor in self?.volumeWentAway(path) }
        })
    }

    private func volumeWentAway(_ path: String?) {
        let affected = records.filter { $0.phase == .active && $0.mountPath == path }
        refreshVolumes()
        guard !affected.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "External drive disconnected")
        content.body = String(format: String(localized: "%lld moved folders are offline until you connect it again. Apps that use them may show errors."), Int64(affected.count))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "driveOffload.offline", content: content, trigger: nil))
    }

    // MARK: - Scanning

    func scan() {
        guard !isScanning else { return }
        if DemoMode.isActive { return }
        refreshVolumes()
        isScanning = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let moved = movedPaths
        let custom = UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let canReadProtected = FullDiskAccessManager.shared.hasFullDiskAccess
            await MainActor.run { self?.skippedProtectedFolders = !canReadProtected }
            let found = Self.discover(home: home, moved: moved, custom: custom, includeProtected: canReadProtected)
            await MainActor.run { self?.candidates = found }
            var measured = found
            for index in measured.indices {
                if Task.isCancelled { break }
                measured[index].measure = OffloadMeasure.measure(measured[index].url) { Task.isCancelled }
                let snapshot = measured
                await MainActor.run { self?.candidates = snapshot }
            }
            await MainActor.run {
                self?.candidates = measured.filter { $0.isCustom || $0.verdict != .small || $0.advice != .move }
                    .filter { $0.size > 0 || $0.isCustom }
                self?.isScanning = false
                self?.hasScanned = true
            }
        }
    }

    /// Folders macOS guards with its own permission prompt.
    nonisolated static let promptingFolders = ["Desktop", "Documents", "Downloads"]

    nonisolated private static func discover(home: URL, moved: [String], custom: [String], includeProtected: Bool) -> [OffloadCandidate] {
        let fm = FileManager.default
        var result: [OffloadCandidate] = []
        var seen = Set<String>()
        func add(_ candidate: OffloadCandidate) {
            guard !seen.contains(candidate.url.path), !moved.contains(candidate.url.path) else { return }
            seen.insert(candidate.url.path)
            result.append(candidate)
        }
        func prompts(_ relative: String) -> Bool {
            !includeProtected && promptingFolders.contains { relative == $0 || relative.hasPrefix($0 + "/") }
        }
        for entry in DriveOffloadCatalog.entries where !prompts(entry.relativePath) {
            let url = home.appendingPathComponent(entry.relativePath)
            guard fm.fileExists(atPath: url.path), !DriveOffloadEngine.isSymbolicLink(url) else { continue }
            var candidate = OffloadCandidate(url: url, title: entry.title, detail: entry.detail, symbol: entry.symbol, advice: entry.advice, entry: entry)
            if entry.advice == .move { candidate.block = OffloadSafety.blockReason(for: url, home: home, moved: moved) }
            add(candidate)
        }
        // Projects and folders in Documents.
        let documents = home.appendingPathComponent("Documents")
        let children = !includeProtected ? [] : (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            var candidate = OffloadCandidate(
                url: child, title: child.lastPathComponent,
                detail: String(localized: "Folder in Documents."), symbol: "folder.fill", advice: .move
            )
            candidate.block = OffloadSafety.blockReason(for: child, home: home, moved: moved)
            add(candidate)
        }
        for path in custom {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path), !DriveOffloadEngine.isSymbolicLink(url) else { continue }
            var candidate = OffloadCandidate(
                url: url, title: url.lastPathComponent,
                detail: String(localized: "Added by you."), symbol: "folder.fill", advice: .move, isCustom: true
            )
            candidate.block = OffloadSafety.blockReason(for: url, home: home, moved: moved)
            result.removeAll { $0.url.path == path }
            seen.remove(path)
            add(candidate)
        }
        return result
    }

    /// Adds folders the person picked or dropped.
    func addCustom(_ urls: [URL]) {
        guard !DemoMode.isActive else { return }
        var custom = UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser
        var rejected: [String] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if let reason = OffloadSafety.blockReason(for: url, home: home, moved: movedPaths) {
                rejected.append("\(url.lastPathComponent): \(reason.message)")
                continue
            }
            if !custom.contains(path) { custom.append(path) }
        }
        UserDefaults.standard.set(custom, forKey: Self.customKey)
        if !rejected.isEmpty { message = (rejected.joined(separator: "\n"), true) }
        scanTask?.cancel()
        isScanning = false
        scan()
    }

    func removeCustom(_ candidate: OffloadCandidate) {
        var custom = UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []
        custom.removeAll { $0 == candidate.url.path }
        UserDefaults.standard.set(custom, forKey: Self.customKey)
        candidates.removeAll { $0.id == candidate.id }
    }

    // MARK: - Moving

    func move(_ candidate: OffloadCandidate) {
        guard !DemoMode.isActive, operation == nil else { return }
        guard let volume = selectedVolume, volumes.contains(volume) else {
            message = (OffloadError.driveOffline.errorDescription ?? "", true)
            return
        }
        guard volume.supportsOffload else {
            message = (String(format: String(localized: "%@ is formatted as %@. Moving needs APFS or Mac OS Extended."), volume.name, volume.fileSystemLabel), true)
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let reason = OffloadSafety.blockReason(for: candidate.url, home: home, moved: movedPaths) {
            message = (reason.message, true)
            return
        }
        withBusyCheck(paths: [candidate.url.path], entry: candidate.entry) { [weak self] in
            self?.startMove(candidate, volume: volume)
        }
    }

    private func startMove(_ candidate: OffloadCandidate, volume: OffloadVolume) {
        let id = UUID()
        let relative = "\(DriveOffloadEngine.folderName)/\(id.uuidString.prefix(8)) \(candidate.url.lastPathComponent)"
        var record = OffloadRecord(
            id: id, sourcePath: candidate.url.standardizedFileURL.path, title: candidate.title,
            catalogID: candidate.entry?.id, volumeUUID: volume.uuid, volumeName: volume.name,
            mountPath: volume.url.path, destinationRelativePath: relative,
            size: candidate.size, fileCount: candidate.measure?.fileCount ?? 0,
            phase: .copying, createdAt: Date(), lastVerifiedAt: nil
        )
        operation = OffloadOperation(kind: .move, title: candidate.title, stage: .checking, progress: nil)
        cancelRequested = false

        Task {
            let source = record.sourceURL
            let destination = record.destinationURL()
            do {
                let measure = await backgroundValue { OffloadMeasure.measure(source) }
                guard !measure.crossesVolumes else { throw OffloadError.copyFailed(OffloadBlockReason.otherDisk.message) }
                record.size = measure.size
                record.fileCount = measure.fileCount
                let needed = Int64(Double(measure.size) * 1.1) + 1_000_000_000
                let available = Self.availableSpace(volume.url)
                guard available >= needed else { throw OffloadError.notEnoughSpace(needed: needed, available: available) }
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw OffloadError.destinationExists }

                upsert(record)
                operation?.stage = .copying
                try await copyWithProgress(from: source, to: destination, size: measure.size, volume: volume.url)

                operation?.stage = .verifying
                operation?.progress = nil
                let flag = cancelFlag
                try await background {
                    _ = try DriveOffloadEngine.verify(original: source, copy: destination) { flag.value }
                }

                operation?.stage = .swapping
                record.phase = .swapping
                upsert(record)
                let backup = record.backupURL
                try await background { try DriveOffloadEngine.swapInLink(source: source, backup: backup, destination: destination) }

                operation?.stage = .finishing
                record.phase = .active
                record.lastVerifiedAt = Date()
                upsert(record)
                do {
                    try await background { try DriveOffloadEngine.deleteBackup(backup) }
                    message = (String(format: String(localized: "%@ moved to %@. %@ freed on your Mac."), record.title, volume.name, Self.format(record.size)), false)
                } catch {
                    message = (String(format: String(localized: "%@ moved, but the original couldn't be deleted. MacDash will try again later: %@"), record.title, backup.path), true)
                }
                writeVolumeManifest(volume.url)
                Haptics.success()
            } catch {
                // Drop the partial copy only when the original is certainly in
                // place. Otherwise the record stays, and recovery sorts it out
                // from what is on disk.
                var isDirectory: ObjCBool = false
                if !DriveOffloadEngine.isSymbolicLink(source),
                   FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
                   !FileManager.default.fileExists(atPath: record.backupURL.path) {
                    try? FileManager.default.removeItem(at: destination)
                    removeRecord(record.id)
                } else {
                    recoverInterrupted(force: true)
                }
                message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, !(error is CancellationError) && (error as? OffloadError) != .cancelled)
            }
            operation = nil
            process = nil
            refreshVolumes()
            candidates.removeAll { $0.url.path == record.sourcePath && records.contains(where: { $0.id == record.id }) }
        }
    }

    // MARK: - Restoring

    func restore(_ record: OffloadRecord, keepCopy: Bool) {
        guard !DemoMode.isActive, operation == nil else { return }
        guard let mount = mountPath(for: record) else {
            message = (OffloadError.driveOffline.errorDescription ?? "", true)
            return
        }
        refreshStatuses()
        guard let current = records.first(where: { $0.id == record.id }), statuses[record.id] == .healthy else {
            message = (String(localized: "Fix the folder's status before bringing it back."), true)
            return
        }
        let needed = current.size + 2_000_000_000
        let free = OffloadVolumes.internalFreeSpace().free
        guard free >= needed else {
            message = (OffloadError.notEnoughSpace(needed: needed, available: free).errorDescription ?? "", true)
            return
        }
        let destination = current.destinationURL(mountPath: mount)
        withBusyCheck(paths: [current.sourcePath, destination.path], entry: DriveOffloadCatalog.entries.first { $0.id == current.catalogID }) { [weak self] in
            self?.startRestore(current, destination: destination, keepCopy: keepCopy)
        }
    }

    private func startRestore(_ start: OffloadRecord, destination: URL, keepCopy: Bool) {
        var record = start
        operation = OffloadOperation(kind: .restore, title: record.title, stage: .copying, progress: 0)
        cancelRequested = false
        Task {
            let restored = record.restoreURL
            let source = record.sourceURL
            do {
                record.phase = .restoring
                upsert(record)
                try await copyWithProgress(from: destination, to: restored, size: record.size, volume: nil)
                operation?.stage = .verifying
                operation?.progress = nil
                let flag = cancelFlag
                try await background {
                    _ = try DriveOffloadEngine.verify(original: destination, copy: restored) { flag.value }
                }
                operation?.stage = .swapping
                record.phase = .restoreSwapping
                upsert(record)
                try await background { try DriveOffloadEngine.swapOutLink(source: source, restored: restored) }
                operation?.stage = .finishing
                if !keepCopy {
                    let folder = destination.deletingLastPathComponent()
                    try? await background {
                        try DriveOffloadEngine.deleteBackup(destination)
                        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true,
                           folder.lastPathComponent == DriveOffloadEngine.folderName {
                            try? FileManager.default.removeItem(at: folder)
                        }
                    }
                }
                removeRecord(record.id)
                if let volume = volumes.first(where: { $0.uuid == record.volumeUUID }) { writeVolumeManifest(volume.url) }
                message = (String(format: String(localized: "%@ is back on your Mac."), record.title), false)
                Haptics.success()
            } catch {
                // The drive copy is untouched, so the restored copy can go,
                // unless it's already the only folder on the Mac.
                if DriveOffloadEngine.isSymbolicLink(source) {
                    try? FileManager.default.removeItem(at: restored)
                    record.phase = .active
                    upsert(record)
                } else {
                    recoverInterrupted(force: true)
                }
                message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, (error as? OffloadError) != .cancelled)
            }
            operation = nil
            process = nil
            refreshVolumes()
            scan()
        }
    }

    // MARK: - Repairs

    /// Moves what an app wrote into a stand-in folder over to the drive, puts
    /// the stand-in in the Trash and links again.
    func resolveConflict(_ record: OffloadRecord) {
        guard !DemoMode.isActive, operation == nil, let mount = mountPath(for: record) else { return }
        let destination = record.destinationURL(mountPath: mount)
        withBusyCheck(paths: [record.sourcePath], entry: DriveOffloadCatalog.entries.first { $0.id == record.catalogID }) { [weak self] in
            guard let self else { return }
            operation = OffloadOperation(kind: .merge, title: record.title, stage: .copying, progress: nil)
            Task {
                do {
                    let count = try await self.background { () -> Int in
                        let moved = try DriveOffloadEngine.merge(standIn: record.sourceURL, into: destination)
                        try FileManager.default.trashItem(at: record.sourceURL, resultingItemURL: nil)
                        try FileManager.default.createSymbolicLink(at: record.sourceURL, withDestinationURL: destination)
                        return moved
                    }
                    self.message = (String(format: String(localized: "Linked again. %lld new items were moved to the drive; the empty stand-in is in the Trash."), Int64(count)), false)
                } catch {
                    self.message = (error.localizedDescription, true)
                }
                self.operation = nil
                self.refreshVolumes()
            }
        }
    }

    func recreateLink(_ record: OffloadRecord) {
        guard !DemoMode.isActive, let mount = mountPath(for: record) else { return }
        do {
            try FileManager.default.createSymbolicLink(at: record.sourceURL, withDestinationURL: record.destinationURL(mountPath: mount))
            message = (String(localized: "The link is back."), false)
        } catch {
            message = (error.localizedDescription, true)
        }
        refreshVolumes()
    }

    /// Stops tracking a folder whose copy is gone. A link pointing nowhere is
    /// removed; nothing else is touched.
    func forget(_ record: OffloadRecord) {
        guard !DemoMode.isActive else { return }
        if DriveOffloadEngine.isSymbolicLink(record.sourceURL), !FileManager.default.fileExists(atPath: record.sourceURL.path) {
            try? FileManager.default.removeItem(at: record.sourceURL)
        }
        removeRecord(record.id)
        refreshVolumes()
    }

    func revealCopy(_ record: OffloadRecord) {
        guard let mount = mountPath(for: record) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([record.destinationURL(mountPath: mount)])
    }

    func cancel() {
        cancelRequested = true
        process?.terminate()
    }

    // MARK: - Recovery

    /// Finishes or undoes whatever an interrupted move or restore left behind.
    /// Each case only takes a step when the files on disk confirm where it stopped.
    func recoverInterrupted(force: Bool = false) {
        guard !DemoMode.isActive, force || operation == nil else { return }
        let fm = FileManager.default
        for record in records {
            let source = record.sourceURL
            let isLink = DriveOffloadEngine.isSymbolicLink(source)
            let sourceExists = isLink || fm.fileExists(atPath: source.path)
            let backupExists = fm.fileExists(atPath: record.backupURL.path)
            let restoreExists = fm.fileExists(atPath: record.restoreURL.path)
            let mount = mountPath(for: record)
            var updated = record

            switch record.phase {
            case .active:
                if isLink, backupExists { try? DriveOffloadEngine.deleteBackup(record.backupURL) }
                continue
            case .copying:
                // The original never changed. Remove the partial copy once the drive is here.
                if let mount {
                    try? fm.removeItem(at: record.destinationURL(mountPath: mount))
                    removeRecord(record.id)
                }
                continue
            case .swapping:
                if isLink {
                    if backupExists { try? DriveOffloadEngine.deleteBackup(record.backupURL) }
                    updated.phase = .active
                } else if !sourceExists, backupExists {
                    try? fm.moveItem(at: record.backupURL, to: source)
                    updated.phase = .copying
                } else {
                    updated.phase = .copying
                }
            case .restoring:
                if restoreExists { try? fm.removeItem(at: record.restoreURL) }
                updated.phase = .active
            case .restoreSwapping:
                if isLink, restoreExists {
                    try? DriveOffloadEngine.swapOutLink(source: source, restored: record.restoreURL)
                    removeRecord(record.id)
                    continue
                } else if !sourceExists, restoreExists {
                    try? fm.moveItem(at: record.restoreURL, to: source)
                    removeRecord(record.id)
                    continue
                } else if sourceExists, !isLink {
                    removeRecord(record.id)
                    continue
                } else {
                    updated.phase = .active
                }
            }
            if updated != record { upsert(updated) }
            if updated.phase == .copying, mount != nil { recoverInterrupted(force: force); return }
        }
        refreshStatuses()
    }

    // MARK: - Busy apps

    private func withBusyCheck(paths: [String], entry: OffloadCatalogEntry?, then action: @escaping () -> Void) {
        operation = OffloadOperation(kind: .move, title: "", stage: .checking, progress: nil)
        let bundleIDs = entry?.bundleIdentifiers ?? []
        let processNames = entry?.processNames ?? []
        Task {
            let names = await backgroundValue { () -> [String] in
                var names = Set(OffloadOpenFiles.processes(using: paths))
                for name in processNames where Shell.run("/usr/bin/pgrep", ["-x", name]).status == 0 { names.insert(name) }
                return names.sorted()
            }
            let apps = NSWorkspace.shared.runningApplications.filter {
                ($0.bundleIdentifier.map(bundleIDs.contains) ?? false) || names.contains($0.localizedName ?? "\u{0}")
            }
            var all = Set(names)
            apps.compactMap(\.localizedName).forEach { all.insert($0) }
            // MacDash itself shows up while it measures.
            all.remove(ProcessInfo.processInfo.processName)
            all.remove("MacDash")
            operation = nil
            if all.isEmpty {
                action()
            } else {
                busyApps = BusyPrompt(names: all.sorted()) { [weak self] in
                    for app in apps where app.processIdentifier != getpid() { app.terminate() }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self?.withBusyCheck(paths: paths, entry: entry, then: action)
                    }
                }
            }
        }
    }

    // MARK: - Copy progress

    private func copyWithProgress(from source: URL, to destination: URL, size: Int64, volume: URL?) async throws {
        let target = volume ?? FileManager.default.homeDirectoryForCurrentUser
        let startFree = Self.availableSpace(target)
        operation?.progress = 0
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let used = Double(startFree - Self.availableSpace(target))
                if size > 0 { self?.operation?.progress = min(0.99, max(0, used / Double(size))) }
            }
        }
        defer { poll.cancel() }
        if cancelRequested { throw OffloadError.cancelled }
        try await background { [weak self] in
            try DriveOffloadEngine.copy(from: source, to: destination) { process in
                DispatchQueue.main.async { self?.process = process }
            }
        }
        if cancelRequested { throw OffloadError.cancelled }
        operation?.progress = 1
    }

    private nonisolated static func availableSpace(_ url: URL) -> Int64 {
        // A fresh URL each time: resource values are cached per URL object.
        let fresh = URL(fileURLWithPath: url.path)
        let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    private func background<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private func backgroundValue<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Manifest

    private func upsert(_ record: OffloadRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        saveManifest()
    }

    private func removeRecord(_ id: UUID) {
        records.removeAll { $0.id == id }
        saveManifest()
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([OffloadRecord].self, from: data)) ?? []
    }

    /// Written atomically before each step, so it always describes the files.
    private func saveManifest() {
        guard !DemoMode.isActive else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// A copy of the list on the drive, with a note, so the folders there
    /// explain themselves even without MacDash.
    private func writeVolumeManifest(_ volume: URL) {
        let folder = volume.appendingPathComponent(DriveOffloadEngine.folderName)
        let mine = records.filter { $0.mountPath == volume.path }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(mine) {
            try? data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        }
        let lines = mine.map { "• \($0.destinationRelativePath.split(separator: "/").last ?? "") → \($0.sourcePath)" }
        let note = String(localized: "These folders were moved here by MacDash. Each one is linked from its original place on the Mac. To bring one back, open MacDash › Drive Offload and turn it off. Don't rename or delete them while they're in use.")
        try? (note + "\n\n" + lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Demo

    private func loadDemo() {
        let gb: Int64 = 1_000_000_000
        let volume = OffloadVolume(
            url: URL(fileURLWithPath: "/Volumes/Studio SSD"), name: "Studio SSD", uuid: "DEMO-VOLUME",
            fileSystem: "apfs", isInternal: false, isReadOnly: false,
            totalCapacity: 2_000 * gb, availableCapacity: 1_412 * gb, isSolidState: true, busProtocol: "USB"
        )
        volumes = [volume]
        selectedVolumeID = volume.id
        internalFree = 38 * gb
        internalTotal = 245 * gb
        let home = "/Users/alex"
        func record(_ title: String, _ path: String, _ size: Int64, days: Double, catalog: String) -> OffloadRecord {
            OffloadRecord(
                id: UUID(), sourcePath: home + path, title: title, catalogID: catalog, volumeUUID: volume.uuid,
                volumeName: volume.name, mountPath: volume.url.path,
                destinationRelativePath: "\(DriveOffloadEngine.folderName)/\(title)",
                size: size * gb, fileCount: 1_200, phase: .active,
                createdAt: Date().addingTimeInterval(-days * 86_400), lastVerifiedAt: Date()
            )
        }
        records = [
            record(String(localized: "Ollama models"), "/.ollama/models", 46, days: 21, catalog: "ollama.models"),
            record(String(localized: "iOS simulators"), "/Library/Developer/CoreSimulator/Devices", 18, days: 9, catalog: "simulators"),
        ]
        statuses = Dictionary(uniqueKeysWithValues: records.map { ($0.id, OffloadLinkStatus.healthy) })
        let catalog = Dictionary(uniqueKeysWithValues: DriveOffloadCatalog.entries.map { ($0.id, $0) })
        func candidate(_ id: String, _ size: Int64, days: Double) -> OffloadCandidate? {
            guard let entry = catalog[id] else { return nil }
            var item = OffloadCandidate(
                url: URL(fileURLWithPath: home + "/" + entry.relativePath), title: entry.title, detail: entry.detail,
                symbol: entry.symbol, advice: entry.advice, entry: entry
            )
            item.measure = FolderMeasure(size: size, fileCount: 800, lastModified: Date().addingTimeInterval(-days * 86_400))
            return item
        }
        candidates = [
            candidate("claude.vm", 11_400_000_000, days: 3),
            candidate("downloads", 17_800_000_000, days: 0.2),
            candidate("lmstudio.models", 24_300_000_000, days: 12),
            candidate("xcode.devicesupport", 6_100_000_000, days: 40),
            candidate("movies", 1_800_000_000, days: 90),
            candidate("derivedData", 9_400_000_000, days: 1),
            candidate("npm", 2_000_000_000, days: 4),
            candidate("photos", 31_000_000_000, days: 2),
        ].compactMap { $0 }
        hasScanned = true
    }
}

/// A cancel switch shared with background threads.
final class OffloadCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
