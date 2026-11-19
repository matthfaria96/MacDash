// Treemap layout and file categories adapted from Mac Sai (https://github.com/iliyami/MacSai)
// Copyright (c) 2026, Mac Sai Contributors. BSD 3-Clause License.
// See THIRD_PARTY_NOTICES.md.

import CoreGraphics
import Foundation

/// One item in the Space Lens tree. Folders keep their children so drilling
/// down never needs another scan; small files are folded into a single
/// "smaller files" node to keep memory flat on whole-disk scans.
final class SpaceNode: Identifiable, @unchecked Sendable {
    enum Kind: Sendable {
        case folder
        /// A bundle macOS shows as one file (apps, libraries, packages).
        case package
        case file
        /// Files too small to list one by one.
        case smallerFiles
        /// Space the volume uses that no reachable file accounts for: other
        /// APFS volumes in the container, snapshots, purgeable data.
        case hidden
    }

    let name: String
    let kind: Kind
    fileprivate(set) var size: Int64
    /// Files inside (for folders and packages) or folded together (smaller files).
    fileprivate(set) var itemCount: Int
    fileprivate(set) var children: [SpaceNode]
    /// The folder couldn't be read (no permission).
    fileprivate(set) var isUnreadable = false

    init(name: String, kind: Kind, size: Int64 = 0, itemCount: Int = 0, children: [SpaceNode] = []) {
        self.name = name
        self.kind = kind
        self.size = size
        self.itemCount = itemCount
        self.children = children
    }

    var canOpen: Bool { (kind == .folder || kind == .hidden) && !children.isEmpty }

    /// Items with a real place on disk (not the folded or hidden ones).
    var isOnDisk: Bool { kind != .smallerFiles && kind != .hidden }

    var category: SpaceCategory {
        switch kind {
        case .folder: return .folder
        case .package: return (name as NSString).pathExtension.lowercased() == "app" ? .application : .package
        case .smallerFiles: return .other
        case .hidden: return .system
        case .file: return SpaceCategory(fileExtension: (name as NSString).pathExtension)
        }
    }

    /// Removes a child after it was moved to the Trash. Ancestors are
    /// updated by the caller, which knows the path.
    func removeChild(_ child: SpaceNode) {
        children.removeAll { $0 === child }
        size -= child.size
        itemCount -= max(child.itemCount, 1)
    }

    func shrink(by bytes: Int64, items: Int) {
        size -= bytes
        itemCount -= items
    }
}

/// Color families for the map.
enum SpaceCategory: String, CaseIterable, Sendable {
    case folder
    case application
    case package
    case video
    case images
    case audio
    case documents
    case archives
    case code
    case system
    case other

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "braw", "r3d", "mxf": self = .video
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "psb", "afphoto": self = .images
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff", "aif", "caf", "logicx": self = .audio
        case "pdf", "doc", "docx", "pages", "rtf", "txt", "odt", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "epub": self = .documents
        case "zip", "gz", "tgz", "tar", "rar", "7z", "bz2", "xz", "dmg", "iso", "img", "sparseimage", "sparsebundle", "pkg", "ipsw", "xip": self = .archives
        case "swift", "h", "m", "c", "cpp", "py", "js", "ts", "java", "rs", "go", "rb", "json", "sqlite", "db", "log", "gguf", "safetensors", "bin", "pt", "onnx": self = .code
        default: self = .other
        }
    }
}

struct SpaceLensProgress: Sendable {
    var items = 0
    var bytes: Int64 = 0
    var currentPath = ""
}

/// What the scan has measured at the top level so far, so the map can take
/// shape while the scan runs. Every top-level folder grows at once.
struct SpaceLensPartial: Sendable {
    struct Top: Sendable {
        let name: String
        let bytes: Int64
        let category: SpaceCategory
        let isDone: Bool
    }

    let tops: [Top]
}

/// A finished scan: the tree plus what the volume says about itself.
struct SpaceLensResult: @unchecked Sendable {
    let root: SpaceNode
    /// Capacity and free space when the scan covered a whole volume.
    let volume: (total: Int64, free: Int64)?
}

