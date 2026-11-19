import CryptoKit
import Foundation

// MARK: - Records

/// One folder moved to an external drive. Saved in a manifest on the Mac and a
/// copy on the drive, and updated before every step, so an interrupted move or
/// restore can be finished or undone at the next launch.
struct OffloadRecord: Codable, Identifiable, Equatable {
    enum Phase: String, Codable {
        /// Copying to the drive. The original is untouched.
        case copying
        /// The copy is verified; the original is being swapped for the link.
        case swapping
        /// The folder lives on the drive behind a link.
        case active
        /// Copying back to the Mac. The link is untouched.
        case restoring
        /// The restored copy is verified; the link is being swapped for it.
        case restoreSwapping
    }

    let id: UUID
    /// Absolute path of the original folder (now the link).
    let sourcePath: String
    let title: String
    var catalogID: String?
    let volumeUUID: String
    var volumeName: String
    /// Where the volume was mounted when the link was made.
    var mountPath: String
    /// Path of the copy, relative to the volume root.
    let destinationRelativePath: String
    var size: Int64
    var fileCount: Int
    var phase: Phase
    let createdAt: Date
    var lastVerifiedAt: Date?

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    func destinationURL(mountPath: String? = nil) -> URL {
        URL(fileURLWithPath: mountPath ?? self.mountPath).appendingPathComponent(destinationRelativePath)
    }
    /// The original, renamed beside the link until the link is confirmed.
    var backupURL: URL { sibling("macdash-original") }
    /// The copy coming back from the drive before it replaces the link.
    var restoreURL: URL { sibling("macdash-restore") }

    private func sibling(_ tag: String) -> URL {
        let source = sourceURL
        return source.deletingLastPathComponent()
            .appendingPathComponent(".\(source.lastPathComponent).\(tag)-\(id.uuidString.prefix(8))")
    }
}

/// The state of a moved folder right now.
enum OffloadLinkStatus: Equatable {
    /// Link and copy are in place.
    case healthy
    /// The drive isn't connected. Apps can't reach the folder.
    case driveOffline
    /// The drive came back at another path; the link has to point there.
    case needsRelink
    /// An app replaced the link with a new folder while the drive was away.
    case conflict
    /// The link was deleted.
    case linkMissing
    /// The drive is connected, but the copy isn't on it.
    case copyMissing
    /// A move or restore was interrupted and needs to be finished.
    case interrupted
}

// MARK: - Volumes

struct OffloadVolume: Identifiable, Equatable {
    let url: URL
    let name: String
    let uuid: String
    /// "apfs", "hfs", "exfat", "msdos", "ntfs"…
    let fileSystem: String
    let isInternal: Bool
    let isReadOnly: Bool
    let totalCapacity: Int64
    let availableCapacity: Int64
    var isSolidState: Bool?
    var busProtocol: String?

    var id: String { uuid }

    /// APFS and Mac OS Extended keep permissions, extended attributes and
    /// links, survive unplugging with their journal, and work with Time Machine.
    var supportsOffload: Bool { ["apfs", "hfs"].contains(fileSystem.lowercased()) && !isReadOnly }

    var fileSystemLabel: String {
        switch fileSystem.lowercased() {
        case "apfs": return "APFS"
        case "hfs": return String(localized: "Mac OS Extended")
        case "exfat": return "ExFAT"
        case "msdos": return "FAT32"
        case "ntfs", "ufsd_ntfs", "tuxera_ntfs": return "NTFS"
        default: return fileSystem.uppercased()
        }
    }
}

enum OffloadVolumes {
    /// External drives that are mounted now. Disk images and hidden volumes
    /// are skipped.
    static func external() -> [OffloadVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> OffloadVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsLocal == true,
                  values.volumeIsBrowsable != false,
                  url.path.hasPrefix("/Volumes/")
            else { return nil }
            // Some FAT drives have no UUID. They can't take moved folders
            // anyway, but still show up so the format warning can explain why.
            let uuid = values.volumeUUIDString ?? "path:\(url.path)"
            var stats = statfs()
            guard statfs(url.path, &stats) == 0 else { return nil }
            let fsType = withUnsafePointer(to: &stats.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let device = withUnsafePointer(to: &stats.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            // Disk images mount from a device too; diskutil tells them apart.
            let info = diskInfo(device)
            if info?["VirtualOrPhysical"] as? String == "Virtual", info?["BusProtocol"] as? String == "Disk Image" { return nil }
            let isInternal = values.volumeIsInternal ?? (info?["Internal"] as? Bool ?? false)
            guard !isInternal else { return nil }
            return OffloadVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                uuid: uuid,
                fileSystem: fsType,
                isInternal: isInternal,
                isReadOnly: values.volumeIsReadOnly ?? false,
                totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
                availableCapacity: Int64(values.volumeAvailableCapacity ?? 0),
                isSolidState: info?["SolidState"] as? Bool,
                busProtocol: info?["BusProtocol"] as? String
            )
        }
    }

    /// The startup disk's free space, counting what macOS can purge.
    static func internalFreeSpace() -> (free: Int64, total: Int64) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    private static func diskInfo(_ device: String) -> [String: Any]? {
        guard device.hasPrefix("/dev/") else { return nil }
        let result = Shell.run("/usr/sbin/diskutil", ["info", "-plist", device])
        guard result.status == 0 else { return nil }
        return try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any]
    }
}

// MARK: - Measuring

struct FolderMeasure: Equatable {
    var size: Int64 = 0
    var fileCount = 0
    var lastModified: Date?
    /// True when something inside is on another disk.
    var crossesVolumes = false
}

enum OffloadMeasure {
    static func measure(_ url: URL, isCancelled: () -> Bool = { false }) -> FolderMeasure {
        var result = FolderMeasure()
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
            .contentModificationDateKey, .volumeIdentifierKey,
        ]
        let rootVolume = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return result }
        for case let item as URL in enumerator {
            if isCancelled() { break }
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            if let volume = values.volumeIdentifier as? NSObject, let rootVolume, !volume.isEqual(rootVolume) {
                result.crossesVolumes = true
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                result.size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                result.fileCount += 1
                if let date = values.contentModificationDate, date > (result.lastModified ?? .distantPast) {
                    result.lastModified = date
                }
            }
        }
        return result
    }
}

// MARK: - Engine

enum OffloadError: LocalizedError, Equatable {
    case sourceMissing
    case destinationExists
    case notEnoughSpace(needed: Int64, available: Int64)
    case copyFailed(String)
    case verifyFailed(String)
    case swapFailed(String)
    case cancelled
    case linkUnexpected
    case driveOffline

    var errorDescription: String? {
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        switch self {
        case .sourceMissing: return String(localized: "The folder is no longer there.")
        case .destinationExists: return String(localized: "A folder with this name is already on the drive.")
        case .notEnoughSpace(let needed, let available):
            return String(format: String(localized: "Not enough space: %@ needed, %@ available."), format(needed), format(available))
        case .copyFailed(let detail): return String(format: String(localized: "Copying failed: %@"), detail)
        case .verifyFailed(let detail): return String(format: String(localized: "The copy doesn't match the original (%@). Nothing was changed."), detail)
        case .swapFailed(let detail): return String(format: String(localized: "Couldn't put the link in place: %@"), detail)
        case .cancelled: return String(localized: "Cancelled. Nothing was changed.")
        case .linkUnexpected: return String(localized: "The folder on the Mac isn't the link MacDash made.")
        case .driveOffline: return String(localized: "Connect the drive first.")
        }
    }
}

/// Copy, verify and swap. Every function works on plain URLs so the tests can
/// run it between temporary folders.
enum DriveOffloadEngine {
    static let folderName = "MacDash Offload"
    private static let fm = FileManager.default