/// Measures a disk or folder into a `SpaceNode` tree.
///
/// Several workers pull folders from one shared queue, breadth first, and
/// list each with a single bulk call. Sizes are the blocks actually
/// allocated, hard links and APFS clones are counted once, cloud placeholders
/// count as nothing, and the scan never crosses into another volume. On a
/// whole volume, whatever the volume reports as used but no file accounts for
/// is shown as its own item, so the total matches the disk.
enum SpaceLensScanner {
    /// Files at least this big are listed on their own.
    static let listedFileSize: Int64 = 1_000_000
    /// Folders with only a handful of small files list them anyway.
    static let smallFolderFileCount = 8

    static func scan(
        root: URL,
        onProgress: @escaping @Sendable (SpaceLensProgress) -> Void,
        onPartial: (@Sendable (SpaceLensPartial) -> Void)? = nil
    ) async -> SpaceLensResult? {
        let job = ScanJob(root: root, onProgress: onProgress, onPartial: onPartial)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                job.run { continuation.resume(returning: $0) }
            }
        } onCancel: {
            job.cancel()
        }
    }

    // MARK: Package detection

    private static let packageCache = NSCache<NSString, NSNumber>()

    /// Folders macOS shows as one file: apps, bundles, libraries.
    static func isPackage(_ path: String, name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let cached = packageCache.object(forKey: ext as NSString) { return cached.boolValue }
        let isPackage = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        // Package-ness comes from the extension's type in almost every case,
        // so one lookup per extension is enough.
        packageCache.setObject(NSNumber(value: isPackage), forKey: ext as NSString)
        return isPackage
    }

    /// On the startup disk these paths are other volumes or the same data seen
    /// twice through firmlinks, so they're skipped.
    /// `/.nofollow` and `/.resolve` are virtual mirrors of the whole disk.
    static let startupDiskSkips: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/Network",
        "/.nofollow", "/.resolve", "/.vol",
    ]

    static let smallerFilesName = String(localized: "Smaller files")

    // MARK: Trash safety

    /// Space Lens only moves things to the Trash inside the user's folders or
    /// on external disks. System folders, apps (use the uninstaller) and the
    /// standard folders themselves are never offered.
    static func canMoveToTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let ownBundle = Bundle.main.bundleURL.standardizedFileURL.path
        if path == ownBundle || path.hasPrefix(ownBundle + "/") { return false }

        if path.hasPrefix(home + "/") {
            let relative = String(path.dropFirst(home.count + 1))
            let protectedFolders: Set<String> = [
                "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                "Applications", "Public", "Sites", ".Trash",
            ]
            if protectedFolders.contains(relative) { return false }
            // The Library's own top-level folders (Caches, Containers…) stay.
            let parts = relative.split(separator: "/")
            if parts.first == "Library", parts.count <= 2 { return false }
            return true
        }

        if path.hasPrefix("/Volumes/") {
            // Never a whole disk, only what's on it.
            return path.split(separator: "/").count > 2
        }
        return false
    }
}

// MARK: - Parallel scan

/// One scan in progress. Workers share a queue of folders; each folder node
/// is filled by exactly one worker, and sizes are added up once every worker
/// has finished, so nodes need no locking of their own.
private final class ScanJob: @unchecked Sendable {
    private struct Work {
        let node: SpaceNode
        let path: String
        /// Index of the top-level item this folder belongs to.
        let top: Int
        let depth: Int
    }

    private let rootURL: URL
    private let rootPath: String
    private let onProgress: @Sendable (SpaceLensProgress) -> Void
    private let onPartial: (@Sendable (SpaceLensPartial) -> Void)?
    private let isStartupDisk: Bool
    private let allowedDevices: Set<Int32>

    private let condition = NSCondition()
    private var queue: [Work] = []
    private var queueHead = 0
    private var busyWorkers = 0
    private var cancelled = false

    // Guarded by `stateLock`.
    private let stateLock = NSLock()
    private var progress = SpaceLensProgress()
    private var lastReport = CFAbsoluteTimeGetCurrent()
    private var lastPartial = CFAbsoluteTimeGetCurrent()
    private var seenLinks = Set<FileKey>()
    private var seenClones = Set<FileKey>()
    private var tops: [(node: SpaceNode, bytes: Int64, pending: Int)] = []

    private struct FileKey: Hashable {
        let device: Int32
        let id: UInt64
    }

    private let rootNode: SpaceNode

    init(root: URL, onProgress: @escaping @Sendable (SpaceLensProgress) -> Void, onPartial: (@Sendable (SpaceLensPartial) -> Void)?) {
        rootURL = root
        rootPath = (root.path as NSString).standardizingPath
        self.onProgress = onProgress
        self.onPartial = onPartial
        isStartupDisk = rootPath == "/"
        // The startup disk is a system and a data volume joined by firmlinks;
        // both count as this disk.
        var devices = Set<Int32>()
        if let device = DirectoryLister.device(of: rootPath) { devices.insert(device) }
        if isStartupDisk, let data = DirectoryLister.device(of: "/System/Volumes/Data") { devices.insert(data) }
        allowedDevices = devices
        rootNode = SpaceNode(name: FileManager.default.displayName(atPath: root.path), kind: .folder)
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    private var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func run(completion: @escaping (SpaceLensResult?) -> Void) {
        let thread = Thread { [self] in
            // The root is listed first so every top-level folder can be
            // measured side by side from the start.
            fill(Work(node: rootNode, path: rootPath, top: -1, depth: 0))
            let workerCount = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
            let group = DispatchGroup()
            for _ in 0..<workerCount {
                group.enter()
                let worker = Thread { [self] in
                    workLoop()
                    group.leave()
                }
                worker.qualityOfService = .userInitiated
                worker.start()
            }
            group.wait()
            guard !isCancelled else { return completion(nil) }

            Self.finalize(rootNode)
            let volume = addHiddenSpace()
            sendPartial(force: true)
            stateLock.lock()
            let final = progress
            stateLock.unlock()
            onProgress(final)
            completion(SpaceLensResult(root: rootNode, volume: volume))
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func workLoop() {
        while let work = nextWork() {
            autoreleasepool { fill(work) }
            condition.lock()
            busyWorkers -= 1
            condition.broadcast()
            condition.unlock()
            finished(top: work.top)
        }
    }

    private func nextWork() -> Work? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled { return nil }
            if queueHead < queue.count {
                let work = queue[queueHead]
                queueHead += 1
                // Drop the consumed prefix now and then so the array stays small.
                if queueHead > 4096 {
                    queue.removeFirst(queueHead)
                    queueHead = 0
                }
                busyWorkers += 1
                return work
            }
            if busyWorkers == 0 { return nil }
            condition.wait()
        }
    }

    private func enqueue(_ items: [Work]) {
        guard !items.isEmpty else { return }
        condition.lock()
        queue.append(contentsOf: items)
        condition.broadcast()
        condition.unlock()
    }

    /// Lists one folder into its node and queues its subfolders.
    private func fill(_ work: Work) {
        guard let entries = DirectoryLister.list(work.path) else {
            work.node.isUnreadable = true
            return
        }
        var children: [SpaceNode] = []
        var subfolders: [Work] = []
        var smallFiles: [(name: String, size: Int64)] = []
        var bytes: Int64 = 0
        var files = 0
        let insidePackage = work.node.kind == .package

        for entry in entries {
            let path = work.path == "/" ? "/" + entry.name : work.path + "/" + entry.name
            switch entry.kind {
            case .symlink, .other, .mountPoint:
                continue
            case .directory:
                if entry.isDataless { continue }
                if isStartupDisk, work.depth == 0, SpaceLensScanner.startupDiskSkips.contains(path) { continue }
                if !allowedDevices.isEmpty, !allowedDevices.contains(entry.device) { continue }
                let kind: SpaceNode.Kind = insidePackage || SpaceLensScanner.isPackage(path, name: entry.name) ? .package : .folder
                let child = SpaceNode(name: entry.name, kind: kind)
                children.append(child)
                let top = work.depth == 0 ? register(top: child) : work.top
                subfolders.append(Work(node: child, path: path, top: top, depth: work.depth + 1))
            case .file:
                let size = countedSize(of: entry)
                bytes += size
                files += 1
                if work.depth == 0 {
                    let file = SpaceNode(name: entry.name, kind: .file, size: size, itemCount: 1)
                    children.append(file)
                    _ = register(top: file, bytes: size, done: true)
                } else if size >= SpaceLensScanner.listedFileSize, !insidePackage {
                    // A package's contents are folded into it later, so its
                    // files never need nodes of their own.
                    children.append(SpaceNode(name: entry.name, kind: .file, size: size, itemCount: 1))
                } else {
                    smallFiles.append((entry.name, size))
                }
            }
        }

        if smallFiles.count <= SpaceLensScanner.smallFolderFileCount {
            children += smallFiles.map { SpaceNode(name: $0.name, kind: .file, size: $0.size, itemCount: 1) }
        } else {
            let total = smallFiles.reduce(Int64(0)) { $0 + $1.size }
            children.append(SpaceNode(name: SpaceLensScanner.smallerFilesName, kind: .smallerFiles, size: total, itemCount: smallFiles.count))
        }
        work.node.children = children

        stateLock.lock()
        if work.top >= 0 {
            tops[work.top].bytes += bytes
            tops[work.top].pending += subfolders.count
        }
        stateLock.unlock()
        counted(files: files, bytes: bytes, path: work.path)
        enqueue(subfolders)
    }

    /// Allocated size, or 0 when the same blocks were already counted through
    /// another hard link or an APFS clone.
    private func countedSize(of entry: DirectoryLister.Entry) -> Int64 {
        guard entry.allocated > 0 else { return 0 }
        if entry.linkCount > 1 {
            stateLock.lock()
            defer { stateLock.unlock() }
            return seenLinks.insert(FileKey(device: entry.device, id: entry.fileID)).inserted ? entry.allocated : 0
        }
        if let clone = entry.cloneID {
            stateLock.lock()
            defer { stateLock.unlock() }
            return seenClones.insert(FileKey(device: entry.device, id: clone)).inserted ? entry.allocated : 0
        }
        return entry.allocated
    }

    private func register(top node: SpaceNode, bytes: Int64 = 0, done: Bool = false) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        tops.append((node, bytes, done ? 0 : 1))
        return tops.count - 1
    }