    /// Copies with ditto, which keeps permissions, ACLs, extended attributes,
    /// resource forks and links. `onProcess` hands back the running process so
    /// the caller can cancel it.
    static func copy(from source: URL, to destination: URL, onProcess: (Process) -> Void = { _ in }) throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        onProcess(process)
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal { throw OffloadError.cancelled }
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .split(separator: "\n").first.map(String.init) ?? "ditto \(process.terminationStatus)"
            throw OffloadError.copyFailed(message)
        }
    }

    /// Compares two trees: the same entries, the same kind of entry, the same
    /// size for every file, the same target for every link, and identical
    /// content for a sample of files (the largest ones and a spread of the rest).
    static func verify(original: URL, copy: URL, sampleCount: Int = 48, isCancelled: () -> Bool = { false }) throws -> FolderMeasure {
        let left = try snapshot(original, isCancelled: isCancelled)
        let right = try snapshot(copy, isCancelled: isCancelled)
        if left.entries.count != right.entries.count {
            throw OffloadError.verifyFailed(String(format: String(localized: "%lld items vs %lld"), Int64(left.entries.count), Int64(right.entries.count)))
        }
        for (path, entry) in left.entries {
            guard let other = right.entries[path] else { throw OffloadError.verifyFailed(path) }
            if entry != other { throw OffloadError.verifyFailed(path) }
        }

        let files = left.entries.filter { $0.value.kind == .file && $0.value.size > 0 }.sorted { $0.key < $1.key }
        var sample = Set(files.sorted { $0.value.size > $1.value.size }.prefix(sampleCount / 3).map(\.key))
        if !files.isEmpty {
            let stride = max(1, files.count / max(1, sampleCount - sample.count))
            for index in Swift.stride(from: 0, to: files.count, by: stride) { sample.insert(files[index].key) }
        }
        for path in sample {
            if isCancelled() { throw OffloadError.cancelled }
            let a = original.appendingPathComponent(path), b = copy.appendingPathComponent(path)
            guard try digest(a) == digest(b) else { throw OffloadError.verifyFailed(path) }
        }
        return FolderMeasure(size: left.bytes, fileCount: left.fileCount, lastModified: nil)
    }

    /// Renames the original aside, puts the link in its place, checks the
    /// link reaches the copy, and only then deletes the original. If anything
    /// fails before the delete, the original is put back.
    static func swapInLink(source: URL, backup: URL, destination: URL) throws {
        guard !fm.fileExists(atPath: backup.path) else { throw OffloadError.swapFailed(backup.lastPathComponent) }
        do {
            try fm.moveItem(at: source, to: backup)
        } catch {
            throw OffloadError.swapFailed(error.localizedDescription)
        }
        do {
            try fm.createSymbolicLink(at: source, withDestinationURL: destination)
            _ = try fm.contentsOfDirectory(atPath: source.path)
        } catch {
            try? removeLinkIfPresent(source)
            try? fm.moveItem(at: backup, to: source)
            throw OffloadError.swapFailed(error.localizedDescription)
        }
    }

    /// Deletes the renamed original. Locked or root-owned files are unlocked
    /// first; anything left is reported.
    static func deleteBackup(_ backup: URL) throws {
        guard fm.fileExists(atPath: backup.path) else { return }
        do {
            try fm.removeItem(at: backup)
        } catch {
            _ = Shell.run("/usr/bin/chflags", ["-R", "nouchg", backup.path])
            _ = Shell.run("/bin/chmod", ["-R", "u+w", backup.path])
            try fm.removeItem(at: backup)
        }
    }

    /// Replaces the link with the restored folder.
    static func swapOutLink(source: URL, restored: URL) throws {
        guard isSymbolicLink(source) else { throw OffloadError.linkUnexpected }
        try fm.removeItem(at: source)
        do {
            try fm.moveItem(at: restored, to: source)
        } catch {
            throw OffloadError.swapFailed(error.localizedDescription)
        }
    }

    /// Points the link somewhere else in one step, so there is never a moment
    /// without a link.
    static func repoint(link: URL, to destination: URL) throws {
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).macdash-link")
        try? fm.removeItem(at: temporary)
        try fm.createSymbolicLink(at: temporary, withDestinationURL: destination)
        guard rename(temporary.path, link.path) == 0 else {
            try? fm.removeItem(at: temporary)
            throw OffloadError.swapFailed(String(cString: strerror(errno)))
        }
    }

    /// Moves what an app wrote into a stand-in folder over to the drive copy,
    /// never overwriting: a file that exists on both sides with different
    /// content is kept beside it with a suffix. Returns how many items moved.
    @discardableResult
    static func merge(standIn: URL, into destination: URL) throws -> Int {
        var moved = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: standIn, includingPropertiesForKeys: keys, options: []) else { return 0 }
        let basePath = standIn.standardizedFileURL.path
        for case let item as URL in enumerator {
            let relative = String(item.standardizedFileURL.path.dropFirst(basePath.count + 1))
            let target = destination.appendingPathComponent(relative)
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                if !fm.fileExists(atPath: target.path) {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
                continue
            }
            if fm.fileExists(atPath: target.path) {
                if (try? digest(item)) == (try? digest(target)) { continue }
                let name = target.deletingPathExtension().lastPathComponent
                let ext = target.pathExtension
                var candidate: URL
                var index = 1
                repeat {
                    let suffix = index == 1 ? " (Mac)" : " (Mac \(index))"
                    candidate = target.deletingLastPathComponent()
                        .appendingPathComponent(name + suffix + (ext.isEmpty ? "" : ".\(ext)"))
                    index += 1
                } while fm.fileExists(atPath: candidate.path)
                try fm.copyItem(at: item, to: candidate)
            } else {
                try fm.copyItem(at: item, to: target)
            }
            moved += 1
        }
        return moved
    }

    /// Asks the file system directly: URL resource values are cached per URL
    /// object and would report a link that was just replaced.
    static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func linkTarget(_ url: URL) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: url.path)
    }

    static func removeLinkIfPresent(_ url: URL) throws {
        if isSymbolicLink(url) { try fm.removeItem(at: url) }
    }

    // MARK: Status

    /// Where the record stands, given where its drive is mounted now (nil when
    /// it isn't connected).
    static func status(of record: OffloadRecord, mountPath: String?) -> OffloadLinkStatus {
        if record.phase != .active { return .interrupted }
        let source = record.sourceURL
        let exists = fm.fileExists(atPath: source.path) || isSymbolicLink(source)
        guard let mountPath else {
            if exists, !isSymbolicLink(source) { return .conflict }
            return .driveOffline
        }
        let destination = record.destinationURL(mountPath: mountPath)
        guard fm.fileExists(atPath: destination.path) else { return .copyMissing }
        if !exists { return .linkMissing }
        if !isSymbolicLink(source) { return .conflict }
        if linkTarget(source) != destination.path { return .needsRelink }
        return .healthy
    }

    // MARK: Private

    private struct Entry: Equatable {
        enum Kind: Equatable { case file, directory, link }
        let kind: Kind
        let size: Int64
        let linkTarget: String?
    }

    private static func snapshot(_ root: URL, isCancelled: () -> Bool) throws -> (entries: [String: Entry], bytes: Int64, fileCount: Int) {
        var entries: [String: Entry] = [:]
        var bytes: Int64 = 0
        var files = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: rootPath), includingPropertiesForKeys: keys, options: []) else {
            throw OffloadError.sourceMissing
        }
        for case let item as URL in enumerator {
            if isCancelled() { throw OffloadError.cancelled }
            let path = item.standardizedFileURL.path
            guard path.count > rootPath.count else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                entries[relative] = Entry(kind: .link, size: 0, linkTarget: try? fm.destinationOfSymbolicLink(atPath: path))
            } else if values.isDirectory == true {
                entries[relative] = Entry(kind: .directory, size: 0, linkTarget: nil)
            } else {
                let size = Int64(values.fileSize ?? 0)
                entries[relative] = Entry(kind: .file, size: size, linkTarget: nil)
                bytes += Int64(values.totalFileAllocatedSize ?? Int(size))
                files += 1
            }
        }
        return (entries, bytes, files)
    }

    /// SHA-256 of a file, read in 4 MB pieces. Files above 256 MB are hashed
    /// on their first and last 64 MB plus their size.
    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let chunk = 4 * 1024 * 1024
        let window: UInt64 = 64 * 1024 * 1024
        func read(upTo limit: UInt64) throws {
            var remaining = limit
            while remaining > 0 {
                let data = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
                remaining -= UInt64(data.count)
            }
        }
        if size > 256 * 1024 * 1024 {
            try read(upTo: window)
            try handle.seek(toOffset: size - window)
            try read(upTo: window)
            withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
        } else {
            try read(upTo: size)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Open files

enum OffloadOpenFiles {
    /// Names of processes holding files open inside any of the paths. One
    /// lsof call for the whole system, filtered here: much faster than
    /// `lsof +D`, which walks the folder.
    static func processes(using paths: [String]) -> [String] {
        let result = Shell.run("/usr/sbin/lsof", ["-n", "-P", "-F", "cn", "-u", "\(getuid())"])
        guard let text = String(data: result.output, encoding: .utf8) else { return [] }
        let prefixes = paths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var names = Set<String>()
        var command = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("c") {
                command = String(line.dropFirst())
            } else if line.hasPrefix("n") {
                let name = String(line.dropFirst())
                if prefixes.contains(where: { name.hasPrefix($0) || name + "/" == $0 }) { names.insert(command) }
            }
        }
        return names.sorted()
    }
}