    private func finished(top: Int) {
        guard top >= 0 else { return }
        stateLock.lock()
        tops[top].pending -= 1
        stateLock.unlock()
    }

    private func counted(files: Int, bytes: Int64, path: String) {
        stateLock.lock()
        progress.items += files
        progress.bytes += bytes
        let now = CFAbsoluteTimeGetCurrent()
        var report: SpaceLensProgress?
        if now - lastReport > 0.12 {
            lastReport = now
            progress.currentPath = path
            report = progress
        }
        stateLock.unlock()
        if let report { onProgress(report) }
        sendPartial(force: false)
    }

    private func sendPartial(force: Bool) {
        guard let onPartial else { return }
        stateLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastPartial > 0.5 else {
            stateLock.unlock()
            return
        }
        lastPartial = now
        let snapshot = tops.map { top in
            SpaceLensPartial.Top(
                name: top.node.name,
                bytes: top.node.kind == .file ? top.node.size : top.bytes,
                category: top.node.category,
                isDone: top.pending <= 0
            )
        }
        stateLock.unlock()
        onPartial(SpaceLensPartial(tops: snapshot))
    }

    /// Adds sizes up from the leaves, sorts each folder largest first, and
    /// folds package contents into the package.
    private static func finalize(_ node: SpaceNode) {
        var stack: [(SpaceNode, Bool)] = [(node, false)]
        while let (current, visited) = stack.popLast() {
            if visited || current.children.isEmpty {
                guard current.kind == .folder || current.kind == .package else { continue }
                current.size = current.children.reduce(0) { $0 + $1.size }
                current.itemCount = current.children.reduce(0) { $0 + ($1.kind == .file ? 1 : $1.itemCount) }
                if current.kind == .package {
                    current.children = []
                } else {
                    current.children.sort { $0.size > $1.size }
                }
            } else {
                stack.append((current, true))
                for child in current.children where child.kind == .folder || child.kind == .package {
                    stack.append((child, false))
                }
            }
        }
    }

    /// On a whole volume, shows the used space no file accounts for as one
    /// item, split into the named APFS volumes that share the disk. Returns
    /// the volume's capacity and free space.
    private func addHiddenSpace() -> (total: Int64, free: Int64)? {
        guard DirectoryLister.isVolumeRoot(rootPath), let space = DirectoryLister.volumeSpace(rootPath) else { return nil }
        let volume = (total: space.total, free: space.available)
        let used = space.total - space.available
        let unseen = used - rootNode.size
        // Small differences are rounding and metadata, not worth a slice.
        guard unseen > max(used / 200, 256 * 1_048_576) else { return volume }

        var parts: [SpaceNode] = []
        var named: Int64 = 0
        for volume in DirectoryLister.siblingVolumes(of: rootPath, excluding: allowedDevices) {
            let bytes = min(volume.bytes, unseen - named)
            guard bytes > 0 else { break }
            parts.append(SpaceNode(name: volume.name, kind: .hidden, size: bytes))
            named += bytes
        }
        let rest = unseen - named
        if rest > 0 {
            parts.append(SpaceNode(name: String(localized: "Snapshots, purgeable and unreadable files"), kind: .hidden, size: rest))
        }
        parts.sort { $0.size > $1.size }
        let hidden = SpaceNode(name: String(localized: "System & hidden data"), kind: .hidden, size: unseen, children: parts.count > 1 ? parts : [])
        rootNode.children.append(hidden)
        rootNode.children.sort { $0.size > $1.size }
        rootNode.size += unseen
        return volume
    }
}

/// Squarified treemap layout (Bruls, Huijing, van Wijk, 2000): rows of tiles
/// chosen to keep every tile as close to square as possible.
enum SquarifiedTreemap {
    /// One rectangle per value, in the order given. Values should be sorted
    /// largest first for the best result.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in .zero } }

        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var results: [CGRect] = []
        results.reserveCapacity(values.count)
        var remaining = rect
        var index = 0

        while index < areas.count {
            let wide = remaining.width >= remaining.height
            let side = Double(wide ? remaining.height : remaining.width)
            var rowEnd = index
            var rowArea = 0.0
            var best = Double.infinity

            while rowEnd < areas.count {
                let candidateArea = rowArea + areas[rowEnd]
                let worst = worstAspectRatio(areas[index...rowEnd], total: candidateArea, side: side)
                if worst <= best {
                    best = worst
                    rowArea = candidateArea
                    rowEnd += 1
                } else {
                    break
                }
            }

            let thickness = side > 0 ? rowArea / side : 0
            var offset = 0.0
            for areaIndex in index..<rowEnd {
                let length = thickness > 0 ? areas[areaIndex] / thickness : 0
                if wide {
                    results.append(CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length))
                } else {
                    results.append(CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness))
                }
                offset += length
            }

            if wide {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY, width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: max(0, remaining.height - thickness))
            }
            index = rowEnd
        }
        return results
    }

    static func worstAspectRatio(_ areas: ArraySlice<Double>, total: Double, side: Double) -> Double {
        guard side > 0, total > 0 else { return .infinity }
        let side2 = side * side
        var worst = 0.0
        for area in areas where area > 0 {
            worst = max(worst, max(side2 * area / (total * total), (total * total) / (side2 * area)))
        }
        return worst
    }
}
